//! examples/demo —— 组件展示页（M7 视觉系统）。
//! 每例一个概念（规则 §3）：分区展示按钮/复选框/滑块/输入框与排版层级（font_title/font_caption）。

const std = @import("std");
const ui = @import("zigui");

pub const std_options: std.Options = .{ .networking = false };

const theme = ui.theme;
const T = ui.core.node.Tree;

/// 追加文本节点（font/color 走可选排版槽，§5.2）。
fn addText(t: *T, text: []const u8, font: ?theme.Font, color: ?theme.Color) !void {
    const n = try t.createNode(t.root);
    n.widget = .{ .text = .{ .text = try t.allocStr(text), .font = font, .color = color } };
    try t.appendChild(t.root, n);
}

/// 分区标签（小字弱化）。
fn addLabel(t: *T, text: []const u8) !void {
    try addText(t, text, theme.light.font_caption, theme.light.text_weak);
}

/// 行容器。
fn addRow(t: *T) !*ui.core.node.Node {
    const row = try t.createNode(t.root);
    row.layout = .{ .row = .{ .gap = theme.light.spacing.sm } };
    try t.appendChild(t.root, row);
    return row;
}

/// 按钮（可禁用）。
fn addButton(t: *T, row: *ui.core.node.Node, label: []const u8, disabled: bool) !void {
    const b = try t.createNode(row);
    b.widget = .{ .button = .{ .label = try t.allocStr(label) } };
    b.flags.disabled = disabled;
    try t.appendChild(row, b);
}

/// 复选框（可勾选/禁用）。
fn addCheckbox(t: *T, row: *ui.core.node.Node, label: []const u8, checked: bool, disabled: bool) !void {
    const c = try t.createNode(row);
    c.widget = .{ .checkbox = .{ .label = try t.allocStr(label), .checked = checked } };
    c.flags.disabled = disabled;
    try t.appendChild(row, c);
}

/// 滑块（全宽）。
fn addSlider(t: *T, value: f32) !void {
    const s = try t.createNode(t.root);
    s.widget = .{ .slider = .{ .value = value, .min = 0, .max = 100 } };
    try t.appendChild(t.root, s);
}

/// 输入框（全宽）。
fn addEdit(t: *T, text: []const u8) !void {
    const e = try t.createNode(t.root);
    e.widget = .{ .edit = .{ .buf = try t.allocStr(text) } };
    try t.appendChild(t.root, e);
}

pub fn main() anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var tree = try ui.core.node.Tree.init(arena.allocator(), &theme.light);
    defer tree.deinit();

    tree.root.layout = .{ .column = .{ .gap = theme.light.spacing.md } };
    // 内容与窗口四边保持最小间距（类似 Web body 的隔离，防止 UI 贴边；§5.3 padding 语义）。
    tree.root.style = .{ .padding = .all(theme.light.spacing.md), .bg = theme.light.bg_window };

    // 按钮（行内三个）。
    try addLabel(&tree, "按钮 BUTTONS");
    {
        const row = try addRow(&tree);
        try addButton(&tree, row, "主操作", false);
        try addButton(&tree, row, "次操作", false);
        try addButton(&tree, row, "禁用", true);
    }

    // 复选框（行内三个）。
    try addLabel(&tree, "复选框 CHECKBOXES");
    {
        const row = try addRow(&tree);
        try addCheckbox(&tree, row, "已勾选", true, false);
        try addCheckbox(&tree, row, "未勾选", false, false);
        try addCheckbox(&tree, row, "禁用勾选", false, true);
    }

    // 滑块（各占一行）。
    try addLabel(&tree, "滑块 SLIDERS");
    try addSlider(&tree, 60);
    try addSlider(&tree, 25);

    // 输入框（占一行，可 Tab 聚焦体验焦点环 + 光标）。
    try addLabel(&tree, "输入框 EDIT");
    try addEdit(&tree, "hello 世界");

    const title = std.unicode.utf8ToUtf16LeStringLiteral("ZigUI DEMO");
    _ = try ui.platform.window.run(.{ .title = title, .theme_ref = &theme.light }, &tree);
}
