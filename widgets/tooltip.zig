//! widgets/tooltip.zig —— Tooltip 控件行为 + 弹层生命周期控制器（规则 §5.8 / §6 P0-1）。
//!
//! 模块不变量：
//! - 纯行为，数据在 core/widget.zig 的 Tooltip；视觉只取 theme token（L9）；
//! - 帧路径零分配（L4）：measure/paint 不分配（TextLayout 走 text_system 缓存）；
//! - show/hide 属事件/定时路径（非帧路径）：节点创建与文本拷贝入 tree arena（L5）；
//! - Controller 由 platform 在 UI 线程驱动（L7）：sync 于指针事件后、showTick 于 Ticker 推进。
//!
//! 状态机（P0-1，驱动源 = 指针 hover / Ticker 定时）：
//!   hidden → pending（hover 停留锚节点 ≥ SHOW_DELAY）→ showing → hidden
//! - hidden → pending：sync 发现 hover 锚（沿祖先找 tip）变化且非抑制，setTimeout(SHOW_DELAY)；
//! - pending → showing：定时到期 showTick → 创建/复用 tree.overlay 浮层节点（穿透命中）；
//! - showing/pending → hidden：hover 离开锚（sync）/ 任一指针按下（press，抑制至指针
//!   离开该锚）/ 窗口失焦、resize（platform 调 hide，位置失效）。

const std = @import("std");
const geo = @import("../core/geometry.zig");
const layout = @import("../core/layout.zig");
const node = @import("../core/node.zig");
const painter = @import("../core/painter.zig");
const widget = @import("../core/widget.zig");
const theme = @import("../theme.zig");
const ticker_mod = @import("../core/ticker.zig");

/// hover 停留到显示的延迟（秒，§5.13 Ticker setTimeout）。
pub const SHOW_DELAY: f64 = 0.5;

/// 求浮层固有尺寸：caption 字体单行 bounds + 双侧内边距。
pub fn measure(tree: *node.Tree, d: widget.Tooltip, c: layout.Constraints) geo.Size {
    if (tree.text_system) |ts| {
        if (ts.layout(d.text, &tree.theme_ref.font_caption, c.max.width, .{})) |tl| {
            return .{
                .width = tl.bounds.width + 2 * widget.Tooltip.pad_h,
                .height = tl.bounds.height + 2 * widget.Tooltip.pad_v,
            };
        }
    }
    return .{};
}

/// 绘制浮层：圆角底 + 边框 + caption 文本（视觉全取 token，L9）。
pub fn paint(tree: *node.Tree, pc: painter.PaintCtx, rect: geo.Rect, d: widget.Tooltip) void {
    const th = tree.theme_ref;
    pc.fillRoundedRect(rect, th.radius.small, th.bg_surface);
    pc.strokeRect(rect, th.border, 1, th.radius.small);
    if (d.text.len == 0) return;
    if (tree.text_system) |ts| {
        if (ts.layout(d.text, &th.font_caption, rect.w, .{})) |tl| {
            const inner = rect.inset(.{
                .left = widget.Tooltip.pad_h,
                .top = widget.Tooltip.pad_v,
                .right = widget.Tooltip.pad_h,
                .bottom = widget.Tooltip.pad_v,
            });
            pc.drawText(inner, tl, th.text);
        }
    }
}

/// 浮层定位（P0-1 定位 API）：锚下方左对齐 + gap；下方放不下翻到锚上方；
/// 水平/垂直钳制在视口内。全部 DIP，返回窗口坐标矩形。
pub fn place(anchor: geo.Rect, size: geo.Size, viewport: geo.Size, gap: f32) geo.Rect {
    var r = geo.Rect{
        .x = anchor.x,
        .y = anchor.y + anchor.h + gap,
        .w = size.width,
        .h = size.height,
    };
    // 下方溢出 → 翻转到锚上方。
    if (r.y + r.h > viewport.height) {
        r.y = anchor.y - gap - size.height;
    }
    // 垂直钳制（翻转后仍溢出 = 上下都放不下 → 贴底；负值 → 贴顶）。
    if (r.y + r.h > viewport.height) r.y = @max(0, viewport.height - size.height);
    if (r.y < 0) r.y = 0;
    // 水平钳制（右溢出左移；比视口宽 → 贴左缘）。
    if (r.x + r.w > viewport.width) r.x = @max(0, viewport.width - size.width);
    return r;
}

/// Tooltip 生命周期控制器（P0-1 弹层公共基建的首个消费者）。
/// UI 线程唯一（L7）；platform/window.zig 在指针事件后驱动 sync、失焦/resize 时调 hide。
pub const Controller = struct {
    /// 目标树（浮层挂 tree.overlay 顶层槽）。
    tree: *node.Tree,
    /// 复用的浮层节点（首次 show 时创建；arena 存活，flags.visible 控制显隐）。
    tip_node: ?*node.Node = null,
    /// 显示中的锚节点。
    anchor: ?*node.Node = null,
    /// 待显示锚（pending 定时期间）。
    pending: ?*node.Node = null,
    /// show 延迟定时器句柄（null = 无待触发定时）。
    timer: ?usize = null,
    /// 点击抑制锚：按下 dismiss 后，指针未离开该锚前不再自动弹出。
    block: ?*node.Node = null,
    /// 视口尺寸（DIP）：sync 时由 platform 更新，show 定位钳制用。
    viewport: geo.Size = .{},

    /// 构造（UI 线程）。tree 须存活至窗口关闭。
    pub fn init(tree: *node.Tree) Controller {
        return .{ .tree = tree };
    }

    /// hover 变化后调度/取消显示（platform 于 tree.dispatch 后调用）。
    /// - 参数：hover = tree.hover（穿透浮层不影响）；viewport = 当前客户区 DIP；
    ///   tk/now = 平台 Ticker 与单调钟（§5.13）；
    /// - 线程：UI 线程唯一（L7）。
    pub fn sync(self: *Controller, hover: ?*node.Node, viewport: geo.Size, tk: *ticker_mod.Ticker, now: f64) void {
        self.viewport = viewport;
        const anchor = findAnchor(hover);
        // 显示中锚变化：立即隐藏（hover 离开取消）。
        if (self.anchor) |a| {
            if (a != anchor) self.hide(tk);
        }
        // 离开被抑制的锚：解除抑制。
        if (self.block) |b| {
            if (b != anchor) self.block = null;
        }
        if (anchor == null) {
            // hover 离开（无锚）：取消待触发定时——滑过锚后在锚外停下不得弹出。
            if (self.timer) |h| tk.clearTimer(h);
            self.timer = null;
            self.pending = null;
            return;
        }
        if (anchor == self.block) return; // 点击抑制中。
        if (anchor == self.pending or anchor == self.anchor) return; // 同锚：不重置定时。
        if (self.timer) |h| tk.clearTimer(h);
        self.pending = anchor;
        self.timer = tk.setTimeout(showTick, self, SHOW_DELAY, now);
    }

    /// 任一指针按下：dismiss 并抑制（指针离开该锚前不再自动弹出）。
    pub fn press(self: *Controller, tk: *ticker_mod.Ticker) void {
        const a = self.anchor;
        self.hide(tk);
        self.block = a;
    }

    /// 隐藏浮层并取消待触发定时（hover 离开 / 失焦 / resize）。
    pub fn hide(self: *Controller, tk: *ticker_mod.Ticker) void {
        if (self.timer) |h| tk.clearTimer(h);
        self.timer = null;
        self.pending = null;
        self.anchor = null;
        const n = self.tip_node orelse return;
        if (n.flags.visible) {
            // 旧区域标脏：浮层消失后重绘露出的底层内容（§5.4 局部脏区）。
            self.tree.markDirtyRect(n.rect);
            n.flags.visible = false;
        }
    }

    /// Ticker 定时回调（§5.13）：到期显示 pending 锚的浮层。
    fn showTick(ctx: ?*anyopaque) void {
        const self: *Controller = @ptrCast(@alignCast(ctx.?));
        self.timer = null;
        const a = self.pending orelse return;
        self.pending = null;
        self.show(a);
    }

    /// 显示锚的浮层（事件/定时路径，可分配：节点/文本入 arena，L5）。UI 线程唯一。
    pub fn show(self: *Controller, anchor: *node.Node) void {
        const n = self.tip_node orelse blk: {
            const n = self.tree.createNode(self.tree.overlay) catch return;
            n.widget = .{ .tooltip = .{ .text = "" } };
            n.flags.pointer_pass = true; // 命中穿透（hit 无效，hover 落到底层内容）。
            n.flags.visible = false;
            self.tree.appendChild(self.tree.overlay, n) catch return;
            self.tip_node = n;
            break :blk n;
        };
        n.widget.tooltip.text = self.tree.allocStr(anchor.tip) catch return;
        // 尺寸经分发表测叶子（§5.4）；约束 = 视口（loosen 语义由 measureWidget 调用方承担）。
        // 钳制到视口：超长文本的浮层不越窗（measureWidget 契约不做 constrain）。
        const raw: geo.Size = if (self.tree.dispatch_table) |d|
            d.measureWidget(self.tree, n, .{ .max = self.viewport })
        else
            .{};
        const size: geo.Size = .{
            .width = @min(raw.width, self.viewport.width),
            .height = @min(raw.height, self.viewport.height),
        };
        n.hand_rect = place(anchor.rect, size, self.viewport, self.tree.theme_ref.spacing.xxs);
        n.flags.visible = true;
        n.invalidateLayout(); // hand_rect 变更 → 下轮 arrange 提升（§5.3 绝对定位）。
        // 新位置标脏：arrange 提升前 rect 是旧值，须直接并入 hand_rect 区域（§5.4）。
        self.tree.markDirtyRect(n.hand_rect);
        self.anchor = anchor;
    }

    /// 从 hover 起沿祖先找最近带 tip 的节点（子节点继承容器提示）。
    fn findAnchor(hover: ?*node.Node) ?*node.Node {
        var cur = hover;
        while (cur) |c| {
            if (c.tip.len > 0) return c;
            cur = c.parent;
        }
        return null;
    }
};

// —— 测试 ——

/// 假分发表：measure 固定 80×20（core 不能 import widgets，路由用假表验证）。
const Fake = struct {
    fn measureWidget(tree: *node.Tree, n: *node.Node, c: layout.Constraints) geo.Size {
        _ = tree;
        _ = n;
        return c.constrain(.{ .width = 80, .height = 20 });
    }
    fn paintWidget(tree: *node.Tree, n: *node.Node, pc: painter.PaintCtx) void {
        _ = tree;
        _ = n;
        _ = pc;
    }
    fn onEvent(tree: *node.Tree, n: *node.Node, e: *const @import("../core/event.zig").Event) bool {
        _ = tree;
        _ = n;
        _ = e;
        return false;
    }
};
const fake_table = node.DispatchTable{
    .measureWidget = Fake.measureWidget,
    .paintWidget = Fake.paintWidget,
    .onEvent = Fake.onEvent,
};

test "place: below anchor, flip above on overflow, clamp to viewport" {
    const vp = geo.Size{ .width = 200, .height = 100 };
    // 常规：锚下方左对齐 + gap。
    var r = place(.{ .x = 10, .y = 10, .w = 50, .h = 20 }, .{ .width = 60, .height = 18 }, vp, 4);
    try std.testing.expect(geo.approxEq(10, r.x));
    try std.testing.expect(geo.approxEq(34, r.y)); // 10 + 20 + 4
    // 锚贴底：下方放不下 → 翻到锚上方。
    r = place(.{ .x = 10, .y = 80, .w = 50, .h = 16 }, .{ .width = 60, .height = 18 }, vp, 4);
    try std.testing.expect(geo.approxEq(58, r.y)); // 80 - 4 - 18
    // 锚贴右缘：左移贴视口右缘。
    r = place(.{ .x = 180, .y = 10, .w = 50, .h = 20 }, .{ .width = 60, .height = 18 }, vp, 4);
    try std.testing.expect(geo.approxEq(140, r.x)); // 200 - 60
    // 上下都放不下（视口矮于浮层）：贴底钳制、不出界。
    r = place(.{ .x = 10, .y = 90, .w = 50, .h = 16 }, .{ .width = 60, .height = 120 }, vp, 4);
    try std.testing.expect(geo.approxEq(0, r.y)); // max(0, 100-120)
}

/// 测试用假 TextSystem：固定 bounds。
const MockTs = struct {
    layout: painter.TextLayout,
    fn layoutImpl(impl: *anyopaque, _: []const u8, _: *const theme.Font, _: f32, _: painter.TextLayoutOptions) ?*painter.TextLayout {
        const self: *MockTs = @ptrCast(@alignCast(impl));
        return &self.layout;
    }
};

test "tooltip measure adds padding to text bounds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try node.Tree.init(arena.allocator(), &theme.light);
    defer t.deinit();

    var mock = MockTs{ .layout = .{ .bounds = .{ .width = 100, .height = 14 } } };
    t.text_system = .{ .vtable = &.{ .layout = &MockTs.layoutImpl }, .impl = &mock };

    const s = measure(&t, .{ .text = "hello" }, .{ .max = .{ .width = 1000, .height = 1000 } });
    try std.testing.expect(geo.approxEq(116, s.width)); // 100 + 2×8
    try std.testing.expect(geo.approxEq(22, s.height)); // 14 + 2×4
}

test "controller: hover schedules, timer shows, leave hides, press suppresses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try node.Tree.init(arena.allocator(), &theme.light);
    defer t.deinit();
    t.dispatch_table = &fake_table;

    const anchor = try t.createNode(t.root);
    anchor.tip = "hello";
    anchor.rect = .{ .x = 10, .y = 10, .w = 50, .h = 20 };

    var tk = ticker_mod.Ticker{};
    var ctrl = Controller.init(&t);
    const vp = geo.Size{ .width = 400, .height = 300 };

    // hover 进入锚：pending（挂上 Ticker）。
    ctrl.sync(anchor, vp, &tk, 0.0);
    try std.testing.expect(ctrl.pending == anchor);
    try std.testing.expect(tk.hasActive());
    // 未到期：不显示。
    _ = tk.advance(0.3);
    try std.testing.expect(ctrl.tip_node == null);
    // 到期：浮层显示于锚下方（gap = spacing.xxs = 4）。
    _ = tk.advance(0.6);
    const tip = ctrl.tip_node.?;
    try std.testing.expect(tip.flags.visible);
    try std.testing.expect(tip.flags.pointer_pass);
    try std.testing.expect(tip.parent == t.overlay);
    try std.testing.expect(geo.approxEq(10, tip.hand_rect.x));
    try std.testing.expect(geo.approxEq(34, tip.hand_rect.y)); // 10 + 20 + 4
    try std.testing.expect(geo.approxEq(80, tip.hand_rect.w)); // 假表固定尺寸
    // hover 离开：隐藏。
    ctrl.sync(null, vp, &tk, 1.0);
    try std.testing.expect(!tip.flags.visible);
    try std.testing.expect(ctrl.anchor == null);

    // 重新 hover → 显示 → 按下：隐藏并抑制。
    ctrl.sync(anchor, vp, &tk, 2.0);
    _ = tk.advance(2.6);
    try std.testing.expect(tip.flags.visible);
    ctrl.press(&tk);
    try std.testing.expect(!tip.flags.visible);
    // 同锚 move：抑制中，不再调度。
    ctrl.sync(anchor, vp, &tk, 3.0);
    try std.testing.expect(ctrl.pending == null);
    _ = tk.advance(5.0);
    try std.testing.expect(!tip.flags.visible);
    // 离开再回来：抑制解除，恢复调度。
    ctrl.sync(null, vp, &tk, 6.0);
    ctrl.sync(anchor, vp, &tk, 6.1);
    try std.testing.expect(ctrl.pending == anchor);
    _ = tk.advance(6.7);
    try std.testing.expect(tip.flags.visible);
}

test "controller: leaving anchor before delay elapses cancels pending" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try node.Tree.init(arena.allocator(), &theme.light);
    defer t.deinit();

    const anchor = try t.createNode(t.root);
    anchor.tip = "hello";
    anchor.rect = .{ .x = 10, .y = 10, .w = 50, .h = 20 };

    var tk = ticker_mod.Ticker{};
    var ctrl = Controller.init(&t);
    const vp = geo.Size{ .width = 400, .height = 300 };

    // hover 经过锚（挂上 0.5s 定时）→ 延迟内移出到无 tip 区停下。
    ctrl.sync(anchor, vp, &tk, 0.0);
    try std.testing.expect(ctrl.pending == anchor);
    ctrl.sync(null, vp, &tk, 0.2);
    // 定时被取消：无 pending、无活跃定时器。
    try std.testing.expect(ctrl.pending == null);
    try std.testing.expect(!tk.hasActive());
    // 到期后不显示（滑过后在锚外停下不得弹出）。
    _ = tk.advance(1.0);
    try std.testing.expect(ctrl.tip_node == null);
}

test "controller: moving to another anchor re-targets pending" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try node.Tree.init(arena.allocator(), &theme.light);
    defer t.deinit();
    t.dispatch_table = &fake_table;

    const a = try t.createNode(t.root);
    a.tip = "first";
    a.rect = .{ .x = 10, .y = 10, .w = 50, .h = 20 };
    const b = try t.createNode(t.root);
    b.tip = "second";
    b.rect = .{ .x = 10, .y = 60, .w = 50, .h = 20 };

    var tk = ticker_mod.Ticker{};
    var ctrl = Controller.init(&t);
    const vp = geo.Size{ .width = 400, .height = 300 };

    // 锚 A 挂定时 → 延迟内移到锚 B：定时重挂到 B。
    ctrl.sync(a, vp, &tk, 0.0);
    ctrl.sync(b, vp, &tk, 0.2);
    try std.testing.expect(ctrl.pending == b);
    // 到期只显示 B（A 被替换，不残留）。
    _ = tk.advance(0.8);
    try std.testing.expect(ctrl.anchor == b);
    const tip = ctrl.tip_node.?;
    try std.testing.expect(std.mem.eql(u8, tip.widget.tooltip.text, "second"));
}

test "controller: finds tip on ancestor (inheritance)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try node.Tree.init(arena.allocator(), &theme.light);
    defer t.deinit();

    // 容器带 tip，hover 落在无 tip 的子节点上。
    const box = try t.createNode(t.root);
    box.tip = "container tip";
    const child = try t.createNode(box);
    try t.replaceChildren(box, &.{child});

    var tk = ticker_mod.Ticker{};
    var ctrl = Controller.init(&t);
    ctrl.sync(child, .{ .width = 400, .height = 300 }, &tk, 0.0);
    try std.testing.expect(ctrl.pending == box);
}
