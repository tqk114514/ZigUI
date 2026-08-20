//! widgets/slider.zig —— Slider 滑块行为（规则 §6）。
//!
//! 状态机（文件头，§5.8）：
//!   idle ↔ dragging（指针按下/拖动调值）。
//! - pointer_down 进入 dragging 并按 x 定位；dragging 中 pointer_move 持续调值；
//! - pointer_up 结束拖动，经 Node.release_anywhere（§6）无视抬起位置沿其冒泡，
//!   通知 handler 拖动结束（反应式）；
//! - hover/拖动视觉：滑块灰色遮罩取 bg_hover（类似 checkbox hover，§6）；
//! - v1 仅指针交互（TODO(M7)：键盘方向键调值）；
//! - 视觉只取 theme token（L9）。
//!
//! 模块不变量：
//! - 帧路径（measure/paint）零分配；
//! - value 恒在 [min, max]（换算处钳制）；dragging 只由事件路径写入（L6）；
//! - 滑块中心跟随指针：换算与绘制共用"行程 = 轨道宽 − 滑块宽"（§6）。

const std = @import("std");
const geo = @import("../core/geometry.zig");
const layout = @import("../core/layout.zig");
const node = @import("../core/node.zig");
const painter = @import("../core/painter.zig");
const widget = @import("../core/widget.zig");
const event = @import("../core/event.zig");
const theme = @import("../theme.zig");

/// 控件高度 / 轨道厚度 / 滑块边长（DIP）。
const ctrl_h: f32 = 20;
const track_h: f32 = 4;
const thumb_size: f32 = 14;

/// 固有尺寸：高度固定，宽度倾向占满（stretch）。
pub fn measure(tree: *node.Tree, d: widget.Slider, c: layout.Constraints) geo.Size {
    _ = d;
    _ = tree;
    const w: f32 = if (c.max.width < 1_000_000.0) c.max.width else 160;
    return c.constrain(.{ .width = w, .height = ctrl_h });
}

/// 绘制：轨道（圆角底色）→ 已滑段（accent）→ 圆形拇指。hover/拖动时拇指灰色遮罩（bg_hover）。
pub fn paint(tree: *node.Tree, pc: painter.PaintCtx, n: *node.Node, d: widget.Slider) void {
    const th = tree.theme_ref;
    const hover = tree.hover == n;
    const cy = n.rect.y + n.rect.h * 0.5;
    const frac = valueFraction(d);
    const radius = track_h * 0.5;
    const track = geo.Rect{ .x = n.rect.x, .y = cy - track_h * 0.5, .w = n.rect.w, .h = track_h };
    pc.fillRoundedRect(track, radius, th.bg_pressed);
    if (frac > 0) {
        pc.fillRoundedRect(.{ .x = track.x, .y = track.y, .w = track.w * frac, .h = track.h }, radius, th.accent);
    }
    // 圆形拇指：中心跟随指针（行程 = 轨道宽 − 滑块宽，§6 与 setValueFromX 一致）。
    const thumb_cx = track.x + (track.w - thumb_size) * frac + thumb_size * 0.5;
    pc.fillEllipse(
        .{ .x = thumb_cx, .y = cy },
        thumb_size * 0.5,
        thumb_size * 0.5,
        if (hover or d.dragging) th.bg_hover else th.accent,
    );
}

/// value 在 [min,max] 中的归一化比例 [0,1]。
fn valueFraction(d: widget.Slider) f32 {
    const range = d.max - d.min;
    if (range <= 0) return 0;
    return std.math.clamp((d.value - d.min) / range, 0, 1);
}

/// 内建事件处理（dispatch_table.onEvent，§6）。返回 true = 已消费。
pub fn onEvent(tree: *node.Tree, n: *node.Node, e: *const event.Event) bool {
    _ = tree;
    const d = &n.widget.slider;
    return switch (e.*) {
        .pointer_down => |p| {
            d.dragging = true;
            // 拖拽型控件：抬起通知与命中位置无关（dispatch 据 release_anywhere 冒泡，§6）。
            n.release_anywhere = true;
            setValueFromX(n, d, p.pos.x);
            n.invalidatePaint();
            return true;
        },
        .pointer_move => |p| {
            if (!d.dragging) return false;
            setValueFromX(n, d, p.pos.x);
            n.invalidatePaint();
            return true;
        },
        .pointer_up => {
            d.dragging = false;
            n.invalidatePaint();
            return false; // 不消费：由 dispatch 决定沿 release_anywhere 冒泡（§6）。
        },
        else => false,
    };
}

/// 由点击 x（节点内坐标）换算 value：滑块中心跟随指针（§6）。
/// 行程 = 轨道宽 − 滑块宽（与 paint 的滑块定位一致，保证中心贴鼠标）。
fn setValueFromX(n: *node.Node, d: *widget.Slider, x: f32) void {
    const travel = @max(1, n.rect.w - thumb_size);
    const t = std.math.clamp((x - n.rect.x - thumb_size * 0.5) / travel, 0, 1);
    d.value = d.min + (d.max - d.min) * t;
}

// —— 测试 ——

test "slider: drag sets value within range" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try node.Tree.init(arena.allocator(), &theme.light);
    defer t.deinit();

    const n = try t.createNode(t.root);
    n.widget = .{ .slider = .{ .value = 0, .min = 0, .max = 100 } };
    n.rect = .{ .x = 0, .y = 0, .w = 100, .h = 20 };
    // 行程 = 100 − 14 = 86；滑块中心范围 [7, 93]。

    // 按下在中点 → 滑块中心贴指针 → 50。
    var ev = event.Event{ .pointer_down = .{ .pos = .{ .x = 50, .y = 10 } } };
    _ = onEvent(&t, n, &ev);
    try std.testing.expect(geo.approxEq(50, n.widget.slider.value));
    try std.testing.expect(n.widget.slider.dragging);
    // 拖动到最左（中心 x=7）→ 0；最右（中心 x=93）→ 100。
    ev = event.Event{ .pointer_move = .{ .pos = .{ .x = 7, .y = 10 } } };
    _ = onEvent(&t, n, &ev);
    try std.testing.expect(geo.approxEq(0, n.widget.slider.value));
    ev = event.Event{ .pointer_move = .{ .pos = .{ .x = 93, .y = 10 } } };
    _ = onEvent(&t, n, &ev);
    try std.testing.expect(geo.approxEq(100, n.widget.slider.value));
    // 越界钳制。
    ev = event.Event{ .pointer_move = .{ .pos = .{ .x = -50, .y = 10 } } };
    _ = onEvent(&t, n, &ev);
    try std.testing.expect(geo.approxEq(0, n.widget.slider.value));
    ev = event.Event{ .pointer_move = .{ .pos = .{ .x = 150, .y = 10 } } };
    _ = onEvent(&t, n, &ev);
    try std.testing.expect(geo.approxEq(100, n.widget.slider.value));
    // 抬起结束拖动。
    ev = event.Event{ .pointer_up = .{ .pos = .{ .x = 80, .y = 10 } } };
    _ = onEvent(&t, n, &ev);
    try std.testing.expect(!n.widget.slider.dragging);
    // 非拖动时移动不调值。
    ev = event.Event{ .pointer_move = .{ .pos = .{ .x = 80, .y = 10 } } };
    _ = onEvent(&t, n, &ev);
    try std.testing.expect(geo.approxEq(100, n.widget.slider.value));
}

test "slider: value fraction clamps" {
    const d = widget.Slider{ .value = 150, .min = 0, .max = 100 };
    try std.testing.expect(geo.approxEq(1, valueFraction(d)));
    const d2 = widget.Slider{ .value = -5, .min = 0, .max = 100 };
    try std.testing.expect(geo.approxEq(0, valueFraction(d2)));
    const d3 = widget.Slider{ .value = 50, .min = 0, .max = 100 };
    try std.testing.expect(geo.approxEq(0.5, valueFraction(d3)));
}

test "slider: hover shows gray mask on thumb (MockPainter)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try node.Tree.init(arena.allocator(), &theme.light);
    defer t.deinit();

    const n = try t.createNode(t.root);
    n.widget = .{ .slider = .{ .value = 50, .min = 0, .max = 100 } };
    n.rect = .{ .x = 0, .y = 0, .w = 100, .h = 20 };

    var mp = try painter.MockPainter.init(std.testing.allocator, &theme.light);
    defer mp.destroy();
    // value=50 → 轨道 fillRoundedRect、已滑段 fillRoundedRect、拇指 fillEllipse。

    // 无 hover：轨道 bg_pressed，拇指 accent。
    paint(&t, mp.ctx, n, n.widget.slider);
    try std.testing.expect(mp.calls.items[0].fillRoundedRect.color.r == theme.light.bg_pressed.r);
    try std.testing.expect(mp.calls.items[2].fillEllipse.color.r == theme.light.accent.r);

    // hover：拇指灰色遮罩（bg_hover），轨道不变，无描边。
    mp.reset();
    t.hover = n;
    paint(&t, mp.ctx, n, n.widget.slider);
    try std.testing.expect(mp.calls.items[0].fillRoundedRect.color.r == theme.light.bg_pressed.r);
    try std.testing.expect(mp.calls.items[2].fillEllipse.color.r == theme.light.bg_hover.r);
    var strokes: usize = 0;
    for (mp.calls.items) |c| {
        if (c == .strokeRect) strokes += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), strokes);
}
