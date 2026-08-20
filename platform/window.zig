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
const event = @import("../core/event.zig");
const widget = @import("../core/widget.zig");
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

/// 平台选项。
pub const Options = struct {
    /// 窗口标题（UTF-16，调用方持有）。
    title: [:0]const u16,
    /// 初始客户区宽度（物理像素）。
    width: i32 = 960,
    /// 初始客户区高度（物理像素）。
    height: i32 = 600,
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
    /// 光标闪烁定时器是否已创建（§5.8：只在聚焦时创建一次，避免每次事件重置导致不闪烁）。
    caret_timer_active: bool = false,
    /// 透明位图（系统 caret 用：全 0 单色位图，显示不可见但 GetCaretPos 定位有效）。
    caret_bmp: ?w32.gdi.HBITMAP = null,
    /// WM_CHAR 代理对暂存（emoji 等，§5.9：WM_CHAR 是 text_input 唯一来源）。
    surrogate_high: u16 = 0,
};

/// 光标闪烁定时器 ID（§5.8：WM_TIMER 530ms，仅 focus 时启动）。
const TIMER_CARET: usize = 1;

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
            log.err("RegisterClassExW failed, error={s}", .{@tagName(w32.kernel32.GetLastError())});
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
        log.err("CreateWindowExW failed, error={s}", .{@tagName(w32.kernel32.GetLastError())});
        return error.CreateWindowFailed;
    };

    // 4. 暗色标题栏（Win10 1809+，DWM 属性 20 = USE_IMMERSIVE_DARK_MODE）。
    setDarkTitleBar(hwnd);

    // 5. 创建渲染设备（D2D 工厂 + render target）。
    const device = try device_mod.Device.init(std.heap.page_allocator, hwnd);
    defer device.deinit();
    tree.text_system = text_mod.asTextSystem(&device.text_system);

    // 5b. 创建跨线程任务桥（§5.12），绑定 hwnd。
    const bridge = try std.heap.page_allocator.create(post_mod.PostBridge);
    bridge.* = post_mod.PostBridge.init(std.heap.page_allocator);
    bridge.hwnd = hwnd;
    if (opts.post_out) |out| out.* = bridge;
    defer {
        bridge.deinit();
        std.heap.page_allocator.destroy(bridge);
    }

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
    };
    _ = w32.user32.SetWindowLongPtrW(hwnd, .P_USERDATA, @bitCast(@intFromPtr(&ctx)));
    defer _ = w32.user32.DestroyWindow(hwnd);

    // 7. 先渲染首帧再显示：否则窗口先以默认白色客户区呈现一瞬（启动白屏闪烁）。
    //    显示后 WM_PAINT 会再正常重绘一帧，内容一致。
    renderFrame(&ctx);
    _ = w32.user32.ShowWindow(hwnd, w32.windows_and_messaging.SW_SHOW);

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

/// 执行一帧绘制（WM_PAINT 与首帧共用）。
fn renderFrame(ctx: *WindowCtx) void {
    const dev = ctx.device.?;
    // 确保 render target 就绪（窗口显示后首次绘制才真正创建）。
    if (!dev.ensureTarget()) return;
    const client = getClientSizeDips(dev);

    // 惰性布局：绘制前必须调用（§5.3）。
    ctx.tree.ensureLayout(client);

    const pc = ctx.painter.ctx(ctx.theme_ref);
    dev.beginFrame();
    // 清背景（窗口 token）。
    dev.rt.?.ID2D1RenderTarget.Clear(&toD2DColor(ctx.theme_ref.bg_window));
    ctx.tree.paint(pc);
    const need_retry = dev.endFrame();
    if (need_retry) {
        // 设备丢失：endFrame 已重建 render target，重绘一次。
        dev.beginFrame();
        dev.rt.?.ID2D1RenderTarget.Clear(&toD2DColor(ctx.theme_ref.bg_window));
        ctx.tree.paint(pc);
        _ = dev.endFrame();
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

/// 焦点是 Edit 时启动光标闪烁定时器，否则销毁（§5.8：WM_TIMER 530ms，仅 focus）。
/// 定时器只在聚焦时创建一次——WM_TIMER 持续翻转实现闪烁；操作只重置相位为可见
/// （立即显示光标），不重置定时器（否则连续操作期间不闪烁）。
/// 同时创建系统 caret（隐藏，仅供 IME 的 GetCaretPos 定位候选框，§5.10）。
fn syncCaretTimer(ctx: *WindowCtx) void {
    const is_edit = if (ctx.tree.focus) |f| f.widget == .edit else false;
    if (is_edit) {
        ctx.tree.caret_blink_on = true; // 操作后立即可见。
        if (!ctx.caret_timer_active) {
            _ = w32.user32.SetTimer(ctx.hwnd, TIMER_CARET, 530, null);
            ctx.caret_timer_active = true;
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
        if (ctx.caret_timer_active) {
            _ = w32.user32.KillTimer(ctx.hwnd, TIMER_CARET);
            ctx.caret_timer_active = false;
        }
        _ = w32.user32.DestroyCaret();
        if (ctx.caret_bmp) |bmp| {
            _ = w32.gdi32.DeleteObject(bmp);
            ctx.caret_bmp = null;
        }
    }
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
    const r = dev.rt.?.ID2D1RenderTarget.GetSize();
    return .{ .width = r.width / dev.dpi_scale, .height = r.height / dev.dpi_scale };
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
                if (ctx.?.caret_timer_active) {
                    _ = w32.user32.KillTimer(hwnd, TIMER_CARET);
                    ctx.?.caret_timer_active = false;
                }
                _ = w32.user32.DestroyCaret();
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
        // —— WM_TIMER：光标闪烁（§5.8，仅 focus 时 530ms）——
        w32.windows_and_messaging.WM_TIMER => {
            if (ctx != null and w_param == TIMER_CARET) {
                ctx.?.tree.caret_blink_on = !ctx.?.tree.caret_blink_on;
                _ = w32.user32.InvalidateRect(hwnd, null, 0);
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
