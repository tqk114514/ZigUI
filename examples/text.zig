//! examples/text —— 文本深化（wrap / ellipsis / 多行）。
//! 每例一个概念（规则 §3）：验证 TextLayout 的换行与省略，拖拽窗口变窄可观察效果。

const std = @import("std");
const ui = @import("zigui");

const theme = ui.theme;

pub fn main() anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var tree = try ui.core.node.Tree.init(arena.allocator(), &theme.dark);
    defer tree.deinit();

    tree.root.layout = .{ .column = .{ .gap = theme.dark.spacing.md } };
    tree.root.style = .{ .padding = .all(theme.dark.spacing.md) };

    const long_zh = "我们说的文字排版：当可用宽度不足以容纳整行文本时，可以换行（wrap），也可以裁剪并在尾部显示省略号（ellipsis）。请拖拽窗口边缘改变宽度观察差异。";
    const long_en = "DirectWrite text layout handles shaping, wrapping, trimming and fallback. Resize this window to see wrap vs ellipsis behavior.";

    // 单行不换行（默认）。
    _ = try ui.widgets.builder.text(&tree, tree.root, "1. Single line (no wrap)", .{});

    // 换行：超出可用宽度折行。
    _ = try ui.widgets.builder.text(&tree, tree.root, long_zh, .{ .wrap = true });
    _ = try ui.widgets.builder.text(&tree, tree.root, long_en, .{ .wrap = true });

    // 省略号：单行，超宽尾部 …（与 wrap 互斥）。
    _ = try ui.widgets.builder.text(&tree, tree.root, long_zh, .{ .ellipsis = true });
    _ = try ui.widgets.builder.text(&tree, tree.root, long_en, .{ .ellipsis = true });

    // 等宽字体（theme 第二槽位）——展示 font_mono 走 TextSystem 的缓存的另一键。
    _ = try ui.widgets.builder.text(&tree, tree.root, "5. 1234567890 -> mono", .{});

    const title = std.unicode.utf8ToUtf16LeStringLiteral("zigui M4 — text");
    _ = try ui.platform.window.run(.{ .title = title, .theme_ref = &theme.dark }, &tree);
}
