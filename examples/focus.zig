//! examples/focus —— Tab / Shift-Tab 焦点环。
//! 每例一个概念（规则 §3）：验证 focusable 节点按声明顺序循环。

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

    _ = try ui.widgets.builder.text(&tree, tree.root, "Focus ring: press Tab / Shift+Tab to cycle", .{});
    // 三个可聚焦按钮，focusable 由 builder.button 默认设置。
    _ = try ui.widgets.builder.button(&tree, tree.root, "First  (A)");
    _ = try ui.widgets.builder.button(&tree, tree.root, "Second (B)");
    _ = try ui.widgets.builder.button(&tree, tree.root, "Third  (C)");

    const title = std.unicode.utf8ToUtf16LeStringLiteral("zigui M3 — focus ring");
    _ = try ui.platform.window.run(.{ .title = title, .theme_ref = &theme.dark }, &tree);
}
