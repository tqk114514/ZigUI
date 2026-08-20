//! examples/edit —— 单行编辑框（打字 / 方向键 / Backspace / 选区 / 光标闪烁 / IME）。
//! IME 手动验收清单见 checklists/ime.md（§7.3，微软拼音 + 搜狗 + 日语 MS-IME）。

const std = @import("std");
const ui = @import("zigui");

pub const std_options: std.Options = .{ .networking = false };

const theme = ui.theme;

pub fn main() anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var tree = try ui.core.node.Tree.init(arena.allocator(), &theme.dark);
    defer tree.deinit();

    tree.root.layout = .{ .column = .{ .gap = theme.dark.spacing.md } };
    tree.root.style = .{ .padding = .all(theme.dark.spacing.md) };

    _ = try ui.widgets.builder.text(&tree, tree.root, "Type / arrows / Backspace / Shift+arrows select / IME. Tab to switch.", .{});
    _ = try ui.widgets.builder.edit(&tree, tree.root, "hello 世界");
    _ = try ui.widgets.builder.edit(&tree, tree.root, "");

    const title = std.unicode.utf8ToUtf16LeStringLiteral("zigui M5 — edit");
    _ = try ui.platform.window.run(.{ .title = title, .theme_ref = &theme.dark }, &tree);
}
