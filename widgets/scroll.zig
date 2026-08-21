//! widgets/scroll.zig —— Scroll 滚动容器行为（规则 §6）。
//!
//! 状态机（文件头，§5.8）：
//!   静止 → 滚动（滚轮 / Edit 拖选越界 / 拇指拖拽）→ 静止
//! - 滚动 = 改 offset_y + invalidateLayout 强制 arrange 重排（仅改显示不改尺寸，
//!   传播终止 §5.5 的例外）；paint 由 clipIntersects 剔除视口外内容（§5.4，
//!   10000 行 60fps 的前提）；
//! - 拇指拖拽（P0-3 可视滚动条）：pointer_down 落拇指内进入拖拽（core dispatch 按
//!   thumbRect 几何路由，active=scroll，拖动中 move/up 经 active 回它）；grab_off
//!   保持抓取点；pointer_up 结束并完全消费（滚动条无 click 语义）；
//! - 拇指是**视口固定覆盖层**：paint 画在条带 blit / 内容之后（paintNode 接线），
//!   不进离屏条带、不随内容滚；
//! - 子节点按通用容器布局（内容为 column，v1 只做纵向）；
//! - offset 钳制到 [0, content_h − 视口高]；content_h 由 core arrange 刷新；
//! - 帧路径（measure/paint）零分配；滚动是事件路径（允许 invalidate 标脏）。
//!
//! 模块不变量：
//! - 本文件不 import 平台/渲染（L1）；scroll 的 measure 走布局容器路径不经 dispatch；
//! - 偏移变更只有经 setOffset/scrollBy 才发生（统一钳制 + 标脏）；
//! - 视觉只取 theme token（L9）：拇指 idle bg_hover，悬停/拖拽 bg_pressed。

const std = @import("std");
const geo = @import("../core/geometry.zig");
const node = @import("../core/node.zig");
const painter = @import("../core/painter.zig");
const widget = @import("../core/widget.zig");
const event = @import("../core/event.zig");

/// 滚轮一步滚动的像素（DIP）。
const wheel_step: f32 = 24;
/// Edit 拖选越界自动滚动一档的像素（DIP）。
const auto_scroll_step: f32 = 16;

/// 滚动到指定偏移（钳制到 [0, content_h − 视口高]）。偏移不变则什么都不做。
/// 偏移变更走 invalidateLayout 强制 arrange 重排 + invalidatePaintOnly 重绘（不失效离屏表面，§5.6）。
pub fn setOffset(n: *node.Node, y: f32) void {
    const d = &n.widget.scroll;
    const max_off = maxOffset(n);
    const clamped = std.math.clamp(y, 0, max_off);
    if (geo.approxEq(clamped, d.offset_y)) return;
    d.offset_y = clamped;
    n.invalidateLayout();
    // 滚动平移：仅标脏重绘，不失效离屏表面（§5.6 复用前提——内容未变，只平移 DrawSurface）。
    n.invalidatePaintOnly();
}

/// 增量滚动（滚轮/拖选越界）：正 = 内容下移（看向更后）。
pub fn scrollBy(n: *node.Node, dy: f32) void {
    setOffset(n, n.widget.scroll.offset_y + dy);
}

/// 内容可滚动的最大偏移（内容总高 − 视口高，不小于 0）。
pub fn maxOffset(n: *node.Node) f32 {
    const d = &n.widget.scroll;
    return @max(0, d.content_h - viewportHeight(n));
}

/// 视口高度（DIP）：节点高减上下 padding。
pub fn viewportHeight(n: *node.Node) f32 {
    return @max(0, n.rect.h - n.style.padding.top - n.style.padding.bottom);
}

/// 内建事件处理（dispatch_table.onEvent，§6）。滚轮滚动 + 拇指拖拽（P0-3），其余交回冒泡。
pub fn onEvent(tree: *node.Tree, n: *node.Node, e: *const event.Event) bool {
    _ = tree;
    return switch (e.*) {
        .wheel => |w| {
            // lines 正 = 内容向下（offset 增大）；负 = 向上。
            scrollBy(n, w.lines * wheel_step);
            return true;
        },
        .pointer_down => |p| {
            const d = &n.widget.scroll;
            const tr = d.thumbRect(n.rect.inset(n.style.padding)) orelse return false;
            if (!tr.contains(p.pos)) return false;
            d.thumb_drag = true;
            d.thumb_grab_off = p.pos.y - tr.y; // 抓取点保持：拖动拇指不跳变。
            n.invalidatePaint();
            return true;
        },
        .pointer_move => |p| {
            const d = &n.widget.scroll;
            if (!d.thumb_drag) return false;
            setOffsetFromThumbY(n, p.pos.y - d.thumb_grab_off);
            return true;
        },
        .pointer_up => {
            const d = &n.widget.scroll;
            if (!d.thumb_drag) return false;
            d.thumb_drag = false;
            n.invalidatePaint();
            return true; // 拖拽收尾完全消费（滚动条无 click 语义，不冒泡）。
        },
        else => return false,
    };
}

/// 拇指顶边期望 y（根空间 DIP，含抓取偏移）→ offset：行程 = 视口高 − 拇指高，
/// 比例映射后经 setOffset 统一钳制 + 标脏（与 paint 的拇指定位同一几何，中心贴指针）。
fn setOffsetFromThumbY(n: *node.Node, thumb_y: f32) void {
    const d = &n.widget.scroll;
    const view = n.rect.inset(n.style.padding);
    const tr = d.thumbRect(view) orelse return;
    const travel = view.h - tr.h;
    if (travel <= 0) return;
    const frac = std.math.clamp((thumb_y - view.y) / travel, 0, 1);
    setOffset(n, frac * maxOffset(n));
}

/// 视口固定覆盖层（滚动条拇指，P0-3）：由 paintNode 在条带 blit / 内容之后调用
///（不随内容滚）；无溢出不绘制。视觉只取 token（L9）：idle bg_hover，悬停/拖拽 bg_pressed。
pub fn paint(tree: *node.Tree, pc: painter.PaintCtx, n: *node.Node) void {
    const d = &n.widget.scroll;
    const tr = d.thumbRect(n.rect.inset(n.style.padding)) orelse return;
    const th = tree.theme_ref;
    const active = d.thumb_drag or d.thumb_hover;
    pc.fillRoundedRect(tr, widget.Scroll.thumb_w * 0.5, if (active) th.bg_pressed else th.bg_hover);
}

/// Edit 拖选越界自动滚动（§6 DoD）：从节点向上找最近 scroll 祖先；指针 y（窗口 DIP）
/// 超出其视口时向对应方向滚动一档。返回是否发生了滚动。
pub fn autoScrollOnDrag(start: *node.Node, pointer_y: f32) bool {
    var cur: ?*node.Node = start;
    while (cur) |n| {
        if (n.widget == .scroll) {
            const d = &n.widget.scroll;
            const r = n.rect.inset(n.style.padding);
            if (pointer_y < r.y and d.offset_y > 0) {
                scrollBy(n, -auto_scroll_step);
                return true;
            }
            if (pointer_y > r.y + r.h and d.offset_y < maxOffset(n)) {
                scrollBy(n, auto_scroll_step);
                return true;
            }
            return false; // 最近 scroll 无越界需求：不再向上（内层 scroll 优先）。
        }
        cur = n.parent;
    }
    return false;
}

// —— 测试 ——

const layout = @import("../core/layout.zig");
const theme = @import("../theme.zig");

/// 固定尺寸 custom 叶子（measure 返回固定大小）。
const FixedCtx = struct {
    size: geo.Size,
    vtable: widget.CustomVTable = .{ .measure = measure },

    fn measure(ctx: *anyopaque, c: layout.Constraints) geo.Size {
        const self: *FixedCtx = @ptrCast(@alignCast(ctx));
        return c.constrain(self.size);
    }
};

fn addLeaf(t: *node.Tree, parent: *node.Node, size: geo.Size) !*node.Node {
    const ctx = try t.alloc(FixedCtx);
    ctx.* = .{ .size = size };
    const n = try t.createNode(parent);
    n.widget = .{ .custom = .{ .ctx = ctx, .vtable = &ctx.vtable } };
    try t.appendChild(parent, n);
    return n;
}

test "scroll: clamp offset within content range" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try node.Tree.init(arena.allocator(), &theme.light);
    defer t.deinit();

    // 滚动根：column 布局，视口 100×300，内容 3 个子节点（各 100 高，gap 0）。
    t.root.layout = .{ .column = .{} };
    t.root.widget = .{ .scroll = .{} };
    for (0..3) |_| _ = try addLeaf(&t, t.root, .{ .width = 100, .height = 100 });

    t.ensureLayout(.{ .width = 100, .height = 300 });
    // 内容 300 = 视口 300 → 无滚动余量。
    try std.testing.expect(geo.approxEq(0, maxOffset(t.root)));
    try std.testing.expect(geo.approxEq(0, t.root.widget.scroll.offset_y));

    // 再加一个子节点 → 内容 400，视口 300，余量 100。
    _ = try addLeaf(&t, t.root, .{ .width = 100, .height = 100 });
    t.root.invalidateMeasure();
    t.ensureLayout(.{ .width = 100, .height = 300 });
    try std.testing.expect(geo.approxEq(100, maxOffset(t.root)));

    // 滚到底：偏移钳制到 100；重排后子节点显示位置 = 内容位置 − 偏移。
    setOffset(t.root, 1000);
    try std.testing.expect(geo.approxEq(100, t.root.widget.scroll.offset_y));
    t.ensureLayout(.{ .width = 100, .height = 300 });
    try std.testing.expect(geo.approxEq(-100, t.root.children[0].rect.y));
    try std.testing.expect(geo.approxEq(200, t.root.children[3].rect.y));

    // 滚回顶部。
    setOffset(t.root, 0);
    t.ensureLayout(.{ .width = 100, .height = 300 });
    try std.testing.expect(geo.approxEq(0, t.root.children[0].rect.y));

    // 未越界滚动是 no-op（不标脏，避免无效重排）。
    setOffset(t.root, 0);
    try std.testing.expect(!t.root.layout_dirty);
}

test "scroll: wheel event scrolls by step" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try node.Tree.init(arena.allocator(), &theme.light);
    defer t.deinit();

    t.root.layout = .{ .column = .{} };
    t.root.widget = .{ .scroll = .{} };
    for (0..5) |_| _ = try addLeaf(&t, t.root, .{ .width = 100, .height = 100 });
    t.ensureLayout(.{ .width = 100, .height = 300 });

    // 向下滚 2 档（lines = 2）。
    var ev = event.Event{ .wheel = .{ .pos = .{ .x = 50, .y = 50 }, .lines = 2 } };
    _ = onEvent(&t, t.root, &ev);
    try std.testing.expect(geo.approxEq(wheel_step * 2, t.root.widget.scroll.offset_y));
    // 向上滚 1 档。
    ev = event.Event{ .wheel = .{ .pos = .{ .x = 50, .y = 50 }, .lines = -1 } };
    _ = onEvent(&t, t.root, &ev);
    try std.testing.expect(geo.approxEq(wheel_step, t.root.widget.scroll.offset_y));
}

test "scroll: auto scroll on drag beyond viewport" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try node.Tree.init(arena.allocator(), &theme.light);
    defer t.deinit();

    t.root.layout = .{ .column = .{} };
    t.root.widget = .{ .scroll = .{} };
    const leaf = try addLeaf(&t, t.root, .{ .width = 100, .height = 100 });
    _ = try addLeaf(&t, t.root, .{ .width = 100, .height = 100 });
    _ = try addLeaf(&t, t.root, .{ .width = 100, .height = 100 });
    _ = try addLeaf(&t, t.root, .{ .width = 100, .height = 100 });
    t.ensureLayout(.{ .width = 100, .height = 300 });

    // 视口 y ∈ [0,300]；指针在下方 → 向下自动滚动一档。
    try std.testing.expect(autoScrollOnDrag(leaf, 350));
    try std.testing.expect(geo.approxEq(auto_scroll_step, t.root.widget.scroll.offset_y));
    // 指针回到视口内 → 不再滚动。
    try std.testing.expect(!autoScrollOnDrag(leaf, 150));
    try std.testing.expect(geo.approxEq(auto_scroll_step, t.root.widget.scroll.offset_y));
    // 滚到底后指针仍在下方 → 不越界（钳制），返回 false。
    setOffset(t.root, 1000);
    try std.testing.expect(!autoScrollOnDrag(leaf, 350));
    // 指针在上方 → 向上滚动。
    try std.testing.expect(autoScrollOnDrag(leaf, -10));
    try std.testing.expect(geo.approxEq(maxOffset(t.root) - auto_scroll_step, t.root.widget.scroll.offset_y));
}

test "scroll: thumb geometry proportional, clamped, hidden without overflow (P0-3)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try node.Tree.init(arena.allocator(), &theme.light);
    defer t.deinit();

    // 视口 200、内容 400（4×100）：拇指高 = 200²/400 = 100，行程 = 100。
    t.root.layout = .{ .column = .{} };
    t.root.widget = .{ .scroll = .{} };
    for (0..4) |_| _ = try addLeaf(&t, t.root, .{ .width = 100, .height = 100 });
    t.ensureLayout(.{ .width = 100, .height = 200 });
    const d = &t.root.widget.scroll;
    const view = t.root.rect.inset(t.root.style.padding);

    const tr0 = d.thumbRect(view).?;
    try std.testing.expect(geo.approxEq(100, tr0.h));
    try std.testing.expect(geo.approxEq(0, tr0.y)); // offset 0 → 拇指顶在视口顶。
    try std.testing.expect(geo.approxEq(view.x + view.w - widget.Scroll.thumb_w - 2, tr0.x));
    // 滚到底（max_off 200）→ y = 行程 100。
    setOffset(t.root, 200);
    const tr1 = d.thumbRect(view).?;
    try std.testing.expect(geo.approxEq(100, tr1.y));
    // 中点 offset 100 → y = 50。
    setOffset(t.root, 100);
    const tr2 = d.thumbRect(view).?;
    try std.testing.expect(geo.approxEq(50, tr2.y));

    // 无溢出（内容 == 视口）→ 无拇指。
    var t2 = try node.Tree.init(arena.allocator(), &theme.light);
    defer t2.deinit();
    t2.root.layout = .{ .column = .{} };
    t2.root.widget = .{ .scroll = .{} };
    for (0..2) |_| _ = try addLeaf(&t2, t2.root, .{ .width = 100, .height = 100 });
    t2.ensureLayout(.{ .width = 100, .height = 200 });
    try std.testing.expect(t2.root.widget.scroll.thumbRect(t2.root.rect.inset(t2.root.style.padding)) == null);

    // 极小拇指下限：视口 200、内容 4000 → 高 = 200²/4000 = 10 → 钳到 min 24。
    d.content_h = 4000;
    const tr3 = d.thumbRect(view).?;
    try std.testing.expect(geo.approxEq(24, tr3.h));
}

test "scroll: thumb drag maps pointer to offset with grab offset (P0-3)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try node.Tree.init(arena.allocator(), &theme.light);
    defer t.deinit();

    // 视口 200、内容 400：拇指 (90, 0, 8, 100)，行程 100，max_off 200。
    t.root.layout = .{ .column = .{} };
    t.root.widget = .{ .scroll = .{} };
    for (0..4) |_| _ = try addLeaf(&t, t.root, .{ .width = 100, .height = 100 });
    t.ensureLayout(.{ .width = 100, .height = 200 });

    // 按在拇指中部 (94, 50)：grab_off = 50，进入拖拽。
    var ev = event.Event{ .pointer_down = .{ .pos = .{ .x = 94, .y = 50 } } };
    try std.testing.expect(onEvent(&t, t.root, &ev));
    try std.testing.expect(t.root.widget.scroll.thumb_drag);
    try std.testing.expect(geo.approxEq(50, t.root.widget.scroll.thumb_grab_off));

    // 拖到 y=150 → 拇指顶 100 → frac 1 → offset 200（滚到底）。
    ev = event.Event{ .pointer_move = .{ .pos = .{ .x = 94, .y = 150 } } };
    try std.testing.expect(onEvent(&t, t.root, &ev));
    try std.testing.expect(geo.approxEq(200, t.root.widget.scroll.offset_y));
    // 拖回 y=100 → 拇指顶 50 → frac 0.5 → offset 100。
    ev = event.Event{ .pointer_move = .{ .pos = .{ .x = 94, .y = 100 } } };
    try std.testing.expect(onEvent(&t, t.root, &ev));
    try std.testing.expect(geo.approxEq(100, t.root.widget.scroll.offset_y));
    // 越界钳制：拖出视口上下缘。
    ev = event.Event{ .pointer_move = .{ .pos = .{ .x = 94, .y = -50 } } };
    _ = onEvent(&t, t.root, &ev);
    try std.testing.expect(geo.approxEq(0, t.root.widget.scroll.offset_y));
    ev = event.Event{ .pointer_move = .{ .pos = .{ .x = 94, .y = 500 } } };
    _ = onEvent(&t, t.root, &ev);
    try std.testing.expect(geo.approxEq(200, t.root.widget.scroll.offset_y));

    // 抬起结束拖拽；此后 move 不再改 offset。
    ev = event.Event{ .pointer_up = .{ .pos = .{ .x = 94, .y = 10 } } };
    try std.testing.expect(onEvent(&t, t.root, &ev));
    try std.testing.expect(!t.root.widget.scroll.thumb_drag);
    ev = event.Event{ .pointer_move = .{ .pos = .{ .x = 94, .y = 100 } } };
    try std.testing.expect(!onEvent(&t, t.root, &ev));
    try std.testing.expect(geo.approxEq(200, t.root.widget.scroll.offset_y));

    // 按在拇指外（内容区）→ 不进入拖拽、不消费。
    ev = event.Event{ .pointer_down = .{ .pos = .{ .x = 50, .y = 150 } } };
    try std.testing.expect(!onEvent(&t, t.root, &ev));
    try std.testing.expect(!t.root.widget.scroll.thumb_drag);
}

test "scroll: paint draws thumb overlay only on overflow, token colors (MockPainter)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try node.Tree.init(arena.allocator(), &theme.light);
    defer t.deinit();

    t.root.layout = .{ .column = .{} };
    t.root.widget = .{ .scroll = .{} };
    for (0..4) |_| _ = try addLeaf(&t, t.root, .{ .width = 100, .height = 100 });
    t.ensureLayout(.{ .width = 100, .height = 200 });

    var mp = try painter.MockPainter.init(std.testing.allocator, &theme.light);
    defer mp.destroy();

    // 溢出：1 次 fillRoundedRect，idle 色 bg_hover。
    paint(&t, mp.ctx, t.root);
    try std.testing.expectEqual(@as(usize, 1), mp.calls.items.len);
    try std.testing.expect(mp.calls.items[0].fillRoundedRect.color.r == theme.light.bg_hover.r);

    // 悬停/拖拽 → bg_pressed。
    mp.reset();
    t.root.widget.scroll.thumb_drag = true;
    paint(&t, mp.ctx, t.root);
    try std.testing.expect(mp.calls.items[0].fillRoundedRect.color.r == theme.light.bg_pressed.r);
    t.root.widget.scroll.thumb_drag = false;

    // 无溢出：不绘制。
    mp.reset();
    t.root.widget.scroll.content_h = 200;
    paint(&t, mp.ctx, t.root);
    try std.testing.expectEqual(@as(usize, 0), mp.calls.items.len);
}
