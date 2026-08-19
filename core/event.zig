//! core/event.zig —— 事件类型与路由（规则 §5.1/§5.3 事件部分）。
//!
//! 模块不变量：
//! - 本文件只定义事件载荷（纯数据）与常量，不 import node（避免环）；
//! - hit test 与冒泡的执行在 node.zig 的 Tree.dispatch 中完成；
//! - 指针事件坐标一律窗口 DIP（LPARAM→DIP 转换仅发生在 platform/ 边界）；
//! - handler 返回 true 停止冒泡（§5.3 dispatch）。

const std = @import("std");
const geo = @import("geometry.zig");

/// 指针事件载荷：窗口 DIP 坐标 + 状态位。
pub const Pointer = struct {
    pos: geo.Point = .{},
    /// 修饰键与按钮位（M3 触手把手补充具体枚举；M1 先留位）。
    mods: u32 = 0,
    button: Button = .left,
};

/// 鼠标按钮。
pub const Button = enum(u8) { none = 0, left = 1, right = 2, middle = 4 };

/// 键盘事件载荷（M3 深化按键枚举；M1 先传虚拟键码）。
pub const Key = struct {
    vk: u32 = 0,
    mods: u32 = 0,
};

/// 虚拟键码（Win32 VK_* 子集，M3 所需）。值对齐 Win32。
pub const VK = struct {
    pub const TAB: u32 = 0x09;
    pub const RETURN: u32 = 0x0D;
    pub const SHIFT: u32 = 0x10;
    pub const CONTROL: u32 = 0x11;
    pub const MENU: u32 = 0x12;
    pub const LEFT: u32 = 0x25;
    pub const UP: u32 = 0x26;
    pub const RIGHT: u32 = 0x27;
    pub const DOWN: u32 = 0x28;
    pub const SPACE: u32 = 0x20;
};

/// 修饰键位（mods 字段）。
pub const Mod = struct {
    pub const shift: u32 = 1 << 0;
    pub const control: u32 = 1 << 1;
    pub const alt: u32 = 1 << 2;
};

/// 文本输入载荷（M5 由 WM_CHAR / IME 产生的 UTF-8 串）。
pub const TextInput = struct {
    text: []const u8 = "",
};

/// 事件联合。新增事件类型时，node.dispatch 的 switch 必须穷尽（编译器强制）。
pub const Event = union(enum) {
    pointer_down: Pointer,
    pointer_up: Pointer,
    pointer_move: Pointer,
    key_down: Key,
    key_up: Key,
    text_input: TextInput,
    focus_gained,
    focus_lost,
    custom: u32,
};

/// 事件是否属于指针类（用于 dispatch 走 hit test 而非焦点链）。
pub fn isPointer(e: Event) bool {
    return switch (e) {
        .pointer_down, .pointer_up, .pointer_move => true,
        else => false,
    };
}

/// 事件是否为键盘类（走焦点链）。
pub fn isKey(e: Event) bool {
    return switch (e) {
        .key_down, .key_up => true,
        else => false,
    };
}

test "event classification" {
    try std.testing.expect(isPointer(.{ .pointer_down = .{} }));
    try std.testing.expect(!isPointer(.{ .key_down = .{} }));
    try std.testing.expect(isKey(.{ .key_down = .{} }));
    try std.testing.expect(!isKey(.{ .focus_gained = {} }));
    // 默认 Pointer 坐标在原点。
    const p = Pointer{};
    try std.testing.expect(geo.approxEq(0, p.pos.x));
    try std.testing.expect(p.button == .left);
}
