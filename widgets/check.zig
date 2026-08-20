//! widgets/check.zig —— Checkbox 复选框行为（规则 §6）。
//!
//! 状态机（文件头，§5.8）：
//!   unchecked ↔ checked；disabled 吸收一切输入。
//! - 切换：pointer_up 且指针在框内（按下+释放同一节点，click 语义），或聚焦时 Space；
//! - pointer_up 返回 false 让 click 冒泡给用户 handler（§6 反应式展示）；
//! - hover 视觉：由 Tree.hover 推导（§5.3），未勾选时框底取 bg_hover token（L9）；
//! - 勾选视觉 = accent 填充 + accent 边框（无勾号原语，TODO(M7)：线/路径原语后补）。
//!
//! 模块不变量：
//! - 帧路径（measure/paint）零分配；
//! - 视觉只取 theme token（L9）；
//! - checked 只由事件路径写入（L6：paint 不写树状态）。

const std = @import("std");
const geo = @import("../core/geometry.zig");
const layout = @import("../core/layout.zig");
const node = @import("../core/node.zig");
const painter = @import("../core/painter.zig");
const widget = @import("../core/widget.zig");
const event = @import("../core/event.zig");
const theme = @import("../theme.zig");

/// 勾选框边长（DIP）。
const box_size: f32 = 18;
/// 框与标签间距（DIP）。
const label_gap: f32 = 8;

/// 固有尺寸：勾选框 + 标签文本。
pub fn measure(tree: *node.Tree, d: widget.Checkbox, c: layout.Constraints) geo.Size {
    var w = box_size;
    var h = box_size;
    if (d.label.len > 0) {
        if (tree.text_system) |ts| {
            if (ts.layout(d.label, &tree.theme_ref.font_ui, 1_000_000.0, .{})) |tl| {
                w += label_gap + tl.bounds.width;
                h = @max(h, tl.bounds.height);
            }
        }
    }
    return c.constrain(.{ .width = w, .height = h });
}

/// 绘制：焦点光环 → 勾选框（状态决定填充/边框）→ 勾号 → 标签文本。
pub fn paint(tree: *node.Tree, pc: painter.PaintCtx, n: *node.Node, d: widget.Checkbox) void {
    const th = tree.theme_ref;
    const focus = tree.focus == n;
    const hover = tree.hover == n;
    const box = geo.Rect{
        .x = n.rect.x,
        .y = n.rect.y + (n.rect.h - box_size) * 0.5,
        .w = box_size,
        .h = box_size,
    };
    // 焦点光环（外扩 ring，键盘 Tab 聚焦；disabled 不显示）。
    if (focus and !n.flags.disabled) {
        pc.strokeRect(box.outset(geo.Edges.all(1)), th.focus_ring, 2, th.radius.small + 1);
    }
    // 勾选态：accent 填充（hover accent_hover）+ accent 边框；未勾选：surface（悬停 bg_hover）+ border。
    const bg = if (d.checked)
        (if (hover) th.accent_hover else th.accent)
    else
        (if (hover) th.bg_hover else th.bg_surface);
    const border = if (d.checked or focus) th.accent else th.border;
    pc.fillRoundedRect(box, th.radius.small, bg);
    pc.strokeRect(box, border, 1, th.radius.small);

    // 勾号：折线（M7 线原语）。坐标按 box 归一化，末端圆头。
    if (d.checked) {
        const s = box_size;
        const pts = [_]geo.Point{
            .{ .x = box.x + s * 0.22, .y = box.y + s * 0.52 },
            .{ .x = box.x + s * 0.42, .y = box.y + s * 0.72 },
            .{ .x = box.x + s * 0.78, .y = box.y + s * 0.30 },
        };
        pc.strokePolyline(&pts, 2.0, th.accent_text);
    }

    if (d.label.len > 0) {
        if (tree.text_system) |ts| {
            const lw = @max(0, n.rect.w - box_size - label_gap);
            if (ts.layout(d.label, &th.font_ui, lw, .{})) |tl| {
                pc.drawText(
                    .{ .x = box.x + box_size + label_gap, .y = n.rect.y, .w = lw, .h = n.rect.h },
                    tl,
                    if (n.flags.disabled) th.text_disabled else th.text,
                );
            }
        }
    }
}

/// 内建事件处理（dispatch_table.onEvent，§6）。返回 true = 已消费。
pub fn onEvent(tree: *node.Tree, n: *node.Node, e: *const event.Event) bool {
    _ = tree;
    const d = &n.widget.checkbox;
    return switch (e.*) {
        .pointer_down => true, // 消费按下（焦点转移由 Tree.dispatch 负责）。
        .pointer_up => |p| {
            // click 语义（§5.8）：框内抬起才切换（按下与抬起同节点的判定在 Tree）。
            if (n.rect.contains(p.pos)) {
                d.checked = !d.checked;
                n.invalidatePaint();
            }
            return false; // 不消费：让 click 冒泡给用户 handler（§6 反应式）。
        },
        .key_down => |k| {
            if (k.vk == event.VK.SPACE) {
                d.checked = !d.checked;
                n.invalidatePaint();
                return true;
            }
            return false;
        },
        else => false,
    };
}

// —— 测试 ——

test "checkbox: toggles on pointer up inside box and space" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try node.Tree.init(arena.allocator(), &theme.light);
    defer t.deinit();

    const n = try t.createNode(t.root);
    n.widget = .{ .checkbox = .{ .label = "ok" } };
    n.rect = .{ .x = 0, .y = 0, .w = 80, .h = 20 };

    // 框内抬起 → 切换。
    var ev = event.Event{ .pointer_up = .{ .pos = .{ .x = 5, .y = 10 } } };
    _ = onEvent(&t, n, &ev);
    try std.testing.expect(n.widget.checkbox.checked);
    // 框外抬起 → 不切换（返回 false 让 click 语义继续）。
    ev = event.Event{ .pointer_up = .{ .pos = .{ .x = 200, .y = 10 } } };
    _ = onEvent(&t, n, &ev);
    try std.testing.expect(n.widget.checkbox.checked);
    // Space → 切换。
    ev = event.Event{ .key_down = .{ .vk = event.VK.SPACE } };
    _ = onEvent(&t, n, &ev);
    try std.testing.expect(!n.widget.checkbox.checked);
    // 其他键不处理。
    ev = event.Event{ .key_down = .{ .vk = event.VK.RETURN } };
    _ = onEvent(&t, n, &ev);
    try std.testing.expect(!n.widget.checkbox.checked);
}

test "checkbox: paint checked uses accent fill (MockPainter)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try node.Tree.init(arena.allocator(), &theme.light);
    defer t.deinit();

    const n = try t.createNode(t.root);
    n.widget = .{ .checkbox = .{ .label = "x" } };
    n.rect = .{ .x = 0, .y = 0, .w = 80, .h = 20 };

    var mp = try painter.MockPainter.init(std.testing.allocator, &theme.light);
    defer mp.destroy();

    // 未勾选：首个 fillRoundedRect 用 surface。
    paint(&t, mp.ctx, n, n.widget.checkbox);
    try std.testing.expect(mp.calls.items[0].fillRoundedRect.color.r == theme.light.bg_surface.r);

    mp.reset();
    n.widget.checkbox.checked = true;
    paint(&t, mp.ctx, n, n.widget.checkbox);
    try std.testing.expect(mp.calls.items[0].fillRoundedRect.color.r == theme.light.accent.r);
    // 勾选态画出勾号（strokePolyline）。
    var polylines: usize = 0;
    for (mp.calls.items) |c| {
        if (c == .strokePolyline) polylines += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), polylines);
}

test "checkbox: hover uses bg_hover on unchecked box (MockPainter)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try node.Tree.init(arena.allocator(), &theme.light);
    defer t.deinit();

    const n = try t.createNode(t.root);
    n.widget = .{ .checkbox = .{ .label = "x" } };
    n.rect = .{ .x = 0, .y = 0, .w = 80, .h = 20 };

    var mp = try painter.MockPainter.init(std.testing.allocator, &theme.light);
    defer mp.destroy();

    t.hover = n; // 悬停：未勾选框底取 bg_hover。
    paint(&t, mp.ctx, n, n.widget.checkbox);
    try std.testing.expect(mp.calls.items[0].fillRoundedRect.color.r == theme.light.bg_hover.r);

    mp.reset();
    // 勾选 + hover：填充取 accent_hover（accent 的 hover 变体）。
    n.widget.checkbox.checked = true;
    paint(&t, mp.ctx, n, n.widget.checkbox);
    try std.testing.expect(mp.calls.items[0].fillRoundedRect.color.r == theme.light.accent_hover.r);
}
