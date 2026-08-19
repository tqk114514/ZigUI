//! examples/theme_preview —— M2 渲染验收：主题预览（中文 + 拉丁 fallback）。
//! 每例一个概念（规则 §3）：验证 D2D 渲染、DWrite 文本（含中文）、主题 token 视觉。

const std = @import("std");
const ui = @import("zigui");

const theme = ui.theme;

pub fn main() anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var tree = try ui.core.node.Tree.init(arena.allocator(), &theme.light);
    defer tree.deinit();

    // 根 column：浅色主题，含背景与圆角边框。
    tree.root.layout = .{ .column = .{ .gap = theme.light.spacing.sm } };
    tree.root.style = .{
        .padding = .all(theme.light.spacing.lg),
        .bg = theme.light.bg_window,
    };

    // 标题（等宽字体无法在此指定，M2 用 UI 字体；展示双语）。
    const addText = struct {
        fn push(t: *ui.core.node.Tree, text: []const u8) !void {
            const n = try t.createNode(t.root);
            n.widget = .{ .text = .{ .text = try t.allocStr(text) } };
            try t.appendChild(t.root, n);
        }
    }.push;

    try addText(&tree, "ZigUI M2 — Direct2D + DirectWrite 渲染");
    try addText(&tree, "中文渲染：微软雅黑（Microsoft YaHei UI）fallback");
    try addText(&tree, "Latin: ClearType antialiasing & subpixel positioning");
    try addText(&tree, "Numbers 0123456789 — Symbols !@#$%^&*()");

    const title = std.unicode.utf8ToUtf16LeStringLiteral("zigui M2 — theme preview");
    _ = try ui.platform.window.run(.{ .title = title, .theme_ref = &theme.light }, &tree);
}