//! widgets/builder.zig —— 构建 DSL（规则 §5.8）。
//!
//! 模块不变量：
//! - 树一次性声明式构建（column / button / text 等），构建后经 find(id) + setter 修改；
//! - 列表变更走 replaceChildren 重建（§4.3/§5.3）；
//! - 事件订阅：调用方在返回的节点上挂 handler + handler_ctx（§5.8 trampoline 模式）。
//!
//! 注意：id / label / text 字符串经 tree.allocStr 拷贝入 arena（§4.3），调用方可传栈上字符串。

const std = @import("std");
const node = @import("../core/node.zig");
const widget = @import("../core/widget.zig");
const layout = @import("../core/layout.zig");
const painter = @import("../core/painter.zig");

/// 创建 column 布局容器并挂到 parent。
pub fn column(tree: *node.Tree, parent: *node.Node, opts: layout.Stack) !*node.Node {
    const n = try tree.createNode(parent);
    n.layout = .{ .column = opts };
    try tree.appendChild(parent, n);
    return n;
}

/// 创建 row 布局容器并挂到 parent。
pub fn row(tree: *node.Tree, parent: *node.Node, opts: layout.Stack) !*node.Node {
    const n = try tree.createNode(parent);
    n.layout = .{ .row = opts };
    try tree.appendChild(parent, n);
    return n;
}

/// 创建文本节点。`opts` 支持 wrap/ellipsis。
pub fn text(tree: *node.Tree, parent: *node.Node, str: []const u8, opts: painter.TextLayoutOptions) !*node.Node {
    const n = try tree.createNode(parent);
    n.widget = .{ .text = .{ .text = try tree.allocStr(str), .wrap = opts.wrap, .ellipsis = opts.ellipsis } };
    try tree.appendChild(parent, n);
    return n;
}

/// 创建按钮节点（label 拷贝入 arena）。click 由调用方挂 n.handler/n.handler_ctx。
pub fn button(tree: *node.Tree, parent: *node.Node, label: []const u8) !*node.Node {
    const n = try tree.createNode(parent);
    n.widget = .{ .button = .{ .label = try tree.allocStr(label) } };
    n.flags.focusable = true; // 按钮默认可聚焦（Tab 焦点环）。
    try tree.appendChild(parent, n);
    return n;
}

/// 创建单行编辑框节点（buf 拷贝入 arena）。可聚焦；键盘/IME 输入为内建行为（§5.8）。
pub fn edit(tree: *node.Tree, parent: *node.Node, initial: []const u8) !*node.Node {
    const n = try tree.createNode(parent);
    n.widget = .{ .edit = .{ .buf = try tree.allocStr(initial) } };
    n.flags.focusable = true;
    try tree.appendChild(parent, n);
    return n;
}

/// 创建纵向滚动容器并挂到 parent（§6）：内容为其子节点，滚轮 / Edit 拖选越界滚动。
/// 内容布局为 column（v1 只做纵向，§6 TODO(M7) 横向/滚动条）。
pub fn scroll(tree: *node.Tree, parent: *node.Node) !*node.Node {
    const n = try tree.createNode(parent);
    n.widget = .{ .scroll = .{} };
    n.layout = .{ .column = .{} };
    try tree.appendChild(parent, n);
    return n;
}

/// 创建复选框节点（label 拷贝入 arena）。可聚焦（Tab 焦点环 + Space 切换，§6）。
pub fn checkbox(tree: *node.Tree, parent: *node.Node, label: []const u8) !*node.Node {
    const n = try tree.createNode(parent);
    n.widget = .{ .checkbox = .{ .label = try tree.allocStr(label) } };
    n.flags.focusable = true;
    try tree.appendChild(parent, n);
    return n;
}

/// 创建滑块节点（§6）。范围 [min, max]，初值 value（钳制到范围）。
pub fn slider(tree: *node.Tree, parent: *node.Node, value: f32, min: f32, max: f32) !*node.Node {
    const n = try tree.createNode(parent);
    const v = if (max > min) @min(max, @max(min, value)) else min;
    n.widget = .{ .slider = .{ .value = v, .min = min, .max = max } };
    try tree.appendChild(parent, n);
    return n;
}

/// 便捷：给节点设置 id（拷贝入 arena），供 find(id) 定位。
pub fn setNodeId(tree: *node.Tree, n: *node.Node, id: []const u8) !void {
    n.id = try tree.allocStr(id);
}

/// 给节点设置 tooltip 文本（拷贝入 arena，L5）：hover 停留 0.5s 后于锚附近显示浮层，
/// 移开/按下/失焦消失（P0-1 弹层）。容器设置时其子节点 hover 同样生效（沿祖先找 tip）。
pub fn tooltip(tree: *node.Tree, n: *node.Node, str: []const u8) !void {
    n.tip = try tree.allocStr(str);
}
