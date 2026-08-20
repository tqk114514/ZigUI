//! widgets/button.zig —— Button 控件行为（状态机 + measure/paint）。
//!
//! 状态机（文件头，规则 §5.8）：
//!   normal ↔ hover ↔ pressed；disabled 吸收一切输入。
//!   - 状态由 Tree.hover / Tree.active 单值指针推导（§5.3），非按钮自身存储；
//!   - hover/active 指针的维护在 core/node.zig 的 Tree.dispatch 中完成（通用）；
//!   - 转换只由指针事件驱动；视觉只由状态 + theme token 决定（L9）；
//!   - click 触发：pointer_up 命中自身时经 Node.handler（builder 挂接，§5.8）。

const std = @import("std");
const geo = @import("../core/geometry.zig");
const layout = @import("../core/layout.zig");
const node = @import("../core/node.zig");
const painter = @import("../core/painter.zig");
const widget = @import("../core/widget.zig");
const theme = @import("../theme.zig");

/// 按钮内边距（DIP）。
const pad_h: f32 = 14;
const pad_v: f32 = 6;

/// 求按钮固有尺寸：文本宽 + 内边距。
pub fn measure(tree: *node.Tree, d: widget.Button, c: layout.Constraints) geo.Size {
    var base: geo.Size = .{};
    if (tree.text_system) |ts| {
        if (ts.layout(d.label, &tree.theme_ref.font_ui, c.max.width, .{})) |tl| {
            base = tl.bounds;
        }
    }
    return c.constrain(.{
        .width = base.width + pad_h * 2,
        .height = base.height + pad_v * 2,
    });
}

/// 绘制按钮：焦点光环 → 圆角背景/边框（按状态选 token，L9）。
pub fn paint(tree: *node.Tree, pc: painter.PaintCtx, n: *node.Node, d: widget.Button) void {
    const th = tree.theme_ref;
    const state = stateOf(tree, n);

    // 焦点光环（外扩 ring，键盘 Tab 聚焦；disabled 不显示）。
    if (tree.focus == n and state != .disabled) {
        pc.strokeRect(n.rect.outset(geo.Edges.all(1)), th.focus_ring, 2, th.radius.small + 1);
    }

    // 背景与边框（按状态取 token）。
    const bg: theme.Color = switch (state) {
        .disabled => th.bg_disabled,
        .pressed => th.bg_pressed,
        .hover => th.bg_hover,
        .normal => th.bg_surface,
    };
    const border: theme.Color = switch (state) {
        .disabled => th.border,
        .normal => th.border,
        else => th.accent,
    };
    const fg: theme.Color = if (state == .disabled) th.text_disabled else th.text;

    pc.fillRoundedRect(n.rect, th.radius.small, bg);
    pc.strokeRect(n.rect, border, 1, th.radius.small);

    // 文本居中。
    if (tree.text_system) |ts| {
        if (ts.layout(d.label, &th.font_ui, n.rect.w, .{})) |tl| {
            const text_rect = geo.Rect{
                .x = n.rect.x + pad_h,
                .y = n.rect.y + pad_v,
                .w = n.rect.w - pad_h * 2,
                .h = n.rect.h - pad_v * 2,
            };
            pc.drawText(text_rect, tl, fg);
        }
    }
}

/// Button 状态。
pub const State = enum { normal, hover, pressed, disabled };

/// 由 Tree 状态指针推导按钮状态（§5.3）。
pub fn stateOf(tree: *node.Tree, n: *node.Node) State {
    if (n.flags.disabled) return .disabled;
    if (tree.active == n) return .pressed;
    if (tree.hover == n) return .hover;
    return .normal;
}

test "button state derived from tree pointers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try node.Tree.init(arena.allocator(), &theme.light);
    defer t.deinit();

    const n = try t.createNode(t.root);
    n.widget = .{ .button = .{ .label = "OK" } };

    try std.testing.expect(stateOf(&t, n) == .normal);

    t.hover = n;
    try std.testing.expect(stateOf(&t, n) == .hover);

    t.active = n;
    try std.testing.expect(stateOf(&t, n) == .pressed);

    n.flags.disabled = true;
    try std.testing.expect(stateOf(&t, n) == .disabled);
}

test "button paint uses hover token (MockPainter)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try node.Tree.init(arena.allocator(), &theme.light);
    defer t.deinit();

    const n = try t.createNode(t.root);
    n.widget = .{ .button = .{ .label = "OK" } };
    n.rect = .{ .x = 0, .y = 0, .w = 60, .h = 30 };

    var mp = try painter.MockPainter.init(std.testing.allocator, &theme.light);
    defer mp.destroy();

    // 先 normal 绘制：首条 fillRoundedRect 应为 bg_surface。
    paint(&t, mp.ctx, n, n.widget.button);
    try std.testing.expect(mp.calls.items.len >= 1);
    try std.testing.expect(mp.calls.items[0] == .fillRoundedRect);

    mp.reset();
    // hover 状态：fillRoundedRect 用 bg_hover。
    t.hover = n;
    paint(&t, mp.ctx, n, n.widget.button);
    try std.testing.expect(mp.calls.items[0].fillRoundedRect.color.r == theme.light.bg_hover.r);
    try std.testing.expect(mp.calls.items[0].fillRoundedRect.color.g == theme.light.bg_hover.g);

    mp.reset();
    // pressed：bg_pressed。
    t.active = n;
    paint(&t, mp.ctx, n, n.widget.button);
    try std.testing.expect(mp.calls.items[0].fillRoundedRect.color.r == theme.light.bg_pressed.r);
}
