//! core/widget.zig —— Widget tagged union 与各内建控件的**数据** struct（规则 §5.4）。
//!
//! 模块不变量：
//! - 本文件只有数据，无行为；paint/measure/事件处理在 widgets/*.zig（数据/行为分离）；
//! - 字符串一律为 `[]const u8` 切片，指向 Tree 的 arena（§4.3），本文件不拥有内存；
//! - 对 Widget union 的 switch 必须穷尽、禁 else（L8），由 widgets/dispatch.zig 保证；
//! - custom 变体是用户扩展唯一入口：ctx + vtable。

const std = @import("std");
const geo = @import("geometry.zig");
const layout = @import("layout.zig");

/// 各内建控件的数据 struct —— 均为纯数据，字段语义见 §5 各节。
pub const Box = struct {
    // 纯布局容器，不绘制；无额外数据。
};

/// 文本控件数据（M2 深化；M4 加 wrap/ellipsis）。
pub const Text = struct {
    text: []const u8,
    /// 超出可用宽度时换行（多行）。默认单行不换行。
    wrap: bool = false,
    /// 超宽时尾部省略号（单行）。与 wrap 互斥。
    ellipsis: bool = false,
};

/// 按钮控件数据（M3；M1 仅占位）。
pub const Button = struct {
    label: []const u8,
};

/// 编辑框控件数据（M5）。
///
/// 状态机（§5.8）：
///   normal ↔ has_selection ↔ composing(IME)
/// - buf 始终合法 UTF-8；caret/anchor 只落在码点边界（core/utf8 步进）；
/// - composing 期间 buf 与 caret 冻结，组合串显示在 caret 处（带下划线）；
/// - 组合提交合并为一步 undo（undo M6 交付，M5 先留位）。
pub const Edit = struct {
    /// 缓冲区（arena，始终合法 UTF-8）。
    buf: []const u8 = "",
    /// 光标（字节偏移，码点边界）。
    caret: u32 = 0,
    /// 选区锚点（字节偏移，码点边界）。== caret 表示无选区（normal）。
    anchor: u32 = 0,
    /// IME 组合串（arena；composing 时非空）。
    compose_text: []const u8 = "",
    /// 是否 IME composing 中（buf/caret 冻结，§5.8）。
    composing: bool = false,
    /// 是否鼠标拖选中（pointer_down 置位，pointer_up 清除，§5.8）。
    dragging: bool = false,
    /// 内容区内边距（DIP）。widgets/edit.zig 与 platform/window.zig（IME caret 定位）共用。
    pub const pad_h: f32 = 8;
    pub const pad_v: f32 = 4;

    /// 是否有选区（anchor != caret）。
    pub fn hasSelection(self: Edit) bool {
        return self.anchor != self.caret;
    }
};

/// 滚动容器数据（M6；M1 占位）。
pub const Scroll = struct {};

/// custom 变体的 vtable：用户扩展入口（§5.4）。
pub const CustomVTable = struct {
    /// 在给定约束下返回固有尺寸。M1 起生效；paint/onEvent 待 M2/M3 补齐。
    measure: *const fn (ctx: *anyopaque, c: layout.Constraints) geo.Size,
    paint: ?*const fn (ctx: *anyopaque, pc: *anyopaque) void = null,
    on_event: ?*const fn (ctx: *anyopaque, player_ctx: *anyopaque, e: *const @import("event.zig").Event) bool = null,
};

/// custom 变体数据：ctx 指针 + vtable（§5.4）。
pub const Custom = struct {
    ctx: *anyopaque,
    vtable: *const CustomVTable,
};

/// Widget 为 tagged union（§5.4）。新增控件时编译器会指出所有漏改的穷尽 switch。
pub const Widget = union(enum) {
    none,
    box: Box,
    text: Text,
    button: Button,
    edit: Edit,
    scroll: Scroll,
    custom: Custom,
};

/// 便捷：某节点是否可视为"空占位"（不参与绘制/命中）。
pub fn isNone(w: Widget) bool {
    return switch (w) {
        .none => true,
        else => false,
    };
}

test "widget union exhaustive switch compiles" {
    // 穷尽 switch（L8）：确保补全判空逻辑不会漏变体。
    const w: Widget = .box;
    const result = switch (w) {
        .none => 0,
        .box => 1,
        .text => 2,
        .button => 3,
        .edit => 4,
        .scroll => 5,
        .custom => 6,
    };
    try std.testing.expect(result == 1);
    try std.testing.expect(!isNone(.box));
    try std.testing.expect(isNone(.none));
}
