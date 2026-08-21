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

/// 建一个静态 node.layer 层盒（C 层合成演示）：层内铺背景色 + 文字，由父（布局容器）排布给
/// 正常坐标 rect，合成按 alpha / scale / z 属性生效。层盒自身即容器（bg + 文字子节点）。
fn addCBox(t: *T, parent: *ui.core.node.Node, txt: []const u8, color: theme.Color, alpha: f32, scale: f32, z: f32) !void {
    const l = try t.createNode(parent);
    l.layer = true;
    l.layer_alpha = alpha;
    l.layer_scale = scale;
    l.layer_z = z;
    l.layout = .{ .column = .{ .gap = theme.light.spacing.xxs } };
    l.style = .{ .bg = color, .padding = .all(theme.light.spacing.xs) };
    try t.appendChild(parent, l);
    const tx = try t.createNode(l);
    tx.widget = .{ .text = .{ .text = try t.allocStr(txt), .font = theme.light.font_caption, .color = theme.light.accent_text } };
    try t.appendChild(l, tx);
}

pub fn main() anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var tree = try ui.core.node.Tree.init(arena.allocator(), &theme.light);
    defer tree.deinit();

    // 根即滚动容器（C 使内容超窗可滚、不超窗 offset 钳到 0 不可滚）。
    tree.root.widget = .{ .scroll = .{} };
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

    // 缓存层（§5.6 分层）：两个独立 node.layer 子树并排，各自离屏缓存、互不干扰
    //（批量文本可在 scroll 层里看复用；此处验证多并发静态层正确合成）。
    try addLabel(&tree, "缓存层 LAYERS");
    {
        const row = try addRow(&tree);
        const LayerBox = struct {
            fn box(t: *T, parent: *ui.core.node.Node, txt: []const u8) !*ui.core.node.Node {
                const b = try t.createNode(parent);
                b.layout = .{ .column = .{ .gap = theme.light.spacing.xxs } };
                b.style = .{ .bg = theme.light.bg_surface, .padding = .all(theme.light.spacing.sm) };
                b.layer = true; // 提升为独立缓存层：内容变才重栅化，父级越过不重绘它。
                try t.appendChild(parent, b);
                const tx = try t.createNode(b);
                tx.widget = .{ .text = .{ .text = try t.allocStr(txt), .font = theme.light.font_caption } };
                try t.appendChild(b, tx);
                return b;
            }
        };
        _ = try LayerBox.box(&tree, row, "静态层 A");
        _ = try LayerBox.box(&tree, row, "静态层 B");
    }

    // 层合成增强 C：node.layer 的 alpha / scale / z 合成属性演示（层盒由布局容器排布）。
    try addLabel(&tree, "层合成 ALPHA（半透明层透出下面深色行底色）");
    {
        const row = try addRow(&tree);
        row.style = .{ .bg = theme.light.text }; // 深底色，衬托半透明透出。
        try addCBox(&tree, row, "不透明 1.0", theme.light.danger, 1.0, 1.0, 0);
        try addCBox(&tree, row, "半透明 0.5", theme.light.accent, 0.5, 1.0, 0);
    }

    try addLabel(&tree, "层合成 SCALE（右为缩放 0.8，同内容更小）");
    {
        const row = try addRow(&tree);
        try addCBox(&tree, row, "缩放 1.0", theme.light.accent, 1.0, 1.0, 0);
        try addCBox(&tree, row, "缩放 0.8", theme.light.accent, 1.0, 0.8, 0);
    }

    try addLabel(&tree, "层合成 Z（z 排序层属性；并排展示两盒）");
    {
        const row = try addRow(&tree);
        try addCBox(&tree, row, "A z=2", theme.light.accent, 1.0, 1.0, 2);
        try addCBox(&tree, row, "B z=1", theme.light.danger, 1.0, 1.0, 1);
    }

    const title = std.unicode.utf8ToUtf16LeStringLiteral("ZigUI DEMO");
    // 初始高度取大以容纳全部分区（含层合成 C 示例）；收窄后由根 scroll 兜底滚动。
    _ = try ui.platform.window.run(.{ .title = title, .theme_ref = &theme.light, .height = 860 }, &tree);
}
