//! widgets/scroll.zig —— Scroll 滚动容器行为（规则 §6）。
//!
//! 状态机（文件头，§5.8）：
//!   静止 → 滚动（滚轮 / Edit 拖选越界）→ 静止
//! - 滚动 = 改 offset_y + invalidateLayout 强制 arrange 重排（仅改显示不改尺寸，
//!   传播终止 §5.5 的例外）；paint 由 paintNode 的 clipIntersects 剔除视口外内容（§5.4，
//!   10000 行 60fps 的前提）；
//! - 子节点按通用容器布局（内容为 column，v1 只做纵向）；
//! - offset 钳制到 [0, content_h − 视口高]；content_h 由 core arrange 刷新；
//! - 帧路径（measure/paint）零分配；滚动是事件路径（允许 invalidate 标脏）。
//!
//! 模块不变量：
//! - 本文件不 import 平台/渲染（L1）；scroll 是容器，不参与 dispatch 的 measure/paint 路由；
//! - 偏移变更只有经 setOffset/scrollBy 才发生（统一钳制 + 标脏）。

const std = @import("std");
const geo = @import("../core/geometry.zig");
const node = @import("../core/node.zig");
const event = @import("../core/event.zig");

/// 滚轮一步滚动的像素（DIP）。
const wheel_step: f32 = 24;
/// Edit 拖选越界自动滚动一档的像素（DIP）。
const auto_scroll_step: f32 = 16;

/// 滚动到指定偏移（钳制到 [0, content_h − 视口高]）。偏移不变则什么都不做。
/// 偏移变更走 invalidateLayout 强制 arrange 重排 + invalidatePaint 重绘。
pub fn setOffset(n: *node.Node, y: f32) void {
    const d = &n.widget.scroll;
    const max_off = maxOffset(n);
    const clamped = std.math.clamp(y, 0, max_off);
    if (geo.approxEq(clamped, d.offset_y)) return;
    d.offset_y = clamped;
    n.invalidateLayout();
    n.invalidatePaint();
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

/// 内建事件处理（dispatch_table.onEvent，§6）。仅处理滚轮，其余交回冒泡。
pub fn onEvent(tree: *node.Tree, n: *node.Node, e: *const event.Event) bool {
    _ = tree;
    return switch (e.*) {
        .wheel => |w| {
            // lines 正 = 内容向下（offset 增大）；负 = 向上。
            scrollBy(n, w.lines * wheel_step);
            return true;
        },
        else => return false,
    };
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

const widget = @import("../core/widget.zig");
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
