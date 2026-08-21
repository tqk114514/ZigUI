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
const scroll = @import("scroll.zig");
const check = @import("check.zig");
const slider = @import("slider.zig");
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
        .checkbox => |d| check.measure(tree, d, c),
        .slider => |d| slider.measure(tree, d, c),
        .scroll => .{}, // scroll 是布局容器，走 computeSize 的 else 分支，不经此路由
        .custom => unreachable, // custom 走自身 vtable，不经此路由
    };
}

/// 控件 paint 路由。叶子控件在内容前绘制；scroll 例外——其 paintWidget 是视口固定
/// 覆盖层（滚动条拇指），由 paintNode 在条带 blit / 子内容**之后**调用（§6 P0-3）。
fn paintWidget(tree: *node.Tree, n: *node.Node, pc: painter.PaintCtx) void {
    switch (n.widget) {
        .none, .box => {},
        .text => |d| text.paint(tree, pc, n.rect, d),
        .button => |d| button.paint(tree, pc, n, d),
        .edit => |d| edit.paint(tree, pc, n, d),
        .checkbox => |d| check.paint(tree, pc, n, d),
        .slider => |d| slider.paint(tree, pc, n, d),
        .scroll => scroll.paint(tree, pc, n), // 视口固定覆盖层（滚动条拇指，§6 P0-3；paintNode 在内容后调用）
        .custom => {},
    }
}

/// 内建控件事件处理（§5.4/§5.8）：Edit 键盘/文本/IME、checkbox/slider/scroll 交互。
/// 返回 true = 已消费。
fn onEvent(tree: *node.Tree, n: *node.Node, e: *const event.Event) bool {
    // disabled 吸收一切输入（§5.8）：既不动作也不冒泡，避免触发用户 handler。
    if (n.flags.disabled) return true;
    return switch (n.widget) {
        .edit => edit.onEvent(tree, n, e),
        .checkbox => check.onEvent(tree, n, e),
        .slider => slider.onEvent(tree, n, e),
        .scroll => scroll.onEvent(tree, n, e),
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

test "checkbox/slider get non-zero size via computeSize (回归：曾被当容器测得 0)" {
    const theme = @import("../theme.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try node.Tree.init(arena.allocator(), &theme.light);
    defer t.deinit();
    t.dispatch_table = &table;
    t.root.layout = .{ .column = .{} };

    const cb = try t.createNode(t.root);
    cb.widget = .{ .checkbox = .{ .label = "x" } };
    try t.appendChild(t.root, cb);
    const sl = try t.createNode(t.root);
    sl.widget = .{ .slider = .{} };
    try t.appendChild(t.root, sl);

    t.ensureLayout(.{ .width = 200, .height = 400 });
    // 叶子控件必须测得固有高度（checkbox ≥ 框高，slider = 控件高），且上下排布不重叠。
    try std.testing.expect(cb.measured.height > 0);
    try std.testing.expect(sl.measured.height > 0);
    try std.testing.expect(cb.rect.y < sl.rect.y);
}

test "slider drag end notifies handler even when released off-node (§6)" {
    const theme = @import("../theme.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try node.Tree.init(arena.allocator(), &theme.light);
    defer t.deinit();
    t.dispatch_table = &table;
    t.root.layout = .{ .column = .{} };

    const sl = try t.createNode(t.root);
    sl.widget = .{ .slider = .{ .value = 0, .min = 0, .max = 100 } };
    try t.appendChild(t.root, sl);
    t.ensureLayout(.{ .width = 200, .height = 100 }); // 滑块 rect = (0,0,200,20)。

    var notified: u32 = 0;
    sl.handler_ctx = &notified;
    sl.handler = &struct {
        fn h(_: *node.Node, c: ?*anyopaque, e: *const event.Event) bool {
            if (e.* == .pointer_up) {
                const n: *u32 = @ptrCast(@alignCast(c.?));
                n.* += 1;
            }
            return false;
        }
    }.h;

    // 滑块上按下 → 拖动到最右 → 抬起到滑块外（y 超界）。
    // 滑块宽 200、thumb 14 → 行程 186，中心范围 [7,193]。
    _ = t.dispatch(&.{ .pointer_down = .{ .pos = .{ .x = 100, .y = 10 } } });
    _ = t.dispatch(&.{ .pointer_move = .{ .pos = .{ .x = 193, .y = 10 } } });
    try std.testing.expect(geo.approxEq(100, sl.widget.slider.value));
    _ = t.dispatch(&.{ .pointer_up = .{ .pos = .{ .x = 193, .y = 90 } } });
    // 拖动结束必须通知 handler（拖拽型控件，与抬起位置无关，§6）。
    try std.testing.expectEqual(@as(u32, 1), notified);
}

test "disabled widget absorbs pointer input (no toggle)" {
    const theme = @import("../theme.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try node.Tree.init(arena.allocator(), &theme.light);
    defer t.deinit();
    t.dispatch_table = &table;

    const n = try t.createNode(t.root);
    n.widget = .{ .checkbox = .{ .label = "禁用勾选", .checked = false } };
    n.flags.disabled = true;
    n.rect = .{ .x = 0, .y = 0, .w = 80, .h = 20 };

    // disabled 吸收输入（§5.8）：点击不切换勾选。
    _ = t.dispatch(&.{ .pointer_down = .{ .pos = .{ .x = 5, .y = 10 } } });
    _ = t.dispatch(&.{ .pointer_up = .{ .pos = .{ .x = 5, .y = 10 } } });
    try std.testing.expect(!n.widget.checkbox.checked);
}
