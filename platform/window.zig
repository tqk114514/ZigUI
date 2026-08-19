//! platform/window.zig —— 最小版窗口：窗口类注册 + 消息泵（M0）。
//!
//! 模块不变量（规则 §5.9）：
//! - 本模块是唯一创建/拥有 HWND 的地方；整个 UI 一个顶层 HWND（L2）；
//! - wndProc 只做消息归属分发；M0 阶段仅处理 WM_DESTROY/WM_CLOSE/WM_PAINT；
//! - Win32 调用失败：记日志、安全返回，绝不让消息泵崩溃（§4.2）。
//!
//! 启动序列（规则 §5.9）：SetProcessDpiAwarenessContext(per-monitor-v2) →
//! 注册窗口类 → 创建窗口 → DwmSetWindowAttribute 挂暗色标题栏 → 消息泵。

const std = @import("std");
const builtin = @import("builtin");
const w32 = @import("win32.zig");

const log = std.log.scoped(.platform);

/// 消息泵返回值。目前仅"窗口已关闭"一种退出路径。
pub const RunResult = enum { closed };

/// 平台选项：M0 仅标题与初始尺寸。
pub const Options = struct {
    title: [:0]const u16,
    width: i32 = 960,
    height: i32 = 600,
};

/// 每窗口的上下文，经 GWLP_USERDATA 挂到 HWND，wndProc 取回。
const WindowCtx = struct {
    hwnd: w32.HWND,
    running: bool = true,
};

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("zigui.m0");

/// 运行消息泵直到窗口关闭。
pub fn run(opts: Options) !RunResult {
    if (comptime builtin.os.tag != .windows) {
        @compileError("zigui is Windows-only (rule.md Non-goals)");
    }

    // 1. DPI 感知（per-monitor v2，免 manifest）。
    _ = w32.setProcessDpiAwarenessContextPerMonitorV2();

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
        .hCursor = null,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = class_name,
        .hIconSm = null,
    };
    if (w32.user32.RegisterClassExW(&wnd_class) == 0) {
        // 重复注册不是致命错误；其余失败则退出。
        if (w32.kernel32.GetLastError() != .ERROR_CLASS_ALREADY_EXISTS) {
            log.err("RegisterClassExW failed, error={s}", .{@tagName(w32.kernel32.GetLastError())});
            return error.RegisterClassFailed;
        }
    }

    // 3. 创建窗口（M0 采用可调整大小的主窗口样式）。
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

    // 5. 显示并进入消息泵。
    _ = w32.user32.ShowWindow(hwnd, w32.windows_and_messaging.SW_SHOW);
    defer _ = w32.user32.DestroyWindow(hwnd);

    // 挂上下文供 wndProc 使用。
    var ctx = WindowCtx{ .hwnd = hwnd };
    _ = w32.user32.SetWindowLongPtrW(hwnd, .P_USERDATA, @bitCast(@intFromPtr(&ctx)));

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

/// 窗口过程：M0 只负责退出与请求重绘。
fn wndProc(hwnd: w32.HWND, u_msg: u32, w_param: w32.WPARAM, l_param: w32.LPARAM) callconv(.winapi) w32.LRESULT {
    switch (u_msg) {
        w32.windows_and_messaging.WM_DESTROY => {
            w32.user32.PostQuitMessage(0);
            return 0;
        },
        w32.windows_and_messaging.WM_PAINT => {
            // M0 无绘制；直接验证区域，避免重绘风暴。
            var ps: w32.gdi.PAINTSTRUCT = undefined;
            _ = w32.user32.BeginPaint(hwnd, &ps);
            _ = w32.user32.EndPaint(hwnd, &ps);
            return 0;
        },
        else => {},
    }
    return w32.user32.DefWindowProcW(hwnd, u_msg, w_param, l_param);
}

// —— 编译期自检：确保引用的包符号在 zigwin32 中真实存在 ——
test "win32.zig re-exports exist" {
    _ = w32.user32.CreateWindowExW;
    _ = w32.user32.RegisterClassExW;
    _ = w32.user32.DefWindowProcW;
    _ = w32.user32.GetMessageW;
    _ = w32.user32.DispatchMessageW;
    _ = w32.user32.TranslateMessage;
    _ = w32.user32.PostQuitMessage;
    _ = w32.user32.ShowWindow;
    _ = w32.user32.SetWindowLongPtrW;
    _ = w32.user32.BeginPaint;
    _ = w32.user32.EndPaint;
    _ = w32.windows_and_messaging.WM_DESTROY;
    _ = w32.windows_and_messaging.WM_PAINT;
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
}
