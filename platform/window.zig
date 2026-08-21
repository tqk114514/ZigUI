//! platform/window.zig —— 窗口 + 消息泵 + 渲染集成（规则 §5.9）。
//!
//! 模块不变量（规则 §5.9）：
//! - 本模块是唯一创建/拥有 HWND 的地方；整个 UI 一个顶层 HWND（L2）；
//! - wndProc 只做消息归属分发；
//! - WM_PAINT：ensureLayout → BeginDraw → paintTree → EndDraw；设备丢失整建后重试一次；
//! - WM_SIZE：resize render target + invalidateMeasure；
//! - WM_DPICHANGED：更新缩放 + invalidateMeasure + 应用系统建议矩形；
//! - Win32 调用失败：记日志、安全返回，绝不让消息泵崩溃（§4.2）。
//!
//! 启动序列（规则 §5.9）：SetProcessDpiAwarenessContext(per-monitor-v2) →
//! 注册窗口类 → 创建窗口 → DwmSetWindowAttribute 挂暗色标题栏 → 创建 D2D 工厂。

const std = @import("std");
const builtin = @import("builtin");
const w32 = @import("win32.zig");
const node = @import("../core/node.zig");
const geometry = @import("../core/geometry.zig");
const painter = @import("../core/painter.zig");
const event = @import("../core/event.zig");
const widget = @import("../core/widget.zig");
const ticker_mod = @import("../core/ticker.zig");
const dispatch = @import("../widgets/dispatch.zig");
const device_mod = @import("../render/device.zig");
const painter_mod = @import("../render/painter.zig");
const text_mod = @import("../render/text.zig");
const post_mod = @import("post.zig");
const input_mod = @import("input.zig");
const ime_mod = @import("ime.zig");
const clipboard_mod = @import("clipboard.zig");
const theme = @import("../theme.zig");

const log = std.log.scoped(.platform);

/// 消息泵返回值。目前仅"窗口已关闭"一种退出路径。
pub const RunResult = enum { closed };

/// 自定义标题栏高度（DIP）。
const TITLEBAR_H: f32 = 32;
/// 标题栏按钮宽度（DIP）。
const TITLE_BTN_W: f32 = 46;
/// 按钮索引。
const BTN_MIN: u8 = 0;
const BTN_MAX: u8 = 1;
const BTN_CLOSE: u8 = 2;
const BTN_NONE: i8 = -1;

/// 平台选项。
pub const Options = struct {
    /// 窗口标题（UTF-16，调用方持有）。
    title: [:0]const u16,
    /// 初始客户区宽度（物理像素）。
    width: i32 = 960,
    /// 初始客户区高度（物理像素）。
    height: i32 = 600,
    /// 窗口最小尺寸（DIP，业界默认 320×200；resize 不可再小）。
    min_width: f32 = 320,
    min_height: f32 = 200,
    /// 主题引用（§5.12：theme 是共享常量）。
    theme_ref: *const theme.Theme = &theme.dark,
    /// 可选：run 创建任务桥后回填指针，供调用方（如 worker 线程）调 Ui.post。
    /// 指向一个 *PostBridge 槽（调用方先置 undefined/null）。
    post_out: ?**post_mod.PostBridge = null,
    /// 消息泵退出后、窗口与任务桥销毁前回调（UI 线程）。
    /// 正确关闭顺序（§5.12）：在此通知后台线程退出并 join，之后销毁桥才安全。
    on_close: ?*const fn (user_ctx: ?*anyopaque) void = null,
    on_close_ctx: ?*anyopaque = null,
    /// 每帧绘制完成后回调（UI 线程）。供 profiling / bench（§4.9）统计帧耗时。
    frame_hook: ?*const fn (user_ctx: ?*anyopaque) void = null,
    frame_hook_ctx: ?*anyopaque = null,
    /// 是否使用自定义标题栏（§5.9：DWM 圆角 + 自绘顶栏）。默认 true。
    use_titlebar: bool = true,
};

/// 每窗口的上下文，经 GWLP_USERDATA 挂到 HWND，wndProc 取回。
const WindowCtx = struct {
    hwnd: w32.HWND,
    running: bool = true,
    tree: *node.Tree,
    device: ?*device_mod.Device = null,
    painter: painter_mod.D2DPainter = undefined,
    theme_ref: *const theme.Theme,
    /// 跨线程任务桥（§5.12）：Ui.post 的目标。
    post_bridge: *post_mod.PostBridge = undefined,
    /// 关闭钩子（§5.12 正确关闭顺序）：桥销毁前调用。
    on_close: ?*const fn (user_ctx: ?*anyopaque) void = null,
    on_close_ctx: ?*anyopaque = null,
    /// 帧钩子（§4.9 bench）。
    frame_hook: ?*const fn (user_ctx: ?*anyopaque) void = null,
    frame_hook_ctx: ?*anyopaque = null,
    /// IMM32 输入法上下文（§5.10）。
    ime: ime_mod.Ime = undefined,
    /// 时钟/动画/时机子系统（§5.13 TODO(层树)：核心调度器，纯逻辑）。
    ticker: ticker_mod.Ticker = .{},
    /// 是否已挂着惰性唤醒定时器（ticker.hasActive 时才挂，空闲即杀 → 0% CPU，§4.9）。
    tick_active: bool = false,
    /// 光标闪烁周期定时器的 Ticker 句柄（无焦点 Edit 时为 null）。
    caret_timer: ?usize = null,
    /// 透明位图（系统 caret 用：全 0 单色位图，显示不可见但 GetCaretPos 定位有效）。
    caret_bmp: ?w32.gdi.HBITMAP = null,
    /// WM_CHAR 代理对暂存（emoji 等，§5.9：WM_CHAR 是 text_input 唯一来源）。
    surrogate_high: u16 = 0,
    /// 窗口标题（UTF-8，run 时一次性转换；标题栏绘制用，帧路径零分配）。
    title_utf8: []const u8 = "",
    /// 标题栏启用（§5.9 use_titlebar）。
    titlebar_active: bool = false,
    /// 标题栏按钮悬停索引（BTN_MIN/MAX/CLOSE，BTN_NONE = 无）。
    tb_hover: i8 = BTN_NONE,
    /// 标题栏按钮按下索引（拖动中记原始按钮，BTN_NONE = 无）。
    tb_pressed: i8 = BTN_NONE,
    /// 最大化后首帧需要按最大化处理裁剪/布局（maximize 尺寸与 restore 不同）。
    maximize_dirty: bool = false,
    /// 标题栏需局部重绘（§5.4）：按钮 hover/press 变化时置位，renderFrame 把整条 strip 并入脏区。
    tb_dirty: bool = false,
    /// 窗口最小尺寸（DIP）：resize 不可再小（WM_GETMINMAXINFO 设 ptMinTrackSize）。
    min_dip: geometry.Size = .{ .width = 320, .height = 200 },
};

/// 惰性唤醒定时器 ID（§5.13：ticker.hasActive() 时才挂，空闲即杀）。
const TIMER_TICK: usize = 1;
/// 唤醒查询粒度（ms）：只用于"到点检查 + 推进"，真正的事件间隔由 Ticker 内 QPC 判定；
/// 系统默认滚动到 ~15.6ms 即可（不 timeBeginPeriod，省全局系统分辨率开销）。
const TICK_MS: u32 = 1;

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("zigui.m0");

/// 运行消息泵直到窗口关闭。tree 由调用方持有（arena 在调用方），
/// dispatch 与 text_system 在此装配（§5.4/§5.7）。
pub fn run(opts: Options, tree: *node.Tree) !RunResult {
    if (comptime builtin.os.tag != .windows) {
        @compileError("zigui is Windows-only (rule.md Non-goals)");
    }

    // 1. DPI 感知（per-monitor v2，免 manifest）。
    _ = w32.setProcessDpiAwarenessContextPerMonitorV2();

    // 装配控件行为与文本系统（render 提供）。
    tree.dispatch_table = &dispatch.table;
    // 装配剪贴板接口（§5.11）：Edit 复制/粘贴经 tree.clipboard。
    tree.clipboard = clipboard_mod.asClipboard();

    // 2. 注册窗口类。
    const hinst = w32.kernel32.GetModuleHandleW(null) orelse return error.GetModuleHandleFailed;
    // 类背景画刷 = 主题 bg_window：窗口创建/显示瞬间即为暗色，杜绝启动白屏闪烁
    const bg_brush = w32.gdi32.CreateSolidBrush(w32.zig.COLORREF.rgb(
        toByte(opts.theme_ref.bg_window.r),
        toByte(opts.theme_ref.bg_window.g),
        toByte(opts.theme_ref.bg_window.b),
    )) orelse return error.CreateBrushFailed;
    defer _ = w32.gdi32.DeleteObject(bg_brush);
    const wnd_class = w32.windows_and_messaging.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.windows_and_messaging.WNDCLASSEXW),
        // CS_DBLCLKS：接收 WM_LBUTTONDBLCLK（双击选词，§5.8）——缺失则双击退化为两次 DOWN。
        .style = .{ .DBLCLKS = 1 },
        .lpfnWndProc = wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinst,
        .hIcon = null,
        // 客户区默认箭头光标：鼠标从非客户区（边框）移入时，系统据 hCursor 恢复箭头，
        // 避免残留边框拉伸光标。
        .hCursor = w32.user32.LoadCursorW(null, w32.windows_and_messaging.IDC_ARROW),
        .hbrBackground = bg_brush,
        .lpszMenuName = null,
        .lpszClassName = class_name,
        .hIconSm = null,
    };
    if (w32.user32.RegisterClassExW(&wnd_class) == 0) {
        if (w32.kernel32.GetLastError() != .ERROR_CLASS_ALREADY_EXISTS) {
            log.err("RegisterClassExW failed, error={d}", .{@intFromEnum(w32.kernel32.GetLastError())});
            return error.RegisterClassFailed;
        }
    }

    // 3. 创建窗口。
    const hwnd = w32.user32.CreateWindowExW(
        .{},
        class_name,
        opts.title,
        w32.windows_and_messaging.WS_OVERLAPPEDWINDOW,
        w32.windows_and_messaging.CW_USEDEFAULT,
        w32.windows_and_messaging.CW_USEDEFAULT,
        opts.width,
        opts.height,
        null,
        null,
        hinst,
        null,
    ) orelse {
        log.err("CreateWindowExW failed, error={d}", .{@intFromEnum(w32.kernel32.GetLastError())});
        return error.CreateWindowFailed;
    };

    // 4. 暗色标题栏（Win10 1809+，DWM 属性 20 = USE_IMMERSIVE_DARK_MODE）。
    setDarkTitleBar(hwnd);

    // 5. 创建渲染设备（D2D 工厂 + render target）。
    const device = try device_mod.Device.init(std.heap.page_allocator, hwnd);
    defer device.deinit();
    tree.text_system = text_mod.asTextSystem(&device.text_system);
    // 装配层宿主（§5.6 光栅缓存/分层）：层节点内容缓存到离屏位图，变换（滚动平移）合成复用像素。
    tree.layer_host = painter_mod.asLayerHost(device);

    // 5b. 创建跨线程任务桥（§5.12），绑定 hwnd。
    const bridge = try std.heap.page_allocator.create(post_mod.PostBridge);
    bridge.* = post_mod.PostBridge.init(std.heap.page_allocator);
    bridge.hwnd = hwnd;
    if (opts.post_out) |out| out.* = bridge;
    defer {
        bridge.deinit();
        std.heap.page_allocator.destroy(bridge);
    }

    // 标题栏标题 UTF-8（绘制用；一次性转换，帧路径零分配）。
    const title_utf8 = std.unicode.utf16LeToUtf8Alloc(std.heap.page_allocator, opts.title) catch "";
    defer std.heap.page_allocator.free(title_utf8);

    // 6. 挂载 ctx（让 WM_PAINT 等消息能找到窗口状态）。
    var ctx = WindowCtx{
        .hwnd = hwnd,
        .tree = tree,
        .device = device,
        .painter = .{ .device = device },
        .theme_ref = opts.theme_ref,
        .post_bridge = bridge,
        .on_close = opts.on_close,
        .on_close_ctx = opts.on_close_ctx,
        .frame_hook = opts.frame_hook,
        .frame_hook_ctx = opts.frame_hook_ctx,
        .ime = .{ .hwnd = hwnd },
        .title_utf8 = title_utf8,
        .titlebar_active = opts.use_titlebar,
        .min_dip = .{ .width = opts.min_width, .height = opts.min_height },
    };
    _ = w32.user32.SetWindowLongPtrW(hwnd, .P_USERDATA, @bitCast(@intFromPtr(&ctx)));
    defer _ = w32.user32.DestroyWindow(hwnd);

    // 4b. 自定义标题栏（§5.9）：DWM 扩展帧进客户区（保留阴影/圆角）+ Win11 圆角偏好。
    // 必须在 ctx 挂载之后：WM_NCCALCSIZE（FRAMECHANGED 触发）依赖 ctx 判断"是否启用"，
    // 否则移除标准标题栏的 NCCALCSIZE 落空，系统标题栏残留到下次 resize/minimize。
    if (opts.use_titlebar) {
        applyTitlebarFrame(hwnd);
    }

    // 7. 先渲染首帧再显示：否则窗口先以默认白色客户区呈现一瞬（启动白屏闪烁）。
    //    显示后 WM_PAINT 会再正常重绘一帧，内容一致。
    renderFrame(&ctx);
    _ = w32.user32.ShowWindow(hwnd, w32.windows_and_messaging.SW_SHOW);
    // 首帧带 swing 平面的翻转交换链（§5.6）：窗口未显示前 present 的表面不被 DWM 合成，
    // 窗口一显示会以未初始化表面为白屏，直到一次输入事件触发重绘。显示后同步强制
    // 重绘一次，保证首帧在"可见 + 最终尺寸"下真正 present。
    _ = w32.user32.InvalidateRect(hwnd, null, 0);
    _ = w32.user32.UpdateWindow(hwnd);

    // 消息泵。
    var msg: w32.windows_and_messaging.MSG = undefined;
    while (ctx.running) {
        const got = w32.user32.GetMessageW(&msg, null, 0, 0);
        if (got == 0) break; // WM_QUIT。
        if (got < 0) {
            log.err("GetMessageW returned -1", .{});
            break;
        }
        _ = w32.user32.TranslateMessage(&msg);
        _ = w32.user32.DispatchMessageW(&msg);
    }
    // 正确关闭顺序（§5.12）：桥/窗口尚未销毁，先通知后台线程退出。
    // 回调需在桥的 defer 销毁之前完成（join 后台线程），保证 post 不再发生。
    if (ctx.on_close) |f| f(ctx.on_close_ctx);
    return .closed;
}

fn setDarkTitleBar(hwnd: w32.HWND) void {
    const enable: w32.BOOL = 1;
    _ = w32.dwmapi.DwmSetWindowAttribute(
        hwnd,
        w32.dwm.DWMWINDOWATTRIBUTE.USE_IMMERSIVE_DARK_MODE,
        &enable,
        @sizeOf(w32.BOOL),
    );
}

/// 自定义标题栏帧（§5.9）：DWM 扩展帧进客户区（保留阴影）+ Win11 圆角偏好，
/// 并强制 WM_NCCALCSIZE 应用（移除标准标题栏）。
fn applyTitlebarFrame(hwnd: w32.HWND) void {
    const margins = w32.controls.MARGINS{ .cxLeftWidth = 0, .cxRightWidth = 0, .cyTopHeight = 0, .cyBottomHeight = 0 };
    _ = w32.dwmapi.DwmExtendFrameIntoClientArea(hwnd, &margins);
    const corner: w32.dwm.DWM_WINDOW_CORNER_PREFERENCE = .ROUND;
    _ = w32.dwmapi.DwmSetWindowAttribute(
        hwnd,
        w32.dwm.DWMWINDOWATTRIBUTE.WINDOW_CORNER_PREFERENCE,
        &corner,
        @sizeOf(w32.dwm.DWM_WINDOW_CORNER_PREFERENCE),
    );
    // 立即应用 WM_NCCALCSIZE（移除标准标题栏），避免首帧残留系统标题栏。
    _ = w32.user32.SetWindowPos(
        hwnd,
        null,
        0,
        0,
        0,
        0,
        .{ .NOMOVE = 1, .NOSIZE = 1, .NOZORDER = 1, .NOACTIVATE = 1, .DRAWFRAME = 1 },
    );
}

/// 标题栏按钮矩形（DIP，客户区坐标）。索引 BTN_MIN/MAX/CLOSE。
fn titlebarButtonRect(ctx: *const WindowCtx, index: u8) geometry.Rect {
    const width = getClientSizeDips(ctx.device.?).width;
    const x = width - @as(f32, @floatFromInt(3 - index)) * TITLE_BTN_W;
    return .{ .x = x, .y = 0, .w = TITLE_BTN_W, .h = TITLEBAR_H };
}

/// 客户区 DIP 坐标命中哪个标题栏按钮（BTN_NONE = 无）。
fn titlebarHitButton(ctx: *const WindowCtx, p: geometry.Point) i8 {
    if (p.y < 0 or p.y >= TITLEBAR_H) return BTN_NONE;
    var i: u8 = BTN_MIN;
    while (i <= BTN_CLOSE) : (i += 1) {
        if (titlebarButtonRect(ctx, i).contains(p)) return @intCast(i);
    }
    return BTN_NONE;
}

/// 绘制标题栏（§5.9）：背景（bg_window，与内容区一体，无分隔线）→
/// 标题文本（左，font_ui）→ 三按钮（hover/pressed 视觉 + 字形图标）。
fn paintTitlebar(ctx: *WindowCtx, pc: painter.PaintCtx) void {
    const th = ctx.theme_ref;
    const w = getClientSizeDips(ctx.device.?).width;
    const strip = geometry.Rect{ .x = 0, .y = 0, .w = w, .h = TITLEBAR_H };
    // 背景（L9：只取 theme token）。与内容区间色，不画分隔线，视觉一体。
    pc.fillRect(strip, th.bg_window);

    // 标题文本（左，垂直居中；前导 12 DIP 呼吸间距）。
    if (ctx.title_utf8.len > 0) {
        if (ctx.tree.text_system) |ts| {
            if (ts.layout(ctx.title_utf8, &th.font_ui, w - 4 * TITLE_BTN_W, .{})) |tl| {
                const ty = (TITLEBAR_H - tl.bounds.height) * 0.5;
                pc.drawText(.{ .x = 12, .y = ty, .w = tl.bounds.width, .h = tl.bounds.height }, tl, th.text);
            }
        }
    }

    // 三按钮：最小化 / 最大化恢复 / 关闭（字形图标，Segoe MDL2 Assets，§5.9）。
    const icon_font = th.font_icons;
    var i: u8 = BTN_MIN;
    while (i <= BTN_CLOSE) : (i += 1) {
        const r = titlebarButtonRect(ctx, i);
        const hovered = ctx.tb_hover == @as(i8, @intCast(i));
        const pressed = ctx.tb_pressed == @as(i8, @intCast(i));
        // 关闭键 hover/pressed 用 danger（Win11 风格）；其余用 hover/pressed token。
        const bg: theme.Color = if (i == BTN_CLOSE and (hovered or pressed))
            th.danger
        else if (pressed)
            th.bg_pressed
        else if (hovered)
            th.bg_hover
        else
            th.bg_window;
        pc.fillRect(r, bg);
        // 关闭键红底时图标用 accent_text（保证对比度），其余用正文色（L9）。
        const icon_color: theme.Color = if (i == BTN_CLOSE and (hovered or pressed)) th.accent_text else th.text;
        // 字形图标：U+E921 最小化、U+E922 最大化、U+E923 恢复、U+E8BB 关闭。
        const icon_cp = switch (i) {
            BTN_MIN => "\u{E921}",
            BTN_MAX => if (isZoomed(ctx.hwnd)) "\u{E923}" else "\u{E922}",
            BTN_CLOSE => "\u{E8BB}",
            else => unreachable,
        };
        if (ctx.tree.text_system) |ts| {
            if (ts.layout(icon_cp, &icon_font, r.w, .{})) |tl| {
                const ix = r.x + (r.w - tl.bounds.width) * 0.5;
                const iy = r.y + (r.h - tl.bounds.height) * 0.5;
                pc.drawText(.{ .x = ix, .y = iy, .w = tl.bounds.width, .h = tl.bounds.height }, tl, icon_color);
            }
        }
    }
}

/// 边框厚度（物理像素）：非客户区 resize 边。用 per-DPI 系统度量。
fn frameBorderPx(scale: f32) i32 {
    const dpi: u32 = @intFromFloat(scale * 96.0);
    return w32.user32.GetSystemMetricsForDpi(w32.windows_and_messaging.SM_CXSIZEFRAME, dpi) +
        w32.user32.GetSystemMetricsForDpi(w32.windows_and_messaging.SM_CXPADDEDBORDER, dpi);
}

/// 当前是否最大化。
fn isZoomed(hwnd: w32.HWND) bool {
    return w32.user32.IsZoomed(hwnd) != 0;
}

/// 执行标题栏按钮动作（§5.9）。index = BTN_MIN/MAX/CLOSE。
fn titlebarAction(ctx: *WindowCtx, index: u8) void {
    switch (index) {
        BTN_MIN => _ = w32.user32.ShowWindow(ctx.hwnd, w32.windows_and_messaging.SW_MINIMIZE),
        BTN_MAX => {
            const cmd: w32.windows_and_messaging.SHOW_WINDOW_CMD = if (isZoomed(ctx.hwnd))
                w32.windows_and_messaging.SW_RESTORE
            else
                w32.windows_and_messaging.SW_MAXIMIZE;
            _ = w32.user32.ShowWindow(ctx.hwnd, cmd);
            // 最大化/恢复会触发 WM_SIZE（刷新布局）；最大化首帧 WM_SIZE 可能先于
            // IsZoomed 生效，标记下一帧按最大化尺寸裁剪。
            ctx.maximize_dirty = true;
            _ = w32.user32.InvalidateRect(ctx.hwnd, null, 0);
        },
        BTN_CLOSE => _ = w32.user32.DestroyWindow(ctx.hwnd),
        else => {},
    }
}

/// 从 WM_MOUSE 的 lParam 提取客户区 DIP 坐标（§5.9）。
fn clientPointDip(l_param: w32.LPARAM, scale: f32) geometry.Point {
    const raw: i64 = @bitCast(l_param);
    const px_x: i16 = @truncate(raw);
    const px_y: i16 = @truncate(raw >> 16);
    return .{ .x = @as(f32, @floatFromInt(px_x)) / scale, .y = @as(f32, @floatFromInt(px_y)) / scale };
}

/// 显示系统菜单（§5.9：标题栏右键）。
fn showSystemMenu(ctx: *WindowCtx, sx: i16, sy: i16) void {
    const menu = w32.user32.GetSystemMenu(ctx.hwnd, 0);
    if (menu) |m| {
        _ = w32.user32.SetForegroundWindow(ctx.hwnd);
        const cmd = w32.user32.TrackPopupMenu(
            m,
            .{ .RIGHTBUTTON = 1, .RETURNCMD = 1 },
            sx,
            sy,
            0,
            ctx.hwnd,
            null,
        );
        if (cmd != 0) _ = w32.user32.PostMessageW(ctx.hwnd, w32.windows_and_messaging.WM_SYSCOMMAND, @intCast(cmd), 0);
    }
}

/// 执行一帧绘制（WM_PAINT 与首帧共用）。部分重绘（§5.4）：本帧脏区 = 树局部脏区 ∪
/// 标题栏 strip（tb_dirty）∪ 布局松动时的整窗；用 PushClip 把 Clear 与绘制限制在脏区，
/// 脏区外复用上一帧像素。
fn renderFrame(ctx: *WindowCtx) void {
    const dev = ctx.device.?;
    // 确保 render target 就绪（窗口显示后首次绘制才真正创建）。
    if (!dev.ensureTarget()) return;
    const client = getClientSizeDips(dev);

    // 惰性布局：绘制前必须调用（§5.3）。自定义标题栏时内容区从标题栏下方开始。
    ctx.tree.content_top = if (ctx.titlebar_active) TITLEBAR_H else 0;
    ctx.tree.ensureLayout(client);

    // 本帧脏区（DIP，客户区坐标）：树局部脏区；无局部脏则整窗。
    const full = geometry.Rect{ .x = 0, .y = 0, .w = client.width, .h = client.height };
    var dirty = ctx.tree.beginPaintDirty(full) orelse full;
    if (ctx.tb_dirty) {
        ctx.tb_dirty = false;
        const strip = geometry.Rect{ .x = 0, .y = 0, .w = client.width, .h = TITLEBAR_H };
        dirty = dirty.merge(strip);
    }

    const pc = ctx.painter.ctx(ctx.theme_ref);
    dev.beginFrame();
    // 脏区裁剪：Clear 与全部绘制都受此 clip 限制，脏区外保留上帧像素（部分重绘）。
    pc.pushClip(dirty);
    // 清背景（窗口 token；受 clip 限制，只清脏区）。
    dev.rt.?.ID2D1RenderTarget.Clear(&toD2DColor(ctx.theme_ref.bg_window));
    // 标题栏（§5.9）：先于内容绘制，一体视觉（被 clip 裁到脏区）。
    if (ctx.titlebar_active) paintTitlebar(ctx, pc);
    ctx.tree.paint(pc);
    pc.popClip();
    const need_retry = dev.endFrame();
    if (need_retry) {
        // 设备丢失：endFrame 已重建 render target，重绘一次（全量，旧 clip 已归零）。
        dev.beginFrame();
        dev.rt.?.ID2D1RenderTarget.Clear(&toD2DColor(ctx.theme_ref.bg_window));
        if (ctx.titlebar_active) paintTitlebar(ctx, pc);
        ctx.tree.paint(pc);
        _ = dev.endFrame();
    }
    // 最大化/恢复切换：首帧后 IsZoomed 才稳定，强制再重绘一次（按钮图标跟随）。
    if (ctx.maximize_dirty and ctx.titlebar_active) {
        ctx.maximize_dirty = false;
        _ = w32.user32.InvalidateRect(ctx.hwnd, null, 0);
    }
    // 帧钩子（§4.9）：本帧绘制完成，供 bench 统计帧耗时。
    if (ctx.frame_hook) |f| f(ctx.frame_hook_ctx);
    // IME 组合窗/候选框跟随（§5.10）：焦点 Edit paint 后回报 caret 屏幕物理坐标。
    reportImeCaret(ctx);
}

/// IME caret 跟随（§5.10）：计算焦点 Edit 的光标物理坐标。
/// 1) SetCaretPos 设置系统光标（客户区坐标）——微软拼音等只根据系统光标定位候选框；
/// 2) ime.updateCaret 用屏幕坐标设组合窗/候选框位置。
fn reportImeCaret(ctx: *WindowCtx) void {
    const f = ctx.tree.focus orelse return;
    if (f.widget != .edit) return;
    const ts = ctx.tree.text_system orelse return;
    const d = f.widget.edit;
    var dip_x: f32 = widget.Edit.pad_h;
    if (d.caret > 0) {
        // 含尾随空白宽度：光标紧跟空格时位置正确（与 widgets/edit.zig 的 prefixWidth 一致）。
        if (ts.layout(d.buf[0..d.caret], &ctx.theme_ref.font_ui, 1_000_000.0, .{})) |tl| {
            dip_x += tl.width_with_ws;
        }
    }
    // DIP（内容区）→ 物理像素（客户区）。
    const scale = ctx.device.?.dpi_scale;
    const client_x: i32 = @intFromFloat((f.rect.x + dip_x) * scale);
    const client_y: i32 = @intFromFloat((f.rect.y + widget.Edit.pad_v) * scale);
    // 系统光标跟随（某些 IME 只按系统光标定位候选框，§5.10 实践）。
    _ = w32.user32.SetCaretPos(client_x, client_y);
    // 组合窗/候选框：ImmSet*Window 的 ptCurrentPos 用客户区坐标（GetCaretPos 同坐标系）。
    ctx.ime.updateCaret(client_x, client_y);
}

/// 单调时钟（秒，QPC）：Ticker 的时间源。精度 ~100ns 级，无需高分辨率定时器
/// 高频唤醒——唤醒粒度由惰性 WM_TIMER 决定，到期判定与间隔度量一律用本时钟（§5.13）。
fn nowSeconds() f64 {
    var freq: w32.foundation.LARGE_INTEGER = undefined;
    var cnt: w32.foundation.LARGE_INTEGER = undefined;
    _ = w32.kernel32.QueryPerformanceFrequency(&freq);
    _ = w32.kernel32.QueryPerformanceCounter(&cnt);
    const c: f64 = @floatFromInt(cnt.QuadPart);
    const f: f64 = @floatFromInt(freq.QuadPart);
    return @max(0.0, c / f);
}

/// 根据 ticker 是否有活跃工作挂/停惰性唤醒定时器：有则挂，无则杀（空闲 0% CPU，§4.9）。
fn syncTickTimer(ctx: *WindowCtx) void {
    const on = ctx.ticker.hasActive();
    if (on and !ctx.tick_active) {
        _ = w32.user32.SetTimer(ctx.hwnd, TIMER_TICK, TICK_MS, null);
        ctx.tick_active = true;
    } else if (!on and ctx.tick_active) {
        _ = w32.user32.KillTimer(ctx.hwnd, TIMER_TICK);
        ctx.tick_active = false;
    }
}

/// 光标闪烁回调（§5.8 周期 530ms）：翻转闪烁相位并失效焦点 Edit（驱动其所在 scroll 条带重栅化）。
fn caretBlinkTick(ctx: ?*anyopaque) void {
    const c: *WindowCtx = @ptrCast(@alignCast(ctx.?));
    c.tree.caret_blink_on = !c.tree.caret_blink_on;
    if (c.tree.focus) |f| f.invalidatePaint();
}

/// 焦点是 Edit 时注册光标闪烁周期定时，否则注销（§5.8：经统一 Ticker 调度）。
/// 定时器只在聚焦时注册一次——Ticker 持续翻转实现闪烁；操作只重置相位为可见
/// （立即显示光标），不重新调度（否则连续操作期间不闪烁）。
/// 同时创建系统 caret（隐藏，仅供 IME 的 GetCaretPos 定位候选框，§5.10）。
fn syncCaretTimer(ctx: *WindowCtx) void {
    const is_edit = if (ctx.tree.focus) |f| f.widget == .edit else false;
    if (is_edit) {
        ctx.tree.caret_blink_on = true; // 操作后立即可见。
        if (ctx.caret_timer == null) {
            ctx.caret_timer = ctx.ticker.setInterval(caretBlinkTick, ctx, 0.53, nowSeconds());
        }
        // 透明位图 caret：全 0 单色位图（0 位显示为背景色），系统即使显示也完全不可见；
        // caret 仍存在，SetCaretPos/GetCaretPos 供 IME 定位候选框（§5.10）。
        // 视觉光标由 Edit 自绘。
        if (ctx.caret_bmp == null) {
            const zero: [1]u8 = .{0};
            ctx.caret_bmp = w32.gdi32.CreateBitmap(1, 1, 1, 1, &zero);
        }
        if (ctx.caret_bmp) |bmp| {
            _ = w32.user32.CreateCaret(ctx.hwnd, bmp, 1, 1);
        }
    } else {
        if (ctx.caret_timer) |h| ctx.ticker.clearTimer(h);
        ctx.caret_timer = null;
        _ = w32.user32.DestroyCaret();
        if (ctx.caret_bmp) |bmp| {
            _ = w32.gdi32.DeleteObject(bmp);
            ctx.caret_bmp = null;
        }
    }
    syncTickTimer(ctx);
}

/// 释放 IME 事件分配的文本（§5.10：生命周期 = 当前事件）。空串为字面量，跳过。
fn freeImeEventText(e: event.Event) void {
    switch (e) {
        .text_input => |t| if (t.text.len > 0) std.heap.page_allocator.free(t.text),
        .ime_compose => |t| if (t.text.len > 0) std.heap.page_allocator.free(t.text),
        else => {},
    }
}

/// 客户端尺寸（DIP）：物理像素 / dpi_scale。
fn getClientSizeDips(dev: *device_mod.Device) geometry.Size {
    // DIP 尺寸 = 物理像素 ÷ dpi_scale。不查 rt.GetSize()：ID2D1DeviceContext 在
    // beginFrame SetTarget 之前无 target，GetSize 返回 0（旧 HwndRenderTarget 才总是可用）。
    return .{
        .width = @as(f32, @floatFromInt(dev.px_width)) / dev.dpi_scale,
        .height = @as(f32, @floatFromInt(dev.px_height)) / dev.dpi_scale,
    };
}

fn toD2DColor(c: theme.Color) w32.direct2d.common.D2D_COLOR_F {
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a };
}

/// 主题 f32 颜色分量 → GDI 8bit（类背景画刷用；物理像素边界转换，L3）。
fn toByte(c: f32) u8 {
    return @intFromFloat(@min(255.0, c * 255.0 + 0.5));
}

/// 窗口过程：消息归属见 §5.9，指针/键盘消息转 Event 后经 tree.dispatch。
fn wndProc(hwnd: w32.HWND, u_msg: u32, w_param: w32.WPARAM, l_param: w32.LPARAM) callconv(.winapi) w32.LRESULT {
    const ctx: ?*WindowCtx = @ptrFromInt(@as(usize, @bitCast(w32.user32.GetWindowLongPtrW(hwnd, .P_USERDATA))));
    switch (u_msg) {
        w32.windows_and_messaging.WM_DESTROY => {
            w32.user32.PostQuitMessage(0);
            return 0;
        },
        // —— 自定义标题栏（§5.9）：NC 消息（仅启用时拦截）——
        w32.windows_and_messaging.WM_NCCALCSIZE => {
            if (ctx != null and ctx.?.titlebar_active) {
                if (w_param != 0) {
                    const params: *w32.windows_and_messaging.NCCALCSIZE_PARAMS = @ptrFromInt(@as(usize, @bitCast(l_param)));
                    // 最大化：客户区 = 工作区（补偿系统边框溢出；标准 custom chrome）。
                    if (isZoomed(hwnd)) {
                        const mon = w32.user32.MonitorFromWindow(hwnd, w32.gdi.MONITOR_DEFAULTTONEAREST);
                        var mi: w32.gdi.MONITORINFO = undefined;
                        mi.cbSize = @sizeOf(w32.gdi.MONITORINFO);
                        if (w32.user32.GetMonitorInfoW(mon, &mi) != 0) {
                            params.rgrc[0] = mi.rcWork;
                        }
                    }
                    // 返回 0：移除标准标题栏。
                    return 0;
                }
            }
        },
        w32.windows_and_messaging.WM_GETMINMAXINFO => {
            if (ctx != null and ctx.?.titlebar_active) {
                const mm: *w32.windows_and_messaging.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(l_param)));
                // 最小尺寸（DIP → 物理像素×scale；含非客户区边框）。
                const scale = ctx.?.device.?.dpi_scale;
                const minw = @as(i32, @intFromFloat(ctx.?.min_dip.width * scale)) + frameBorderPx(scale) * 2;
                const minh = @as(i32, @intFromFloat(ctx.?.min_dip.height * scale)) + frameBorderPx(scale) * 2 + @as(i32, @intFromFloat(TITLEBAR_H * scale));
                mm.ptMinTrackSize = .{ .x = minw, .y = minh };
                // 最大化填满工作区（不遮任务栏）。
                const mon = w32.user32.MonitorFromWindow(hwnd, w32.gdi.MONITOR_DEFAULTTONEAREST);
                var mi: w32.gdi.MONITORINFO = undefined;
                mi.cbSize = @sizeOf(w32.gdi.MONITORINFO);
                if (w32.user32.GetMonitorInfoW(mon, &mi) != 0) {
                    mm.ptMaxPosition = .{ .x = mi.rcWork.left, .y = mi.rcWork.top };
                    mm.ptMaxSize = .{ .x = mi.rcWork.right - mi.rcWork.left, .y = mi.rcWork.bottom - mi.rcWork.top };
                    mm.ptMaxTrackSize = mm.ptMaxSize;
                }
                return 0;
            }
        },
        w32.windows_and_messaging.WM_NCHITTEST => {
            if (ctx != null and ctx.?.titlebar_active) {
                const raw: i64 = @bitCast(l_param);
                const sx: i16 = @truncate(raw);
                const sy: i16 = @truncate(raw >> 16);
                const scale = ctx.?.device.?.dpi_scale;
                // 非最大化：四边/四角 resize（用 per-DPI 系统边框厚）。
                if (!isZoomed(hwnd)) {
                    const border = frameBorderPx(scale);
                    var wrc: w32.RECT = undefined;
                    if (w32.user32.GetWindowRect(hwnd, &wrc) != 0) {
                        const on_l = sx < wrc.left + border;
                        const on_r = sx > wrc.right - border;
                        const on_t = sy < wrc.top + border;
                        const on_b = sy > wrc.bottom - border;
                        if (on_t and on_l) return w32.windows_and_messaging.HTTOPLEFT;
                        if (on_t and on_r) return w32.windows_and_messaging.HTTOPRIGHT;
                        if (on_b and on_l) return w32.windows_and_messaging.HTBOTTOMLEFT;
                        if (on_b and on_r) return w32.windows_and_messaging.HTBOTTOMRIGHT;
                        if (on_l) return w32.windows_and_messaging.HTLEFT;
                        if (on_r) return w32.windows_and_messaging.HTRIGHT;
                        if (on_t) return w32.windows_and_messaging.HTTOP;
                        if (on_b) return w32.windows_and_messaging.HTBOTTOM;
                    }
                }
                // 标题栏：最大化按钮返回 HTMAXBUTTON（Win11 悬停出 Snap Layouts、点击系统
                // 最大化，§5.9），其余按钮 HTCLIENT（应用自绘响应），拖拽区 HTCAPTION。
                var pt = w32.foundation.POINT{ .x = sx, .y = sy };
                if (w32.user32.ScreenToClient(hwnd, &pt) != 0) {
                    const p = geometry.Point{ .x = @as(f32, @floatFromInt(pt.x)) / scale, .y = @as(f32, @floatFromInt(pt.y)) / scale };
                    if (p.y < TITLEBAR_H) {
                        const btn = titlebarHitButton(ctx.?, p);
                        if (btn == BTN_MAX) return w32.windows_and_messaging.HTMAXBUTTON;
                        if (btn != BTN_NONE) return w32.windows_and_messaging.HTCLIENT;
                        return w32.windows_and_messaging.HTCAPTION;
                    }
                }
                return w32.windows_and_messaging.HTCLIENT;
            }
        },
        w32.windows_and_messaging.WM_NCRBUTTONUP => {
            // 标题栏右键：系统菜单（标准行为，§5.9）。
            if (ctx != null and ctx.?.titlebar_active and w_param == w32.windows_and_messaging.HTCAPTION) {
                const raw: i64 = @bitCast(l_param);
                const sx: i16 = @truncate(raw);
                const sy: i16 = @truncate(raw >> 16);
                showSystemMenu(ctx.?, sx, sy);
                return 0;
            }
        },
        // —— 最大化按钮（HTMAXBUTTON，§5.9）——
        // Snap Layouts 悬停面板由 DWM 据 WM_NCHITTEST 触发，与按下无关。
        // 按下/抬起必须完全自处理、不交 DefWindowProcW：系统对 HTMAXBUTTON 的按下会
        // 捕获鼠标进入 Snap 预览，导致 WM_NCLBUTTONUP 不再发给本窗口（点击永远不触发）。
        w32.windows_and_messaging.WM_NCMOUSEMOVE => {
            if (ctx != null and ctx.?.titlebar_active) {
                const new_hover: i8 = if (w_param == w32.windows_and_messaging.HTMAXBUTTON) BTN_MAX else BTN_NONE;
                if (new_hover != ctx.?.tb_hover) {
                    ctx.?.tb_hover = new_hover;
                    ctx.?.tb_dirty = true;
                    _ = w32.user32.InvalidateRect(hwnd, null, 0);
                }
            }
            return w32.user32.DefWindowProcW(hwnd, u_msg, w_param, l_param);
        },
        w32.windows_and_messaging.WM_NCLBUTTONDOWN => {
            if (ctx != null and ctx.?.titlebar_active and w_param == w32.windows_and_messaging.HTMAXBUTTON) {
                ctx.?.tb_pressed = BTN_MAX;
                ctx.?.tb_dirty = true;
                _ = w32.user32.InvalidateRect(hwnd, null, 0);
                return 0; // 不交系统：避免 Snap 预览捕获鼠标吞掉抬起事件
            }
            return w32.user32.DefWindowProcW(hwnd, u_msg, w_param, l_param);
        },
        w32.windows_and_messaging.WM_NCLBUTTONUP => {
            if (ctx != null and ctx.?.titlebar_active and ctx.?.tb_pressed == BTN_MAX) {
                ctx.?.tb_pressed = BTN_NONE;
                ctx.?.tb_dirty = true;
                _ = w32.user32.InvalidateRect(hwnd, null, 0);
                // 自定义标题栏移除标准栏后系统不执行 HTMAXBUTTON 点击，需手动最大化/恢复。
                titlebarAction(ctx.?, BTN_MAX);
                return 0;
            }
            return w32.user32.DefWindowProcW(hwnd, u_msg, w_param, l_param);
        },
        w32.windows_and_messaging.WM_SETFOCUS => {
            if (ctx != null) {
                // 重新激活：启用输入法；若焦点是 Edit，恢复光标定时器/系统 caret。
                ctx.?.ime.activate();
                syncCaretTimer(ctx.?);
            }
            return 0;
        },
        w32.windows_and_messaging.WM_KILLFOCUS => {
            if (ctx != null) {
                // 失活：停止闪烁 + 销毁系统 caret + 停用 IME（强制完成组合）+ 取消 Edit 焦点。
                if (ctx.?.caret_timer) |h| ctx.?.ticker.clearTimer(h);
                ctx.?.caret_timer = null;
                _ = w32.user32.DestroyCaret();
                syncTickTimer(ctx.?); // 无活跃工作则杀惰性唤醒定时器。
                ctx.?.ime.deactivate();
                // 失活时若 Edit 在组合：清理组合状态；并取消焦点（不再高亮选中）。
                if (ctx.?.tree.focus) |f| {
                    if (f.widget == .edit) {
                        if (f.widget.edit.composing) {
                            var ev = event.Event{ .ime_compose = .{ .text = "" } };
                            _ = ctx.?.tree.dispatch(&ev);
                        }
                        ctx.?.tree.setFocus(null);
                    }
                }
                // 立即重绘去掉 Edit 高亮（仅标脏不会立刻刷新）。
                _ = w32.user32.InvalidateRect(hwnd, null, 0);
            }
            return 0;
        },
        w32.windows_and_messaging.WM_ERASEBKGND => {
            // 启动瞬间（ctx==null）：走 DefWindowProc，用类画刷（主题 bg_window）填充，
            // 窗口一显示即暗色，杜绝白屏；此后背景由 D2D 每帧 Clear 负责，
            // 拦截系统擦除防运行期闪烁。
            if (ctx != null) return 1;
        },
        w32.windows_and_messaging.WM_PAINT => {
            // 首帧：ctx 尚未挂载（CreateWindow 在 SetWindowLongPtr 之前不发 WM_PAINT）。
            if (ctx != null) {
                // 验证区域：由我们全量绘制。
                var ps: w32.gdi.PAINTSTRUCT = undefined;
                _ = w32.user32.BeginPaint(hwnd, &ps);
                renderFrame(ctx.?);
                _ = w32.user32.EndPaint(hwnd, &ps);
                return 0;
            }
        },
        // 光标形态：客户端内 Edit 控件 → I-beam，其余 → 箭头；标题栏/边框交系统默认。
        w32.windows_and_messaging.WM_SETCURSOR => {
            if (ctx != null and @as(u16, @truncate(@as(u64, @bitCast(l_param)))) == w32.windows_and_messaging.HTCLIENT) {
                const scale = ctx.?.device.?.dpi_scale;
                var pt = w32.foundation.POINT{ .x = 0, .y = 0 };
                _ = w32.user32.GetCursorPos(&pt);
                if (w32.user32.ScreenToClient(hwnd, &pt) != 0) {
                    const p = geometry.Point{ .x = @as(f32, @floatFromInt(pt.x)) / scale, .y = @as(f32, @floatFromInt(pt.y)) / scale };
                    const over_edit = if (node.Tree.hitTest(ctx.?.tree.root, p)) |hit| hit.widget == .edit else false;
                    _ = w32.user32.SetCursor(w32.user32.LoadCursorW(null, if (over_edit) w32.windows_and_messaging.IDC_IBEAM else w32.windows_and_messaging.IDC_ARROW));
                    return 1;
                }
            }
            return w32.user32.DefWindowProcW(hwnd, u_msg, w_param, l_param);
        },
        w32.windows_and_messaging.WM_APP + 1 => {
            // dipui 任务（§5.9 消息归属表）：跨线程 post 的唤醒。
            if (ctx != null) {
                ctx.?.post_bridge.drainTasks();
                // 任务（如快照 applier）可能更新树：请求重绘。
                _ = w32.user32.InvalidateRect(hwnd, null, 0);
            }
            return 0;
        },
        // —— WM_MOUSE 系列：input.zig 转成 Event（窗口 DIP 坐标）→ tree.dispatch ——
        w32.windows_and_messaging.WM_MOUSEMOVE,
        w32.windows_and_messaging.WM_LBUTTONDOWN,
        w32.windows_and_messaging.WM_LBUTTONUP,
        w32.windows_and_messaging.WM_RBUTTONDOWN,
        w32.windows_and_messaging.WM_RBUTTONUP,
        w32.windows_and_messaging.WM_MBUTTONDOWN,
        w32.windows_and_messaging.WM_MBUTTONUP,
        w32.windows_and_messaging.WM_LBUTTONDBLCLK,
        w32.windows_and_messaging.WM_RBUTTONDBLCLK,
        w32.windows_and_messaging.WM_MBUTTONDBLCLK,
        => {
            if (ctx != null) {
                // 标题栏按钮（§5.9）：先在顶栏命中逻辑中处理，命中按钮则不交给树。
                if (ctx.?.titlebar_active) {
                    const tb_scale = ctx.?.device.?.dpi_scale;
                    const p = clientPointDip(l_param, tb_scale);
                    const btn = titlebarHitButton(ctx.?, p);
                    switch (u_msg) {
                        w32.windows_and_messaging.WM_LBUTTONDOWN => {
                            if (btn != BTN_NONE) {
                                ctx.?.tb_pressed = btn;
                                ctx.?.tb_hover = btn;
                                _ = w32.user32.SetCapture(hwnd);
                                _ = w32.user32.InvalidateRect(hwnd, null, 0);
                                return 0;
                            }
                        },
                        w32.windows_and_messaging.WM_LBUTTONUP => {
                            if (ctx.?.tb_pressed != BTN_NONE) {
                                if (btn == ctx.?.tb_pressed) titlebarAction(ctx.?, @intCast(btn));
                                ctx.?.tb_pressed = BTN_NONE;
                                ctx.?.tb_hover = BTN_NONE;
                                _ = w32.user32.ReleaseCapture();
                                _ = w32.user32.InvalidateRect(hwnd, null, 0);
                                return 0;
                            }
                        },
                        w32.windows_and_messaging.WM_MOUSEMOVE => {
                            if (btn != ctx.?.tb_hover) {
                                ctx.?.tb_hover = btn;
                                _ = w32.user32.InvalidateRect(hwnd, null, 0);
                            }
                            // 拖动中（已捕获）：吞掉，避免树收到越界指针事件。
                            if (ctx.?.tb_pressed != BTN_NONE) return 0;
                        },
                        w32.windows_and_messaging.WM_LBUTTONDBLCLK => {
                            // 双击按钮 = 第二次点击；吞掉（首击已执行动作，防二次切换）。
                            if (btn != BTN_NONE) return 0;
                        },
                        else => {},
                    }
                }
                const scale = ctx.?.device.?.dpi_scale;
                if (input_mod.pointerEvent(u_msg, l_param, scale)) |ev| {
                    var e = ev;
                    _ = ctx.?.tree.dispatch(&e);
                    // 事件可能改树状态（hover/active/文本等）：请求重绘（保留模式）。
                    _ = w32.user32.InvalidateRect(hwnd, null, 0);
                    // WM_MOUSEMOVE 不重置光标闪烁相位——否则鼠标悬停时 blink 恒 true，光标不闪。
                    if (u_msg != w32.windows_and_messaging.WM_MOUSEMOVE) syncCaretTimer(ctx.?);
                }
            }
            return 0;
        },
        // —— WM_MOUSEWHEEL：滚轮（§6）→ Wheel 事件 → tree.dispatch ——
        w32.windows_and_messaging.WM_MOUSEWHEEL => {
            if (ctx != null) {
                const scale = ctx.?.device.?.dpi_scale;
                if (input_mod.wheelEvent(hwnd, w_param, l_param, scale)) |ev| {
                    var e = ev;
                    _ = ctx.?.tree.dispatch(&e);
                    _ = w32.user32.InvalidateRect(hwnd, null, 0);
                }
            }
            return 0;
        },
        // —— WM_KEYDOWN/UP：input.zig；Tab 走焦点链，其余给 focus 节点 ——
        w32.windows_and_messaging.WM_KEYDOWN,
        w32.windows_and_messaging.WM_KEYUP,
        w32.windows_and_messaging.WM_SYSKEYDOWN,
        w32.windows_and_messaging.WM_SYSKEYUP,
        => {
            if (ctx != null) {
                if (input_mod.keyEvent(u_msg, w_param)) |ev| {
                    var e = ev;
                    _ = ctx.?.tree.dispatch(&e);
                    // 焦点变化等：请求重绘（保留模式）。
                    _ = w32.user32.InvalidateRect(hwnd, null, 0);
                    syncCaretTimer(ctx.?);
                }
            }
            return 0;
        },
        // —— WM_CHAR：text_input 的唯一来源（§5.9）；禁止从 KEYDOWN 推断字符 ——
        w32.windows_and_messaging.WM_CHAR => {
            if (ctx != null) {
                // wParam 为 UTF-16 code unit；代理对分两次到达，需累积（emoji）。
                const code: u16 = @truncate(w_param);
                // 控制字符（Tab/Backspace/Enter 等）不是文本输入：WM_KEYDOWN 已处理
                // （焦点环/退格）。禁止在此作为 text_input 插入（§5.9）。
                if (code < 0x20) {
                    ctx.?.surrogate_high = 0;
                    return 0;
                }
                if (code >= 0xD800 and code <= 0xDBFF) {
                    ctx.?.surrogate_high = code; // 暂存高代理。
                    return 0;
                }
                var cp: u21 = undefined;
                if (code >= 0xDC00 and code <= 0xDFFF and ctx.?.surrogate_high != 0) {
                    cp = 0x10000 + (@as(u21, ctx.?.surrogate_high - 0xD800) << 10) + (code - 0xDC00);
                    ctx.?.surrogate_high = 0;
                } else {
                    ctx.?.surrogate_high = 0;
                    cp = code;
                }
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cp, &buf) catch return 0;
                var ev = event.Event{ .text_input = .{ .text = buf[0..len] } };
                _ = ctx.?.tree.dispatch(&ev);
                _ = w32.user32.InvalidateRect(hwnd, null, 0);
                syncCaretTimer(ctx.?);
            }
            return 0;
        },
        // —— WM_IME 系列：ime.zig 独占处理（§5.9/§5.10）——
        w32.windows_and_messaging.WM_IME_SETCONTEXT => {
            if (ctx != null) reportImeCaret(ctx.?);
            // 不清除 ISC 标志（清除组合窗标志会联动抑制微软拼音候选框）：
            // 组合窗隐藏靠 WM_IME_STARTCOMPOSITION 返回 0（§5.10）。
            return w32.user32.DefWindowProcW(hwnd, u_msg, w_param, l_param);
        },
        w32.windows_and_messaging.WM_IME_STARTCOMPOSITION => {
            if (ctx != null) reportImeCaret(ctx.?);
            // 必须返回 0：系统组合窗仅在 STARTCOMPOSITION 返回 0 时隐藏（§5.10）。
            return 0;
        },
        w32.windows_and_messaging.WM_IME_ENDCOMPOSITION => {
            if (ctx != null) {
                var ev = event.Event{ .ime_compose = .{ .text = "" } };
                _ = ctx.?.tree.dispatch(&ev);
                _ = w32.user32.InvalidateRect(hwnd, null, 0);
            }
            return 0;
        },
        w32.windows_and_messaging.WM_IME_COMPOSITION => {
            if (ctx != null) {
                // 结果串 → text_input（提交）；组合串 → ime_compose（§5.10）。
                if (ctx.?.ime.compositionEvent(std.heap.page_allocator, l_param)) |ev| {
                    defer freeImeEventText(ev);
                    var e = ev;
                    _ = ctx.?.tree.dispatch(&e);
                    _ = w32.user32.InvalidateRect(hwnd, null, 0);
                    syncCaretTimer(ctx.?);
                }
                // 组合串变化后刷新系统光标/候选框位置。
                reportImeCaret(ctx.?);
            }
            return 0;
        },
        // —— WM_TIMER：惰性唤醒定时（§5.13），推进 Ticker（定时回调 + 动画），有则重绘——
        w32.windows_and_messaging.WM_TIMER => {
            if (ctx != null and w_param == TIMER_TICK) {
                const c = ctx.?;
                const step = c.ticker.advance(nowSeconds());
                if (step.moved) _ = w32.user32.InvalidateRect(hwnd, null, 0);
                syncTickTimer(c);
            }
            return 0;
        },
        w32.windows_and_messaging.WM_SIZE => {
            if (ctx != null and w_param != w32.windows_and_messaging.SIZE_MINIMIZED) {
                // lParam：低 16 位 = 宽度，高 16 位 = 高度（不是 32 位取整）。
                const w: u16 = @truncate(@as(u64, @bitCast(l_param)));
                const h: u16 = @truncate(@as(u64, @bitCast(l_param)) >> 16);
                ctx.?.device.?.resize(w, h) catch {};
                ctx.?.tree.root.invalidateMeasure();
                // 触发重绘。
                _ = w32.user32.InvalidateRect(hwnd, null, 0);
            }
            return 0;
        },
        w32.windows_and_messaging.WM_DPICHANGED => {
            // wParam 高 16 位 = Y-DPI。per-monitor v2 下系统给出建议矩形。
            const dpi: u16 = @truncate(@as(u64, @bitCast(w_param)) >> 16);
            if (dpi > 0) {
                ctx.?.device.?.setDpi(@as(f32, @floatFromInt(dpi)) / 96.0);
            }
            // 应用系统建议矩形（WM_DPICHANGED 契约）。
            const rc_ptr: *const w32.RECT = @ptrFromInt(@as(usize, @bitCast(l_param)));
            _ = w32.user32.SetWindowPos(
                hwnd,
                null,
                rc_ptr.left,
                rc_ptr.top,
                rc_ptr.right - rc_ptr.left,
                rc_ptr.bottom - rc_ptr.top,
                .{ .NOZORDER = 1, .NOACTIVATE = 1 },
            );
            ctx.?.tree.root.invalidateMeasure();
            _ = w32.user32.InvalidateRect(hwnd, null, 0);
            return 0;
        },
        else => {},
    }
    return w32.user32.DefWindowProcW(hwnd, u_msg, w_param, l_param);
}

// —— 编译期自检：确保引用的包符号在 zigwin32 中真实存在 ——
test "window/win32 symbols exist" {
    _ = w32.user32.CreateWindowExW;
    _ = w32.user32.RegisterClassExW;
    _ = w32.user32.DefWindowProcW;
    _ = w32.user32.GetMessageW;
    _ = w32.user32.DispatchMessageW;
    _ = w32.user32.TranslateMessage;
    _ = w32.user32.PostQuitMessage;
    _ = w32.user32.ShowWindow;
    _ = w32.user32.SetWindowLongPtrW;
    _ = w32.user32.GetWindowLongPtrW;
    _ = w32.user32.BeginPaint;
    _ = w32.user32.EndPaint;
    _ = w32.user32.InvalidateRect;
    _ = w32.user32.SetWindowPos;
    _ = w32.user32.LoadCursorW;
    _ = w32.windows_and_messaging.SWP_NOZORDER;
    _ = w32.windows_and_messaging.SWP_NOACTIVATE;
    _ = w32.windows_and_messaging.IDC_ARROW;
    _ = w32.windows_and_messaging.WM_DESTROY;
    _ = w32.windows_and_messaging.WM_PAINT;
    _ = w32.windows_and_messaging.WM_SIZE;
    _ = w32.windows_and_messaging.WM_DPICHANGED;
    _ = w32.windows_and_messaging.WM_APP;
    _ = w32.windows_and_messaging.WM_MOUSEMOVE;
    _ = w32.windows_and_messaging.WM_LBUTTONDOWN;
    _ = w32.windows_and_messaging.WM_LBUTTONUP;
    _ = w32.windows_and_messaging.WM_KEYDOWN;
    _ = w32.windows_and_messaging.WM_KEYUP;
    _ = w32.windows_and_messaging.WM_SYSKEYDOWN;
    _ = w32.windows_and_messaging.WM_SYSKEYUP;
    _ = w32.user32.GetKeyState;
    _ = w32.windows_and_messaging.SIZE_MINIMIZED;
    _ = w32.windows_and_messaging.WS_OVERLAPPEDWINDOW;
    _ = w32.windows_and_messaging.SW_SHOW;
    _ = w32.dwmapi.DwmSetWindowAttribute;
    _ = w32.dwm.DWMWINDOWATTRIBUTE.USE_IMMERSIVE_DARK_MODE;
    _ = w32.kernel32.GetModuleHandleW;
    _ = w32.kernel32.GetLastError;
    _ = w32.foundation.ERROR_CLASS_ALREADY_EXISTS;
    _ = w32.windows_and_messaging.WNDCLASSEXW;
    _ = w32.windows_and_messaging.MSG;
    _ = w32.windows_and_messaging.WINDOW_LONG_PTR_INDEX.P_USERDATA;
    _ = w32.direct2d.IID_ID2D1Factory;
    _ = w32.direct_write.IID_IDWriteFactory;
}
