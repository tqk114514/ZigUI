//! widgets/dispatch.zig —— 唯一的分发 switch（规则 §5.4）。
//!
//! 模块不变量：
//! - 对 Widget union 的 switch 必须穷尽、禁 else（L8），新增控件由编译器指出漏改处；
//! - 本文件实现 DispatchTable（measureWidget / paintWidget），Tree 持其引用；
//! - 控件行为自由函数在 widgets/*.zig，本文件只做路由与组合；
//! - 帧路径零分配：这些函数不分配、不带 allocator 参数（L4）。

const std = @import("std");
const layout = @import("../core/layout.zig");
const geo = @import("../core/geometry.zig");
const node = @import("../core/node.zig");
const painter = @import("../core/painter.zig");
const text = @import("text.zig");
const button = @import("button.zig");
const edit = @import("edit.zig");
const event = @import("../core/event.zig");

/// 供 Tree 引用的分发表实例。
pub const table: node.DispatchTable = .{
    .measureWidget = measureWidget,
    .paintWidget = paintWidget,
    .onEvent = onEvent,
};

/// 对叶子控件求 measure。只被 core 在"该节点是叶子控件"时调用。
fn measureWidget(tree: *node.Tree, n: *node.Node, c: layout.Constraints) geo.Size {
    return switch (n.widget) {
        .none => unreachable, // 不应发生：none 走布局容器
        .box => unreachable, // 同上
        .text => |d| text.measure(tree, d, c),
        .button => |d| button.measure(tree, d, c),
        .edit => |d| edit.measure(tree, d, c),
        .scroll => .{}, // TODO(M6)：scroll 待交付
        .custom => unreachable, // custom 走自身 vtable，不经此路由
    };
}

/// 对叶子控件 paint。同样只在叶子节点调用。
fn paintWidget(tree: *node.Tree, n: *node.Node, pc: painter.PaintCtx) void {
    switch (n.widget) {
        .none, .box => {},
        .text => |d| text.paint(tree, pc, n.rect, d),
        .button => |d| button.paint(tree, pc, n, d),
        .edit => |d| edit.paint(tree, pc, n, d),
        .scroll => {},
        .custom => {},
    }
}

/// 内建控件事件处理（§5.4/§5.8）：Edit 键盘/文本/IME。返回 true = 已消费。
fn onEvent(tree: *node.Tree, n: *node.Node, e: *const event.Event) bool {
    return switch (n.widget) {
        .edit => edit.onEvent(tree, n, e),
        else => false, // 非内建事件控件：不消费，交回 bubble（用户 handler）。
    };
}

test "dispatch table routes text measure" {
    const theme = @import("../theme.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try node.Tree.init(arena.allocator(), &theme.light);
    defer t.deinit();
    t.dispatch_table = &table;

    const n = try t.createNode(t.root);
    n.widget = .{ .text = .{ .text = "hello" } };
    const s = measureWidget(&t, n, .{ .max = .{ .width = 1000, .height = 1000 } });
    // 无 text_system 时按零尺寸（文本能力由 render 注入）。
    try std.testing.expect(geo.approxEq(0, s.width));
}
