//! platform/input.zig —— Win32 鼠标/键盘消息 → core Event（规则 §5.9 消息归属）。
//!
//! 模块不变量：
//! - 本模块是 WM_MOUSE / WM_KEY* 消息 → core.Event 的唯一转换点；
//! - 坐标：LPARAM 客户端物理像素 → 窗口 DIP（除以 dpi_scale）；物理像素只存在于本边界（L3）；
//! - WM_CHAR 是 text_input 唯一来源（§5.9），本模块不负责；
//! - 修饰键从 GetKeyState 读取（SHIFT/CTRL/ALT），写入 Mod 位。

const std = @import("std");
const w32 = @import("win32.zig");
const wm = w32.windows_and_messaging;
const event = @import("../core/event.zig");

/// 由 WM_MOUSEMOVE/WM_LBUTTONDOWN 等消息构造 Pointer 事件。
/// `scale` = 当前 DPI 缩放（物理像素 / DIP）。返回 null 表示无需分发。
pub fn pointerEvent(u_msg: u32, l_param: w32.LPARAM, scale: f32) ?event.Event {
    // lParam：低 16 位 = 客户端 x（有符号），高 16 位 = 客户端 y（有符号）。物理像素。
    const x_px: i16 = @bitCast(@as(u16, @truncate(@as(u64, @bitCast(l_param)))));
    const y_px: i16 = @bitCast(@as(u16, @truncate(@as(u64, @bitCast(l_param)) >> 16)));
    const p = event.Pointer{
        .pos = .{ .x = @as(f32, @floatFromInt(x_px)) / scale, .y = @as(f32, @floatFromInt(y_px)) / scale },
        .button = switch (u_msg) {
            wm.WM_LBUTTONDOWN, wm.WM_LBUTTONUP, wm.WM_LBUTTONDBLCLK => .left,
            wm.WM_RBUTTONDOWN, wm.WM_RBUTTONUP, wm.WM_RBUTTONDBLCLK => .right,
            wm.WM_MBUTTONDOWN, wm.WM_MBUTTONUP, wm.WM_MBUTTONDBLCLK => .middle,
            else => .left, // WM_MOUSEMOVE 无按钮，left 仅为占位
        },
        .double = switch (u_msg) {
            wm.WM_LBUTTONDBLCLK, wm.WM_RBUTTONDBLCLK, wm.WM_MBUTTONDBLCLK => true,
            else => false,
        },
    };
    return switch (u_msg) {
        wm.WM_MOUSEMOVE => event.Event{ .pointer_move = p },
        wm.WM_LBUTTONDOWN, wm.WM_RBUTTONDOWN, wm.WM_MBUTTONDOWN => event.Event{ .pointer_down = p },
        wm.WM_LBUTTONUP, wm.WM_RBUTTONUP, wm.WM_MBUTTONUP => event.Event{ .pointer_up = p },
        wm.WM_LBUTTONDBLCLK, wm.WM_RBUTTONDBLCLK, wm.WM_MBUTTONDBLCLK => event.Event{ .pointer_down = p },
        else => null,
    };
}

/// 由 WM_KEYDOWN / WM_KEYUP 构造 Key 事件（含修饰键位）。
pub fn keyEvent(u_msg: u32, w_param: w32.WPARAM) ?event.Event {
    const key = event.Key{
        .vk = @intCast(w_param),
        .mods = readMods(),
    };
    return switch (u_msg) {
        wm.WM_KEYDOWN, wm.WM_SYSKEYDOWN => event.Event{ .key_down = key },
        wm.WM_KEYUP, wm.WM_SYSKEYUP => event.Event{ .key_up = key },
        else => null,
    };
}

/// 由 WM_MOUSEWHEEL 构造 Wheel 事件（§6）。
/// lParam = 鼠标屏幕坐标（物理像素）→ ScreenToClient → DIP；
/// wParam 高 16 位 = delta（±120/档）。Windows 约定：滚轮向上（delta>0）看向文档
/// 开头 → offset 减小，故取反为行数：−delta/120 × 3（正 = 视口向末尾，offset 增大）。
pub fn wheelEvent(hwnd: w32.HWND, w_param: w32.WPARAM, l_param: w32.LPARAM, scale: f32) ?event.Event {
    const sx: i16 = @bitCast(@as(u16, @truncate(@as(u64, @bitCast(l_param)))));
    const sy: i16 = @bitCast(@as(u16, @truncate(@as(u64, @bitCast(l_param)) >> 16)));
    var pt = w32.POINT{ .x = sx, .y = sy };
    _ = w32.user32.ScreenToClient(hwnd, &pt);
    const delta: i16 = @bitCast(@as(u16, @truncate(@as(u64, @bitCast(w_param)) >> 16)));
    return .{ .wheel = .{
        .pos = .{ .x = @as(f32, @floatFromInt(pt.x)) / scale, .y = @as(f32, @floatFromInt(pt.y)) / scale },
        .lines = -@as(f32, @floatFromInt(delta)) / 120.0 * 3.0,
    } };
}

/// 读取当前修饰键状态。
fn readMods() u32 {
    var m: u32 = 0;
    if (isDown(event.VK.SHIFT)) m |= event.Mod.shift;
    if (isDown(event.VK.CONTROL)) m |= event.Mod.control;
    if (isDown(event.VK.MENU)) m |= event.Mod.alt;
    return m;
}

fn isDown(vk: u32) bool {
    // GetKeyState 返回 SHORT(i16)，最高位 = 按下。
    const state: i16 = w32.user32.GetKeyState(@intCast(vk));
    const bits: u16 = @bitCast(state);
    return (bits & 0x8000) != 0;
}
