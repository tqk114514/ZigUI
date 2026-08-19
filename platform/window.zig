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
const dispatch = @import("../widgets/dispatch.zig");
const device_mod = @import("../render/device.zig");
const painter_mod = @import("../render/painter.zig");
const text_mod = @import("../render/text.zig");
const theme = @import("../theme.zig");

const log = std.log.scoped(.platform);

/// 消息泵返回值。目前仅"窗口已关闭"一种退出路径。
pub const RunResult = enum { closed };

/// 平台选项。
pub const Options = struct {
    title: [:0]const u16,
    width: i32 = 960,
    height: i32 = 600,
    /// 主题引用（§5.12：theme 是共享常量）。
    theme_ref: *const theme.Theme = &theme.dark,
};

/// 每窗口的上下文，经 GWLP_USERDATA 挂到 HWND，wndProc 取回。
const WindowCtx = struct {
    hwnd: w32.HWND,
    running: bool = true,
    tree: *node.Tree,
    device: ?*device_mod.Device = null,
    painter: painter_mod.D2DPainter = undefined,
    theme_ref: *const theme.Theme,
};

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

    // 2. 注册窗口类。
    const hinst = w32.kernel32.GetModuleHandleW(null) orelse return error.GetModuleHandleFailed;
    const wnd_class = w32.windows_and_messaging.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.windows_and_messaging.WNDCLASSEXW),
        .style = .{},
        .lpfnWndProc = wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinst,
        .hIcon = null,
        // 客户区默认箭头光标：鼠标从非客户区（边框）移入时，系统据 hCursor 恢复箭头，
        // 避免残留边框拉伸光标（问题 2）。
        .hCursor = w32.user32.LoadCursorW(null, w32.windows_and_messaging.IDC_ARROW),
        .hbrBackground = null,
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

    // 6. 显示并进入消息泵。
    _ = w32.user32.ShowWindow(hwnd, w32.windows_and_messaging.SW_SHOW);
    defer _ = w32.user32.DestroyWindow(hwnd);

    var ctx = WindowCtx{
        .hwnd = hwnd,
        .tree = tree,
        .device = device,
        .painter = .{ .device = device },
        .theme_ref = opts.theme_ref,
    };
    _ = w32.user32.SetWindowLongPtrW(hwnd, .P_USERDATA, @bitCast(@intFromPtr(&ctx)));

    // 首帧：触发一次 WM_PAINT（window 初始尺寸）。
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
}

/// 客户端尺寸（DIP）：物理像素 / dpi_scale。
fn getClientSizeDips(dev: *device_mod.Device) geometry.Size {
    const r = dev.rt.?.ID2D1RenderTarget.GetSize();
    return .{ .width = r.width / dev.dpi_scale, .height = r.height / dev.dpi_scale };
}

fn toD2DColor(c: theme.Color) w32.direct2d.common.D2D_COLOR_F {
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a };
}

/// 窗口过程：M0 只负责退出与请求重绘。
fn wndProc(hwnd: w32.HWND, u_msg: u32, w_param: w32.WPARAM, l_param: w32.LPARAM) callconv(.winapi) w32.LRESULT {
    const ctx: ?*WindowCtx = @ptrFromInt(@as(usize, @bitCast(w32.user32.GetWindowLongPtrW(hwnd, .P_USERDATA))));
    switch (u_msg) {
        w32.windows_and_messaging.WM_DESTROY => {
            w32.user32.PostQuitMessage(0);
            return 0;
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
