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
    /// 修饰键位（event.Mod 按位或）。
    mods: u32 = 0,
    button: Button = .left,
    /// 是否双击（WM_LBUTTONDBLCLK；Edit 双击选词用）。
    double: bool = false,
};

/// 鼠标按钮。
pub const Button = enum(u8) { none = 0, left = 1, right = 2, middle = 4 };

/// 键盘事件载荷：虚拟键码 + 修饰键位。
pub const Key = struct {
    vk: u32 = 0,
    mods: u32 = 0,
};

/// 虚拟键码（Win32 VK_* 子集）。值对齐 Win32。
pub const VK = struct {
    /// 退格键。
    pub const BACKSPACE: u32 = 0x08;
    /// Tab 键（焦点环，§5.3）。
    pub const TAB: u32 = 0x09;
    /// 回车键。
    pub const RETURN: u32 = 0x0D;
    /// Shift 键。
    pub const SHIFT: u32 = 0x10;
    /// Ctrl 键。
    pub const CONTROL: u32 = 0x11;
    /// Alt/Menu 键。
    pub const MENU: u32 = 0x12;
    /// 空格键。
    pub const SPACE: u32 = 0x20;
    /// End 键（单行编辑框 = 行尾）。
    pub const END: u32 = 0x23;
    /// Home 键（单行编辑框 = 行首）。
    pub const HOME: u32 = 0x24;
    /// 左方向键。
    pub const LEFT: u32 = 0x25;
    /// 上方向键（单行编辑框 = 行首）。
    pub const UP: u32 = 0x26;
    /// 右方向键。
    pub const RIGHT: u32 = 0x27;
    /// 下方向键（单行编辑框 = 行尾）。
    pub const DOWN: u32 = 0x28;
    /// Delete 键。
    pub const DELETE: u32 = 0x2E;
};

/// 修饰键位（mods 字段）。
pub const Mod = struct {
    /// Shift 位。
    pub const shift: u32 = 1 << 0;
    /// Ctrl 位。
    pub const control: u32 = 1 << 1;
    /// Alt 位。
    pub const alt: u32 = 1 << 2;
};

/// 文本输入载荷（WM_CHAR / IME 产生的 UTF-8 串）。
pub const TextInput = struct {
    text: []const u8 = "",
};

/// IME 组合串事件（§5.10）：组合内容变化时派发。组合串的 arena 生命周期
/// = 当前事件，Edit 需留存须自行拷贝（§5.10）。
pub const ImeCompose = struct {
    /// 当前组合串（UTF-8，事件期有效）。
    text: []const u8 = "",
};

/// 滚轮事件载荷（§6）：鼠标位置 + 滚动行数。
pub const Wheel = struct {
    /// 鼠标位置（窗口 DIP），用于定位目标（hit test）。
    pos: geo.Point = .{},
    /// 滚动行数（f32 以兼容高精度触控板增量）。**正 = 视口向文档末尾（offset 增大）**，
    /// 负 = 向文档开头（offset 减小）。WM_MOUSEWHEEL 归一化：−delta/120 × 3
    /// （Windows 约定：滚轮向上 delta>0 → 负，即向开头）。
    lines: f32 = 0,
};

/// 事件联合。新增事件类型时，node.dispatch 的 switch 必须穷尽（编译器强制）。
pub const Event = union(enum) {
    pointer_down: Pointer,
    pointer_up: Pointer,
    pointer_move: Pointer,
    key_down: Key,
    key_up: Key,
    text_input: TextInput,
    /// IME 组合串变化（§5.10）。
    ime_compose: ImeCompose,
    /// 滚轮滚动（§6）。
    wheel: Wheel,
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
