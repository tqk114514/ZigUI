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
    /// 是否双击（WM_LBUTTONDBLCLK；Edit 双击选词用，M5）。
    double: bool = false,
};

/// 鼠标按钮。
pub const Button = enum(u8) { none = 0, left = 1, right = 2, middle = 4 };

/// 键盘事件载荷（M3 深化按键枚举；M1 先传虚拟键码）。
pub const Key = struct {
    vk: u32 = 0,
    mods: u32 = 0,
};

/// 虚拟键码（Win32 VK_* 子集，M3/M5 所需）。值对齐 Win32。
pub const VK = struct {
    pub const BACKSPACE: u32 = 0x08;
    pub const TAB: u32 = 0x09;
    pub const RETURN: u32 = 0x0D;
    pub const SHIFT: u32 = 0x10;
    pub const CONTROL: u32 = 0x11;
    pub const MENU: u32 = 0x12;
    pub const SPACE: u32 = 0x20;
    pub const END: u32 = 0x23;
    pub const HOME: u32 = 0x24;
    pub const LEFT: u32 = 0x25;
    pub const UP: u32 = 0x26;
    pub const RIGHT: u32 = 0x27;
    pub const DOWN: u32 = 0x28;
    pub const DELETE: u32 = 0x2E;
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

/// IME 组合串事件（M5 §5.10）：组合内容变化时派发。组合串的 arena 生命周期
/// = 当前事件，Edit 需留存须自行拷贝（§5.10）。
pub const ImeCompose = struct {
    /// 当前组合串（UTF-8，事件期有效）。
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
    /// M5：IME 组合串变化（§5.10）。
    ime_compose: ImeCompose,
    focus_gained,
    focus_lost,
    custom: u32,
};

test "pointer default values" {
    // 默认 Pointer 坐标在原点，按钮为 left。
    const p = Pointer{};
    try std.testing.expect(geo.approxEq(0, p.pos.x));
    try std.testing.expect(p.button == .left);
}
