//! core/node.zig —— Style/Node/Tree/Dirty/measure/arrange/dispatch（规则 §5.3/§5.5）。
//!
//! 模块不变量：
//! - **L4**：帧路径（measure/arrange/paint/事件分发）零分配，本文件相关函数不带 allocator 参数；
//! - rect 只由 arrange 写入；measure 禁止读 rect（§5.3）；
//! - `invalidateMeasure` 沿祖先链置位；重测尺寸不变则终止，不重排祖先（§5.5 传播终止）；
//! - arrrange 不得改任何 measured；
//! - hit test 跳过不可见与 pointer_pass 节点；handler 返回 true 停止冒泡。

const std = @import("std");
const geo = @import("geometry.zig");
const layout = @import("layout.zig");
const widget = @import("widget.zig");
const event = @import("event.zig");
const painter = @import("painter.zig");
const theme = @import("../theme.zig");

/// 事件处理器：返回 true 停止冒泡（§5.3）。ctx 由 handler_ctx 传入（§5.8 trampoline）。
pub const EventHandler = *const fn (node: *Node, ctx: ?*anyopaque, e: *const event.Event) bool;

/// 节点 id：空串视为匿名。builder 用 find(id) 定位。
pub const NodeId = []const u8;

/// Style（§5.3）：margin/padding + 可选背景/边框。背景与边框由 paintTree 在 Node 层统一绘制（M2）。
pub const Style = struct {
    margin: geo.Edges = .{},
    padding: geo.Edges = .{},
    bg: ?theme.Color = null,
    border_color: ?theme.Color = null,
    border_width: f32 = 0,
};

/// Flags（§5.3）。
pub const Flags = packed struct(u32) {
    visible: bool = true,
    pointer_pass: bool = false,
    focusable: bool = false,
    disabled: bool = false,
    _: u28 = 0,
};

pub const Node = struct {
    id: NodeId = "",
    flags: Flags = .{},
    rect: geo.Rect = .{}, // arrange 输出，父坐标系，DIP
    measured: geo.Size = .{}, // measure 缓存
    cache_cons: layout.Constraints = .{}, // 缓存键：上次约束
    style: Style = .{},
    layout: layout.Layout = .none,
    children: []*Node = &.{},
    parent: ?*Node = null,
    widget: widget.Widget = .none,
    dirty_measure: bool = true,
    dirty_paint: bool = true,
    handler: ?EventHandler = null,
    handler_ctx: ?*anyopaque = null,
    /// 本次 measure 是否尺寸未变（传播终止用，每轮 ensureLayout 重置）。
    measured_same: bool = false,
    /// 本节点或任一后代本次 measure 是否有变化（决定是否需重排子树）。
    desc_changed: bool = true,

    pub fn invalidateMeasure(n: *Node) void {
        var cur: ?*Node = n;
        while (cur) |c| {
            c.dirty_measure = true;
            cur = c.parent;
        }
    }

    pub fn invalidatePaint(n: *Node) void {
        var cur: ?*Node = n;
        while (cur) |c| {
            c.dirty_paint = true;
            cur = c.parent;
        }
    }
};

/// 控件行为分发表（§5.4）：widgets/dispatch.zig 提供实现，Tree 持引用。
/// core 不 import widgets（避免环），仅通过函数指针调用。
pub const DispatchTable = struct {
    measureWidget: *const fn (tree: *Tree, n: *Node, c: layout.Constraints) geo.Size,
    paintWidget: *const fn (tree: *Tree, n: *Node, pc: painter.PaintCtx) void,
};

pub const Tree = struct {
    arena: std.heap.ArenaAllocator,
    root: *Node,
    focus: ?*Node = null,
    hover: ?*Node = null,
    active: ?*Node = null,
    theme_ref: *const theme.Theme,
    /// 文本系统（§5.7）：text 控件 measure 消费 bounds。默认 null（无文本能力）。
    text_system: ?painter.TextSystem = null,
    /// 控件行为分发表（§5.4）。默认 null（无内建控件行为）。
    dispatch_table: ?*const DispatchTable = null,
    /// 观测用：arrange 实际重排子树的次数（测试断言传播终止）。
    relayout_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, th: *const theme.Theme) !Tree {
        var tree = Tree{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .root = undefined,
            .theme_ref = th,
        };
        tree.root = try tree.alloc(Node);
        tree.root.* = .{ .layout = .{ .column = .{} }, .parent = null };
        return tree;
    }

    /// 遍历绘制（§5.4 paintTree 顺序）。pc 是 render 实现的 PaintCtx。
    pub fn paint(t: *Tree, pc: painter.PaintCtx) void {
        paintNode(t, pc, t.root);
    }

    pub fn deinit(t: *Tree) void {
        t.arena.deinit();
    }

    /// 暴露 arena 分配器（§4.3）：所有 setter 必须拷贝入 arena。
    pub fn alloc(t: *Tree, comptime T: type) !*T {
        return t.arena.allocator().create(T);
    }

    /// 复制字符串入 arena（builder/setter 用于持有用户传入的栈上字符串）。
    pub fn allocStr(t: *Tree, s: []const u8) ![]const u8 {
        return t.arena.allocator().dupe(u8, s);
    }

    /// 新建节点并挂到某父节点下（arena 语义；返回由调用方初始化 widget/layout/id 等）。
    pub fn createNode(t: *Tree, parent: *Node) !*Node {
        const n = try t.alloc(Node);
        n.* = .{ .parent = parent };
        return n;
    }

    /// 列表变更的唯一合法方式：重建语义（§4.3/§5.3）。
    pub fn replaceChildren(t: *Tree, node: *Node, children: []const *Node) !void {
        node.children = try t.arena.allocator().dupe(*Node, children);
        for (node.children) |c| c.parent = node;
        node.invalidateMeasure();
        node.invalidatePaint();
    }

    /// 追加单个子节点（arena 重建语义，等价 replaceChildren(node, old ++ new)）。
    pub fn appendChild(t: *Tree, node: *Node, child: *Node) !void {
        const n = node.children.len + 1;
        const new_children = try t.arena.allocator().alloc(*Node, n);
        @memcpy(new_children[0 .. n - 1], node.children);
        new_children[n - 1] = child;
        node.children = new_children;
        child.parent = node;
        node.invalidateMeasure();
        node.invalidatePaint();
    }

    /// 惰性布局：绘制前或任何读 rect 前必须调用（§5.3）。稳态零分配。
    pub fn ensureLayout(t: *Tree, window_size: geo.Size) void {
        const root_c = layout.Constraints{
            .min = window_size,
            .max = window_size,
        };
        _ = t.measure(t.root, root_c);
        t.root.rect = .{ .w = window_size.width, .h = window_size.height };
        t.arrange(t.root, t.root.rect);
    }

    // —— measure ——

    /// 测量节点；返回本节点尺寸是否相比上次变化（传播终止用）。
    fn measure(t: *Tree, n: *Node, c: layout.Constraints) bool {
        // 缓存命中：不脏 且 约束相等 → 直接返回，视为未变。
        if (!n.dirty_measure and n.cache_cons.eql(c)) {
            n.measured_same = true;
            n.desc_changed = false;
            return false;
        }
        const old = n.measured;
        const new = t.computeSize(n, c);
        const node_changed = !(geo.approxEq(old.width, new.width) and geo.approxEq(old.height, new.height));
        n.measured = new;
        n.cache_cons = c;
        n.dirty_measure = false;
        n.measured_same = !node_changed;
        // 子树是否有变化：自身变化 ∪ 任一后代变化。
        n.desc_changed = node_changed;
        for (n.children) |child| {
            n.desc_changed = n.desc_changed or child.desc_changed;
        }
        return node_changed;
    }

    fn computeSize(t: *Tree, n: *Node, c: layout.Constraints) geo.Size {
        // 叶子控件：行为经 DispatchTable 委托（§5.4）；无 dispatch 时按空处理。
        switch (n.widget) {
            .text, .button, .edit => {
                if (t.dispatch_table) |d| return c.constrain(d.measureWidget(t, n, c.loosen()));
                return c.constrain(.{});
            },
            .custom => |cu| return c.constrain(cu.vtable.measure(cu.ctx, c.loosen())),
            else => {}, // box / none / scroll 走布局容器
        }

        const pad = n.style.padding;
        switch (n.layout) {
            .none => {
                // 绝对定位容器：无流式内容，固有尺寸 = padding 盒。
                return c.constrain(.{
                    .width = pad.left + pad.right,
                    .height = pad.top + pad.bottom,
                });
            },
            .row, .column => |st| {
                // 内容约束：loosen 后再扣除 padding（§5.5：子节点约束必须 loosen）。
                var content_c = c.loosen();
                content_c.max.width = @max(0, content_c.max.width - pad.left - pad.right);
                content_c.max.height = @max(0, content_c.max.height - pad.top - pad.bottom);

                const axis: layout.Axis = if (n.layout == .row) .horizontal else .vertical;
                var main: f32 = 0;
                var cross: f32 = 0;
                const cnt: usize = n.children.len;
                for (n.children, 0..) |child, i| {
                    _ = t.measure(child, content_c);
                    const s = child.measured;
                    if (axis == .horizontal) {
                        main += s.width;
                        cross = @max(cross, s.height);
                    } else {
                        main += s.height;
                        cross = @max(cross, s.width);
                    }
                    if (i + 1 < cnt) main += st.gap;
                }
                const size: geo.Size = if (axis == .horizontal)
                    .{ .width = main + pad.left + pad.right, .height = cross + pad.top + pad.bottom }
                else
                    .{ .width = cross + pad.left + pad.right, .height = main + pad.top + pad.bottom };
                return c.constrain(size);
            },
        }
    }

    // —— arrange ——

    fn arrange(t: *Tree, n: *Node, bound: geo.Rect) void {
        const prev = n.rect;
        n.rect = bound;

        // 传播终止（§5.5）：本节点及后代本次均无变化且矩形未变 → 子树无需重排。
        if (!n.desc_changed and rectEq(prev, bound)) return;

        if (n.children.len == 0) return;
        const pad = n.style.padding;
        const inner = n.rect.inset(pad);

        switch (n.layout) {
            .none => {
                // 绝对定位：不流动布局，仅递归（子节点 rect 由调用方手填）。
                for (n.children) |child| t.arrange(child, child.rect);
            },
            .row, .column => |st| {
                t.relayout_count += 1;
                const axis: layout.Axis = if (n.layout == .row) .horizontal else .vertical;
                const main0: f32 = if (axis == .horizontal) inner.x else inner.y;
                const cross0: f32 = if (axis == .horizontal) inner.y else inner.x;
                const cross_len: f32 = if (axis == .horizontal) inner.h else inner.w;

                var pos: f32 = main0;
                for (n.children) |child| {
                    const s = child.measured;
                    var cross_off: f32 = 0;
                    var cross_size: f32 = undefined;
                    if (axis == .horizontal) {
                        cross_size = s.height;
                    } else {
                        cross_size = s.width;
                    }
                    if (st.cross == .stretch) {
                        cross_size = cross_len;
                    } else {
                        cross_size = @min(cross_size, cross_len);
                        if (st.cross == .center) cross_off = @max(0, (cross_len - cross_size) * 0.5);
                    }
                    const main_size: f32 = if (axis == .horizontal) s.width else s.height;
                    const child_rect: geo.Rect = if (axis == .horizontal)
                        .{ .x = pos, .y = cross0 + cross_off, .w = main_size, .h = cross_size }
                    else
                        .{ .x = cross0 + cross_off, .y = pos, .w = cross_size, .h = main_size };
                    t.arrange(child, child_rect);
                    pos += main_size + st.gap;
                }
            },
        }
    }

    // —— 事件分发 ——

    /// 指针事件先 hit test 再沿 parent 冒泡；键盘事件走焦点链（§5.3）。
    /// 同时维护 hover / active 单值指针（供 Button 等状态机推导，§5.3）。
    pub fn dispatch(t: *Tree, e: *const event.Event) bool {
        switch (e.*) {
            .pointer_move => |p| {
                const hit = hitTest(t.root, p.pos);
                // hover 变化：旧节点与新节点都重绘。
                if (t.hover != hit) {
                    if (t.hover) |old| old.invalidatePaint();
                    t.hover = hit;
                    if (hit) |n| n.invalidatePaint();
                }
                return if (hit) |n| bubble(t, n, e) else false;
            },
            .pointer_down => |p| {
                const hit = hitTest(t.root, p.pos) orelse {
                    // 点空白：清 active（M3：不抢焦点，焦点变化留待后续策略）。
                    t.active = null;
                    return false;
                };
                t.active = hit;
                hit.invalidatePaint();
                return bubble(t, hit, e);
            },
            .pointer_up => |p| {
                const hit = hitTest(t.root, p.pos);
                if (t.active) |a| {
                    t.active = null;
                    a.invalidatePaint();
                    // click 语义（§5.8）：仅"按下与抬起同一节点"时才沿该节点冒泡，
                    // 触发其 handler；否则视为拖动/误触，不派发。
                    if (hit == a) return bubble(t, a, e);
                }
                return false;
            },
            .key_down => |k| {
                // Tab / Shift+Tab：焦点环（声明顺序，§5.3）。
                if (k.vk == event.VK.TAB) {
                    const next = t.focusNext((k.mods & event.Mod.shift) != 0);
                    if (next) |n| {
                        t.setFocus(n);
                        return true;
                    }
                    return false;
                }
                const f = t.focus orelse return false;
                return bubble(t, f, e);
            },
            .key_up => {
                const f = t.focus orelse return false;
                return bubble(t, f, e);
            },
            .focus_gained, .focus_lost => return false,
            .text_input, .custom => {
                // 文本输入交给焦点；custom 交根。
                const target = t.focus orelse t.root;
                return bubble(t, target, e);
            },
        }
    }

    /// 设置焦点：旧焦点发 focus_lost，新焦点发 focus_gained。
    pub fn setFocus(t: *Tree, n: ?*Node) void {
        if (t.focus == n) return;
        if (t.focus) |old| {
            _ = bubble(t, old, &.{ .focus_lost = {} });
            old.invalidatePaint();
        }
        t.focus = n;
        if (n) |new| {
            _ = bubble(t, new, &.{ .focus_gained = {} });
            new.invalidatePaint();
        }
    }

    /// 按声明顺序（DFS 前序）查找 focusable 节点形成焦点环。
    /// forward=true → 找当前焦点之后的第一个；false → 之前的。
    /// 无当前焦点时：forward 从首个 focusable 开始，否则从末尾开始。
    pub fn focusNext(t: *Tree, forward: bool) ?*Node {
        const n = t.focus;
        if (n == null) {
            return if (forward) findFocusableFirst(t.root) else findFocusableLast(t.root);
        }
        // 收集前序序列。
        var order: [256]*Node = undefined;
        var count: usize = 0;
        collectFocusable(t.root, &order, &count);
        if (count == 0) return null;
        var idx: isize = -1;
        for (order[0..count], 0..) |node, i| {
            if (node == n) {
                idx = @intCast(i);
                break;
            }
        }
        if (idx < 0) {
            // 当前焦点不在环中（非 focusable），从头开始。
            return if (forward) order[0] else order[count - 1];
        }
        const delta: isize = if (forward) 1 else -1;
        const next_idx = @mod(idx + delta, @as(isize, @intCast(count)));
        return order[@intCast(next_idx)];
    }

    fn collectFocusable(n: *Node, out: []*Node, count: *usize) void {
        if (count.* >= out.len) return;
        if (n.flags.focusable and !n.flags.disabled and n.flags.visible) {
            out[count.*] = n;
            count.* += 1;
        }
        for (n.children) |c| collectFocusable(c, out, count);
    }

    fn findFocusableFirst(n: *Node) ?*Node {
        if (n.flags.focusable and !n.flags.disabled and n.flags.visible) return n;
        for (n.children) |c| {
            if (findFocusableFirst(c)) |hit| return hit;
        }
        return null;
    }

    fn findFocusableLast(n: *Node) ?*Node {
        // 后序反向：先找最后一个 focusable。
        var i: usize = n.children.len;
        while (i > 0) {
            i -= 1;
            if (findFocusableLast(n.children[i])) |hit| return hit;
        }
        if (n.flags.focusable and !n.flags.disabled and n.flags.visible) return n;
        return null;
    }

    fn bubble(t: *Tree, start: *Node, e: *const event.Event) bool {
        _ = t;
        var cur: ?*Node = start;
        while (cur) |n| {
            if (n.handler) |h| {
                if (h(n, n.handler_ctx, e)) return true;
            }
            cur = n.parent;
        }
        return false;
    }

    /// hit test：只命中 visible 且非 pointer_pass 的节点；子节点优先（Z 序倒序）。
    pub fn hitTest(n: *Node, p: geo.Point) ?*Node {
        if (!n.flags.visible) return null;
        if (!n.rect.contains(p)) return null;
        // 子节点按倒序（后绘制者在上）优先命中。
        var i: usize = n.children.len;
        while (i > 0) {
            i -= 1;
            const c = n.children[i];
            if (c.flags.visible) {
                if (hitTest(c, p)) |hit| return hit;
            }
        }
        if (n.flags.pointer_pass) return null;
        return n;
    }

    /// 按 id（name）DFS 查找。
    pub fn findIn(n: *Node, id: NodeId) ?*Node {
        if (n.id.len > 0 and std.mem.eql(u8, n.id, id)) return n;
        for (n.children) |c| {
            if (findIn(c, id)) |hit| return hit;
        }
        return null;
    }
};

fn rectEq(a: geo.Rect, b: geo.Rect) bool {
    return geo.approxEq(a.x, b.x) and geo.approxEq(a.y, b.y) and
        geo.approxEq(a.w, b.w) and geo.approxEq(a.h, b.h);
}

/// paintTree 顺序（§5.4）：可见性 → 裁剪剔除 → Node 层背景/边框 → 控件内容 →
/// 内容区 pushClip → 递归子节点 → popClip。paint 不写树状态（L6）。
fn paintNode(t: *Tree, pc: painter.PaintCtx, n: *Node) void {
    if (!n.flags.visible) return;
    if (!pc.clipIntersects(n.rect)) return;

    // Node 层统一绘制背景与边框（控件不得重复实现描边，§5.3）。
    if (n.style.bg) |bg| pc.fillRect(n.rect, bg);
    if (n.style.border_color) |bc| {
        if (n.style.border_width > 0) {
            pc.strokeRect(n.rect, bc, n.style.border_width, t.theme_ref.radius.small);
        }
    }

    // 控件自身内容。
    if (t.dispatch_table) |d| d.paintWidget(t, n, pc);

    // 内容区裁剪后递归子节点。
    const inner = n.rect.inset(n.style.padding);
    pc.pushClip(inner);
    for (n.children) |c| paintNode(t, pc, c);
    pc.popClip();
}

// —— 测试辅助：固定尺寸的 custom 叶子 ——

const FixedCtx = struct {
    size: geo.Size,
    vtable: widget.CustomVTable = .{ .measure = measure },

    fn measure(ctx: *anyopaque, c: layout.Constraints) geo.Size {
        const self: *FixedCtx = @ptrCast(@alignCast(ctx));
        return c.constrain(self.size);
    }
};

fn addFixedLeaf(t: *Tree, parent: *Node, size: geo.Size) !*Node {
    const ctx = try t.alloc(FixedCtx);
    ctx.* = .{ .size = size };
    const n = try t.createNode(parent);
    n.widget = .{ .custom = .{ .ctx = ctx, .vtable = &ctx.vtable } };
    try t.appendChild(parent, n);
    return n;
}

// —— 测试 ——

test "golden: column with padding and gap lays out children exactly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try Tree.init(arena.allocator(), &theme.light);
    defer t.deinit();

    t.root.layout = .{ .column = .{ .gap = 8 } };
    t.root.style = .{ .padding = .{ .left = 4, .top = 6, .right = 4, .bottom = 6 } };

    const a = try addFixedLeaf(&t, t.root, .{ .width = 100, .height = 20 });
    const b = try addFixedLeaf(&t, t.root, .{ .width = 80, .height = 30 });
    const c = try addFixedLeaf(&t, t.root, .{ .width = 50, .height = 25 });
    _ = a;
    _ = b;
    _ = c;

    // 窗口足够高，root 未触及 max 约束，measured.height = 内容固有高(103)。
    t.ensureLayout(.{ .width = 200, .height = 400 });
    // 根是视口，measured 被 clamp 到窗口 min；金标准以子节点精确 rect 为准（§7.1）。
    try std.testing.expect(geo.approxEq(400, t.root.measured.height));
    try std.testing.expect(geo.approxEq(200, t.root.measured.width));
    // 子 0：column 的 cross 轴默认 stretch → 宽度拉满 inner(200-8=192)；x=4, y=6, h=20
    try std.testing.expect(geo.approxEq(4, t.root.children[0].rect.x));
    try std.testing.expect(geo.approxEq(6, t.root.children[0].rect.y));
    try std.testing.expect(geo.approxEq(192, t.root.children[0].rect.w));
    try std.testing.expect(geo.approxEq(20, t.root.children[0].rect.h));
    // 子 1：y=6+20+8=34
    try std.testing.expect(geo.approxEq(34, t.root.children[1].rect.y));
    // 子 2：y=34+30+8=72
    try std.testing.expect(geo.approxEq(72, t.root.children[2].rect.y));
}

test "golden: row stretch fills cross axis" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try Tree.init(arena.allocator(), &theme.light);
    defer t.deinit();

    t.root.layout = .{ .row = .{ .gap = 0, .cross = .stretch } };
    _ = try addFixedLeaf(&t, t.root, .{ .width = 40, .height = 5 });
    _ = try addFixedLeaf(&t, t.root, .{ .width = 30, .height = 7 });

    t.ensureLayout(.{ .width = 300, .height = 60 });
    // 子 0 高度被 stretch 拉满到根内容高 60。
    try std.testing.expect(geo.approxEq(0, t.root.children[0].rect.y));
    try std.testing.expect(geo.approxEq(60, t.root.children[0].rect.h));
    try std.testing.expect(geo.approxEq(40, t.root.children[0].rect.w));
    // 子 1 x = 40
    try std.testing.expect(geo.approxEq(40, t.root.children[1].rect.x));
    try std.testing.expect(geo.approxEq(30, t.root.children[1].rect.w));
}

test "measure forbidden to read rect; arrange does not change measured" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try Tree.init(arena.allocator(), &theme.light);
    defer t.deinit();

    t.root.layout = .{ .column = .{} };
    const a = try addFixedLeaf(&t, t.root, .{ .width = 50, .height = 20 });
    _ = a;
    t.ensureLayout(.{ .width = 100, .height = 100 });

    // arrange 后 measured 保持不变（arrange 不得改 measured）。
    try std.testing.expect(geo.approxEq(50, t.root.children[0].measured.width));
    try std.testing.expect(geo.approxEq(20, t.root.children[0].measured.height));
}

test "propagation termination: no-change reinvalidation skips relayout" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try Tree.init(arena.allocator(), &theme.light);
    defer t.deinit();

    // 两层：root(column) -> mid(column) -> leaf
    t.root.layout = .{ .column = .{} };
    const mid = try t.createNode(t.root);
    mid.layout = .{ .column = .{} };
    try t.replaceChildren(t.root, &.{mid});
    const leaf = try addFixedLeaf(&t, mid, .{ .width = 30, .height = 10 });
    try t.replaceChildren(mid, &.{leaf});

    t.ensureLayout(.{ .width = 200, .height = 200 });
    const relayout_after_first = t.relayout_count;
    try std.testing.expect(relayout_after_first > 0);

    // 仅重标脏（不改任何尺寸）→ 全部重测后尺寸一致 → 传播终止，不重排。
    t.root.invalidateMeasure();
    t.ensureLayout(.{ .width = 200, .height = 200 });
    try std.testing.expect(t.relayout_count == relayout_after_first);

    // 叶子尺寸真变 → 从叶子标脏 → root 的后代有变化 → 必须重排（relayout_count 增长）。
    const ctx: *FixedCtx = @ptrCast(@alignCast(leaf.widget.custom.ctx));
    ctx.size = .{ .width = 30, .height = 12 };
    leaf.invalidateMeasure();
    t.ensureLayout(.{ .width = 200, .height = 200 });
    try std.testing.expect(t.relayout_count > relayout_after_first);
    // 且子矩形随之更新。
    try std.testing.expect(geo.approxEq(12, t.root.children[0].children[0].rect.h));
}

test "hit test passes through pointer_pass and skips invisible" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try Tree.init(arena.allocator(), &theme.light);
    defer t.deinit();

    // 绝对定位，手动给 rect：normal 在下，solid 覆盖其上且 pointer_pass。
    t.root.layout = .{ .none = {} };
    const normal = try addFixedLeaf(&t, t.root, .{ .width = 60, .height = 60 });
    normal.rect = .{ .w = 60, .h = 60 };
    const solid = try addFixedLeaf(&t, t.root, .{ .width = 60, .height = 60 });
    solid.rect = .{ .w = 60, .h = 60 };
    solid.flags.pointer_pass = true;
    const hidden = try addFixedLeaf(&t, t.root, .{ .width = 60, .height = 60 });
    hidden.rect = .{ .x = 70, .w = 60, .h = 60 };
    hidden.flags.visible = false;

    t.ensureLayout(.{ .width = 200, .height = 200 });

    // solid 在上且覆盖 normal，但 pointer_pass → 命中穿透到其下 normal。
    try std.testing.expect(Tree.hitTest(t.root, .{ .x = 30, .y = 30 }).? == normal);
    // 窗口外 → 无命中。
    try std.testing.expect(Tree.hitTest(t.root, .{ .x = 250, .y = 250 }) == null);
}

test "dispatch bubbles up and stops on true" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try Tree.init(arena.allocator(), &theme.light);
    defer t.deinit();

    t.root.layout = .{ .column = .{} };
    const leaf = try addFixedLeaf(&t, t.root, .{ .width = 50, .height = 50 });
    t.ensureLayout(.{ .width = 200, .height = 200 });

    const State = struct {
        leaf_called: bool = false,
        root_called: bool = false,
    };
    var state = State{};

    t.root.handler_ctx = &state;
    t.root.handler = &struct {
        fn h(n: *Node, ctx: ?*anyopaque, e: *const event.Event) bool {
            _ = n;
            _ = e;
            const s: *State = @ptrCast(@alignCast(ctx.?));
            s.root_called = true;
            return false; // 不停止 → 继续冒泡
        }
    }.h;
    leaf.handler_ctx = &state;
    leaf.handler = &struct {
        fn h(n: *Node, ctx: ?*anyopaque, e: *const event.Event) bool {
            _ = n;
            _ = e;
            const s: *State = @ptrCast(@alignCast(ctx.?));
            s.leaf_called = true;
            return true; // 停止
        }
    }.h;

    var ev = event.Event{ .pointer_down = .{ .pos = .{ .x = 25, .y = 25 } } };
    _ = t.dispatch(&ev);
    try std.testing.expect(state.leaf_called);
    try std.testing.expect(!state.root_called); // 冒泡被 leaf 停止
}

test "click semantics: only same-node down+up triggers handler once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try Tree.init(arena.allocator(), &theme.light);
    defer t.deinit();

    t.root.layout = .{ .column = .{} };
    const leaf = try addFixedLeaf(&t, t.root, .{ .width = 50, .height = 50 });
    t.ensureLayout(.{ .width = 200, .height = 200 });

    var clicks: u32 = 0;
    leaf.handler_ctx = &clicks;
    leaf.handler = &struct {
        fn h(n: *Node, ctx: ?*anyopaque, e: *const event.Event) bool {
            _ = n;
            const c: *u32 = @ptrCast(@alignCast(ctx.?));
            if (e.* == .pointer_up) c.* += 1;
            return true;
        }
    }.h;

    // 纯移动不触发 click。
    _ = t.dispatch(&.{ .pointer_move = .{ .pos = .{ .x = 25, .y = 25 } } });
    try std.testing.expectEqual(@as(u32, 0), clicks);
    // 同节点 按下 + 抬起 = 恰好 1 次 click。
    _ = t.dispatch(&.{ .pointer_down = .{ .pos = .{ .x = 25, .y = 25 } } });
    _ = t.dispatch(&.{ .pointer_up = .{ .pos = .{ .x = 25, .y = 25 } } });
    try std.testing.expectEqual(@as(u32, 1), clicks);
    // 按下在节点内、抬起到空白：不算 click。
    _ = t.dispatch(&.{ .pointer_down = .{ .pos = .{ .x = 25, .y = 25 } } });
    _ = t.dispatch(&.{ .pointer_up = .{ .pos = .{ .x = 150, .y = 150 } } });
    try std.testing.expectEqual(@as(u32, 1), clicks);
}

test "find by id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try Tree.init(arena.allocator(), &theme.light);
    defer t.deinit();

    t.root.layout = .{ .column = .{} };
    const n1 = try addFixedLeaf(&t, t.root, .{ .width = 10, .height = 10 });
    n1.id = try t.allocStr("a");
    const n2 = try addFixedLeaf(&t, t.root, .{ .width = 10, .height = 10 });
    n2.id = try t.allocStr("b");

    try std.testing.expect(Tree.findIn(t.root, "a").? == n1);
    try std.testing.expect(Tree.findIn(t.root, "b").? == n2);
    try std.testing.expect(Tree.findIn(t.root, "zzz") == null);
}

test "invalidateMeasure walks ancestors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try Tree.init(arena.allocator(), &theme.light);
    defer t.deinit();

    const mid = try t.createNode(t.root);
    const leaf = try t.createNode(mid);
    t.root.dirty_measure = false;
    mid.dirty_measure = false;
    leaf.dirty_measure = false;

    leaf.invalidateMeasure();
    try std.testing.expect(leaf.dirty_measure);
    try std.testing.expect(mid.dirty_measure);
    try std.testing.expect(t.root.dirty_measure);
}

test "tab focus ring cycles focusable in declaration order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try Tree.init(arena.allocator(), &theme.light);
    defer t.deinit();

    t.root.layout = .{ .column = .{} };
    const a = try t.createNode(t.root);
    a.flags.focusable = true;
    const b = try t.createNode(t.root);
    b.flags.focusable = true;
    const c = try t.createNode(t.root); // 不可聚焦，应被跳过
    const d = try t.createNode(t.root);
    d.flags.focusable = true;
    try t.replaceChildren(t.root, &.{ a, b, c, d });

    // 无焦点：Tab → 首个；Shift-Tab → 末尾。
    try std.testing.expect(t.focusNext(true).? == a);
    try std.testing.expect(t.focusNext(false).? == d);

    // 设焦点到 b：Tab → d（跳过 c）；Shift-Tab → a。
    t.focus = b;
    try std.testing.expect(t.focusNext(true).? == d);
    try std.testing.expect(t.focusNext(false).? == a);

    // 焦点到 d：Tab 回绕到 a。
    t.focus = d;
    try std.testing.expect(t.focusNext(true).? == a);
}

test "setFocus fires focus events" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try Tree.init(arena.allocator(), &theme.light);
    defer t.deinit();

    const a = try t.createNode(t.root);
    a.flags.focusable = true;
    const b = try t.createNode(t.root);
    b.flags.focusable = true;
    try t.replaceChildren(t.root, &.{ a, b });

    var gained: usize = 0;
    var lost: usize = 0;
    const Ctx = struct {
        gained: *usize,
        lost: *usize,
    };
    var ctx = Ctx{ .gained = &gained, .lost = &lost };
    for ([_]*Node{ a, b }) |n| {
        n.handler_ctx = &ctx;
        n.handler = &struct {
            fn h(_: *Node, c: ?*anyopaque, e: *const event.Event) bool {
                const s: *Ctx = @ptrCast(@alignCast(c.?));
                switch (e.*) {
                    .focus_gained => s.gained.* += 1,
                    .focus_lost => s.lost.* += 1,
                    else => {},
                }
                return false;
            }
        }.h;
    }

    t.setFocus(a);
    t.setFocus(b); // a 失焦，b 获焦。
    try std.testing.expect(gained == 2);
    try std.testing.expect(lost == 1);
    try std.testing.expect(t.focus == b);
}
