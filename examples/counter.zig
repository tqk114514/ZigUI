//! examples/counter —— Button + click 回调 + 文本更新。
//! 每例一个概念（规则 §3）：验证 hover/press 视觉（真实渲染）与 click 事件。

const std = @import("std");
const ui = @import("zigui");

const theme = ui.theme;

pub fn main() anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var tree = try ui.core.node.Tree.init(arena.allocator(), &theme.dark);
    defer tree.deinit();

    tree.root.layout = .{ .column = .{ .gap = theme.dark.spacing.sm } };
    tree.root.style = .{ .padding = .all(theme.dark.spacing.md) };

    // 计数显示。
    var count: u32 = 0;
    const label_node = try ui.widgets.builder.text(&tree, tree.root, "Count: 0", .{});

    // 按钮：点击计数 + 更新文本。
    const inc_btn = try ui.widgets.builder.button(&tree, tree.root, "Increment (+1)");

    const Ctx = struct {
        count: *u32,
        label: *ui.core.node.Node,
        tree: *ui.core.node.Tree,
        fn onInc(_: *ui.core.node.Node, c: ?*anyopaque, e: *const ui.core.event.Event) bool {
            // 只在 click 完成（pointer_up 命中自身）时计数；忽略 move/down（§5.8）。
            if (e.* != .pointer_up) return false;
            const s: *@This() = @ptrCast(@alignCast(c.?));
            s.count.* += 1;
            // 更新文本：replaceChildren 重建（§4.3）。简单起见直接改 widget 文本。
            s.label.widget.text.text = std.fmt.allocPrint(s.tree.arena.allocator(), "Count: {d}", .{s.count.*}) catch "";
            s.label.invalidateMeasure();
            s.label.invalidatePaint();
            return true;
        }
    };
    var ctx = Ctx{ .count = &count, .label = label_node, .tree = &tree };
    inc_btn.handler_ctx = &ctx;
    inc_btn.handler = &Ctx.onInc;

    const title = std.unicode.utf8ToUtf16LeStringLiteral("zigui M3 — counter");
    _ = try ui.platform.window.run(.{ .title = title, .theme_ref = &theme.dark }, &tree);
}
