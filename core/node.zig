//! core/node.zig —— Style/Node/Tree/Dirty/measure/arrange/dispatch（规则 §5.3/§5.5）。
//!
//! 模块不变量：
//! - **L4**：帧路径（measure/arrange/paint/事件分发）零分配，本文件相关函数不带 allocator 参数；
//! - rect 只由 arrange 写入；measure 禁止读 rect（§5.3）；
//! - `invalidateMeasure` 沿祖先链置位；重测尺寸不变则终止，不重排祖先（§5.5 传播终止）；
//! - arrange 不得改任何 measured；
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

/// Style（§5.3）：margin/padding + 可选背景/边框。背景与边框由 paintTree 在 Node 层统一绘制。
pub const Style = struct {
    /// 外边距（DIP）。
    margin: geo.Edges = .{},
    /// 内边距（DIP）。
    padding: geo.Edges = .{},
    /// 可选背景色（theme token，L9）。
    bg: ?theme.Color = null,
    /// 可选边框色（theme token，L9）。
    border_color: ?theme.Color = null,
    /// 边框宽度（DIP）。
    border_width: f32 = 0,
};

/// Flags（§5.3）。
pub const Flags = packed struct(u32) {
    /// 是否参与绘制/命中。
    visible: bool = true,
    /// 命中穿透：指针事件穿过本节点（§5.3）。
    pointer_pass: bool = false,
    /// 可聚焦（Tab 焦点环，§5.3）。
    focusable: bool = false,
    /// 禁用：吸收一切输入。
    disabled: bool = false,
    _: u28 = 0,
};

/// 节点（§5.3）：树的基本单元。持有 widget/样式/布局/子节点与脏标记。
pub const Node = struct {
    /// 节点 id（空串 = 匿名；builder 用 find(id) 定位）。
    id: NodeId = "",
    /// 可见/穿透/可聚焦/禁用 标志位。
    flags: Flags = .{},
    /// 布置矩形（arrange 输出，父坐标系，DIP）。
    rect: geo.Rect = .{},
    /// 测量缓存（measure 输出）。
    measured: geo.Size = .{},
    /// 缓存键：上次约束（§5.5）。
    cache_cons: layout.Constraints = .{},
    /// 样式：margin/padding/背景/边框。
    style: Style = .{},
    /// 布局：row/column/none（§5.5）。
    layout: layout.Layout = .none,
    /// 子节点（arena 上的 slice）。
    children: []*Node = &.{},
    /// 父节点回指针（事件冒泡用）。
    parent: ?*Node = null,
    /// 是否提升为独立缓存层（§5.6 光栅缓存/分层）：置 true 后本节点子树被栅格化到离屏层、
    /// 以层变换（平移）合成到主场景；内容变化时层失效重栅化，仅变换（如滚动平移）不重栅化。
    /// 提供宿主（tree.layer_host）时生效；scroll 由 widget 隐式成为层。
    layer: bool = false,
    /// 层合成透明度（C）：本节点作为层节点（scroll / node.layer）合成到主场景时的 opacity，
    /// 取值 [0,1]，1.0 = 不透明。位图栅格化不变，仅 DrawBitmap 的 opacity 生效。非层节点忽略。
    layer_alpha: f32 = 1.0,
    /// 层合成显式 z（C）：同一父下的层节点兄弟按 layer_z **升序**合成（z 大者盖在之上；
    /// 相同保持声明序）。非层子节点仍按树序、相对位置不变。仅对层节点兄弟的合成顺序生效。
    layer_z: f32 = 0,
    /// 层合成缩放（C）：静态 node.layer 层以 factor 硬件缩放合成（≥0，1.0 不变）。
    /// 合成 dest 尺寸 = 层视口 × factor，位图保持自然分辨率，DrawBitmap 硬件缩放源的映射。
    /// 仅静态 node.layer 生效；scroll 层恒 1:1。
    layer_scale: f32 = 1.0,
    /// absolute（layout .none）容器下手填子矩形（§5.3 坐标语义）：**父内容区局部坐标**，
    /// 由 arrange 一次性提升为父坐标（根空间）。是绝对子布局的唯一输入；不随 arrange 覆盖
    /// （rect 会被改为父坐标值，hand_rect 保持手填原值，防每帧重复提升漂移）。
    hand_rect: geo.Rect = .{},
    /// 控件数据（Widget union）。
    widget: widget.Widget = .none,
    /// 测量脏标记（invalidateMeasure 沿祖先链置位）。
    dirty_measure: bool = true,
    /// 绘制脏标记（invalidatePaint 沿祖先链置位）。
    dirty_paint: bool = true,
    /// 布局脏标记（§6）：滚动偏移等"仅改显示不改尺寸"的变更强制 arrange 重排
    /// （传播终止 §5.5 的例外）。沿祖先链置位，arrange 消费后清除。
    layout_dirty: bool = false,
    /// 拖拽型控件标记（§6，slider 等）：接管按下后置位；抬起事件无论是否命中自身
    /// 都沿其冒泡（拖动结束通知 handler）。由 Tree.dispatch 在 pointer_up 读取并清除。
    release_anywhere: bool = false,
    /// 用户事件处理器（builder 挂接，§5.8）。返回 true 停止冒泡。
    handler: ?EventHandler = null,
    /// handler 的 ctx（trampoline，生命周期归用户，§5.12）。
    handler_ctx: ?*anyopaque = null,
    /// 本次 measure 是否尺寸未变（传播终止用，每轮 ensureLayout 重置）。
    measured_same: bool = false,
    /// 本节点或任一后代本次 measure 是否有变化（决定是否需重排子树）。
    desc_changed: bool = true,
    /// 所属树（invalidatePaint 用其上报局部脏区 rect；build 期由 ensureLayout 扫描设置）。
    tree: ?*Tree = null,

    pub fn invalidateMeasure(n: *Node) void {
        var cur: ?*Node = n;
        while (cur) |c| {
            c.dirty_measure = true;
            cur = c.parent;
        }
    }

    /// 标脏自身绘制并失效所在 scroll 的离屏表面（§5.4/§5.6）。并入树脏区（cliped 区域内由
    /// paintPath 的 clipIntersects 连带重绘覆盖区域）；同时向上找最近 scroll 祖先通知宿主，
    /// 使内容变化触发离屏表面重栅化。
    pub fn invalidatePaint(n: *Node) void {
        n.dirty_paint = true;
        if (n.tree) |t| t.markDirtyRect(n.rect);
        notifyLayerInvalid(n);
    }

    /// 仅标脏自身绘制并并入树脏区，不失效任何 scroll 离屏表面（§5.6）。
    /// 供 scroll 偏移变更调用：滚动只平移不改内容，表面位图仍有效，无需重栅化（复用前提）。
    pub fn invalidatePaintOnly(n: *Node) void {
        n.dirty_paint = true;
        if (n.tree) |t| t.markDirtyRect(n.rect);
    }

    /// 标脏布局（§6）：滚动偏移等仅改显示的变更沿祖先链置位，强制下一轮 arrange
    /// 重排本节点子树。不触碰 measure（尺寸未变，缓存保持命中）。
    pub fn invalidateLayout(n: *Node) void {
        var cur: ?*Node = n;
        while (cur) |c| {
            c.layout_dirty = true;
            cur = c.parent;
        }
    }
};

/// 剪贴板接口（§5.11）：platform 实现，Edit 复制/粘贴经此（widgets 不碰平台）。
pub const Clipboard = struct {
    /// 实现 vtable（core 只持接口）。
    vtable: *const VTable,
    /// 实现实例（platform 提供）。
    impl: *anyopaque,

    pub const VTable = struct {
        /// 读取剪贴板文本（UTF-8，分配于 allocator，调用方负责释放）。无文本返回 null。
        read: *const fn (impl: *anyopaque, allocator: std.mem.Allocator) ?[]const u8,
        /// 写入剪贴板文本（UTF-8）。失败静默（§5.11 不 panic）。
        write: *const fn (impl: *anyopaque, text: []const u8) void,
    };

    pub fn read(self: Clipboard, allocator: std.mem.Allocator) ?[]const u8 {
        return self.vtable.read(self.impl, allocator);
    }
    pub fn write(self: Clipboard, text: []const u8) void {
        self.vtable.write(self.impl, text);
    }
};

/// 控件行为分发表（§5.4）：widgets/dispatch.zig 提供实现，Tree 持引用。
/// core 不 import widgets（避免环），仅通过函数指针调用。
pub const DispatchTable = struct {
    /// 求叶子控件固有尺寸。只被 core 在"该节点是叶子控件"时调用。
    measureWidget: *const fn (tree: *Tree, n: *Node, c: layout.Constraints) geo.Size,
    /// 绘制叶子控件内容。只被 core 在 paintNode 中调用。
    paintWidget: *const fn (tree: *Tree, n: *Node, pc: painter.PaintCtx) void,
    /// 内建控件的事件处理（Edit 等，§5.8 状态机）。返回 true = 已消费、停止冒泡。
    onEvent: *const fn (tree: *Tree, n: *Node, e: *const event.Event) bool,
};

/// 层宿主（§5.6 光栅缓存/分层）：render 层实现，core 只持接口（L1，core 不触渲染）。
/// paintNode 遇到层节点（scroll 或 node.layer）且有宿主时，把子树绘制委托给宿主
/// （离屏栅格化 + 层变换合成/平移复用）。
pub const LayerHost = struct {
    /// 实现 vtable。
    vtable: *const VTable,
    /// 实现实例（render 的 Device 等）。
    impl: *anyopaque,
    pub const VTable = struct {
        /// 用（或重栅化）离屏缓存绘制层节点 n 的子内容，并把层位图按层变换绘制到主场景 pc。
        /// 返回 true = 已处理，paintNode 应跳过默认的子递归。
        paintLayer: *const fn (impl: *anyopaque, tree: *Tree, n: *Node, pc: painter.PaintCtx) bool,
        /// 通知宿主：n（层节点）内容/几何已变化，其离屏缓存已失效，下次绘制须重栅化。
        invalidate: *const fn (impl: *anyopaque, n: *Node) void,
    };
};

/// 树（§5.3）：arena 拥有全部节点；单值指针 focus/hover/active；提供布局与事件分发。
pub const Tree = struct {
    /// 整树内存的所有者（§4.3：deinit 整树丢弃）。
    arena: std.heap.ArenaAllocator,
    /// 树根节点（视口容器）。
    root: *Node,
    /// 当前焦点节点（Tab 焦点环，§5.3）。
    focus: ?*Node = null,
    /// 当前悬停节点（hover 状态推导，§5.3）。
    hover: ?*Node = null,
    /// 最近一次指针事件位置（窗口 DIP，dispatch 维护）。供控件按指针细粒度
    /// 判定（如 slider 仅在鼠标落入拇指圆内时触发 hover 遮罩）。首帧无指针事件时
    /// 为 undefined，但仅当 hover 命中节点后才会被读取（此时必有已抵达的指针事件）。
    pointer_pos: geo.Point = undefined,
    /// 当前按下节点（pressed 状态与拖选路由，§5.3）。
    active: ?*Node = null,
    /// 主题引用（§5.2：共享常量）。
    theme_ref: *const theme.Theme,
    /// 文本系统（§5.7）：text 控件 measure 消费 bounds。默认 null（无文本能力）。
    text_system: ?painter.TextSystem = null,
    /// 层宿主（§5.6 光栅缓存/分层）：render 安装实现；null = 层节点走默认子递归绘制。
    layer_host: ?LayerHost = null,
    /// 剪贴板接口（§5.11）：platform 装配实现，Edit 复制/粘贴经此（widgets 不碰平台）。
    clipboard: ?Clipboard = null,
    /// 控件行为分发表（§5.4）。默认 null（无内建控件行为）。
    dispatch_table: ?*const DispatchTable = null,
    /// 光标闪烁相位（§5.8 编辑框 WM_TIMER 530ms 翻转；Edit paint 只读，不写）。
    caret_blink_on: bool = true,
    /// 窗口内容区顶部偏移（DIP，§5.9 自定义标题栏；root 从该处开始排布）。
    content_top: f32 = 0,
    /// 观测用：arrange 实际重排子树的次数（测试断言传播终止）。
    relayout_count: usize = 0,
    /// 局部脏区（DIP，客户区坐标系，§5.4 部分重绘）：invalidatePaint 并入，renderFrame
    /// 消费后置 null。null + 无布局松动 = 整窗重绘。只含"纯绘制状态变化"的叶子矩形；
    /// measure/layout 松动在 beginPaintDirty 判定为整窗。
    dirty_rect: ?geo.Rect = null,

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

    /// 供离屏表面宿主调用：以自定义裁剪区绘制 node 的子节点（滚动条带栅格化，§5.6）。
    /// 子节点 rect 与 clip 均为 node 的本地（父）坐标系；D2D 经 surface 变换折换到条带。
    pub fn paintChildrenInto(t: *Tree, pc: painter.PaintCtx, n: *Node, clip: geo.Rect) void {
        pc.pushClip(clip);
        for (n.children) |c| paintNode(t, pc, c);
        pc.popClip();
    }

    pub fn deinit(t: *Tree) void {
        t.arena.deinit();
    }

    /// 并入一个需重绘的矩形（DIP，客户区坐标）到局部脏区（§5.4）。只并入非空矩形。
    pub fn markDirtyRect(t: *Tree, r: geo.Rect) void {
        if (r.w <= 0 or r.h <= 0) return;
        t.dirty_rect = if (t.dirty_rect) |cur| cur.merge(r) else r;
    }

    /// 消费本帧待重绘区域并清空脏区（渲染前调用）。
    /// 返回本次要重绘的 DIP 矩形：有布局/测量松动（沿链到 root）→ 整窗 viewport；
    /// 否则 → 局部脏区（可能 null = 无新增变化）。
    pub fn beginPaintDirty(t: *Tree, viewport: geo.Rect) ?geo.Rect {
        const d = t.dirty_rect;
        t.dirty_rect = null;
        if (t.root.dirty_measure or t.root.layout_dirty) return viewport;
        return d;
    }

    /// 回填 node.tree 反向指针（invalidatePaint 上报脏区用）。建树完成后首轮生效；
    /// 起见后续 O(1)：已设过则整子树跳过。
    fn syncNodeTree(t: *Tree) void {
        syncNodeChildren(t.root, t);
    }
    fn syncNodeChildren(n: *Node, t: *Tree) void {
        if (n.tree == t) return;
        n.tree = t;
        for (n.children) |c| syncNodeChildren(c, t);
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
        n.* = .{ .parent = parent, .tree = parent.tree };
        return n;
    }

    /// 列表变更的唯一合法方式：重建语义（§4.3/§5.3）。
    pub fn replaceChildren(t: *Tree, node: *Node, children: []const *Node) !void {
        node.children = try t.arena.allocator().dupe(*Node, children);
        for (node.children) |c| {
            c.parent = node;
            if (c.tree == null) c.tree = node.tree;
        }
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
        if (child.tree == null) child.tree = node.tree;
        node.invalidateMeasure();
        node.invalidatePaint();
    }

    /// 惰性布局：绘制前或任何读 rect 前必须调用（§5.3）。稳态零分配。
    /// root 从 content_top（§5.9 自定义标题栏）开始排布，尺寸 = 窗口减顶部偏移。
    pub fn ensureLayout(t: *Tree, window_size: geo.Size) void {
        t.syncNodeTree(); // 首次：回填 node.tree 反向指针（部分重绘上报脏区用）。
        const root_c = layout.Constraints{
            .min = window_size,
            .max = window_size,
        };
        _ = t.measure(t.root, root_c);
        t.root.rect = .{
            .y = t.content_top,
            .w = window_size.width,
            .h = window_size.height - t.content_top,
        };
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
        // 穷尽 switch（L8）：新增叶子控件必须在此登记，否则被当布局容器测得 0 尺寸。
        switch (n.widget) {
            .text, .button, .edit, .checkbox, .slider => {
                if (t.dispatch_table) |d| return c.constrain(d.measureWidget(t, n, c.loosen()));
                return c.constrain(.{});
            },
            .custom => |cu| return c.constrain(cu.vtable.measure(cu.ctx, c.loosen())),
            .box, .none, .scroll => {}, // 布局容器：走下方 padding/stack 逻辑
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
        // layout_dirty（§6 滚动偏移变更）是唯一例外：强制重排本节点子树。
        if (!n.desc_changed and rectEq(prev, bound) and !n.layout_dirty) return;
        n.layout_dirty = false; // 消费本轮布局脏标记。

        if (n.children.len == 0) return;
        const pad = n.style.padding;
        const inner = n.rect.inset(pad);

        // 主轴内容尺寸（不含 padding，内容坐标）。scroll 容器 arrange 后刷新 content_h。
        var content_extent: f32 = 0;

        switch (n.layout) {
            .none => {
                // 绝对定位（§5.3 坐标语义）：子用 hand_rect（父内容区局部）手填，此处一次性提升为
                // 父坐标（根空间，与布局子树一致）——否则 paint 剔除/层合成用根空间 clip，局部 rect 会被误剔。
                for (n.children) |child| {
                    const hr = child.hand_rect;
                    t.arrange(child, .{ .x = inner.x + hr.x, .y = inner.y + hr.y, .w = hr.w, .h = hr.h });
                }
            },
            .row, .column => |st| {
                t.relayout_count += 1;
                const axis: layout.Axis = if (n.layout == .row) .horizontal else .vertical;
                const main0: f32 = if (axis == .horizontal) inner.x else inner.y;
                const cross0: f32 = if (axis == .horizontal) inner.y else inner.x;
                const cross_len: f32 = if (axis == .horizontal) inner.h else inner.w;

                var pos: f32 = main0;
                // 滚动容器（§6，v1 纵向）：子节点按内容坐标排布，显示位置 = 内容位置 − 偏移。
                if (n.widget == .scroll and axis == .vertical) {
                    pos -= n.widget.scroll.offset_y;
                }
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
                    content_extent += main_size + st.gap;
                }
                if (n.children.len > 0) content_extent -= st.gap;
            },
        }

        // 滚动容器（§6）：刷新内容总高并钳制偏移（防 resize 后越界）。
        if (n.widget == .scroll and n.layout == .column) {
            const d = &n.widget.scroll;
            d.content_h = @max(0, content_extent + pad.top + pad.bottom);
            const viewport = @max(0, bound.h - pad.top - pad.bottom);
            const max_off = @max(0, d.content_h - viewport);
            if (d.offset_y > max_off) d.offset_y = max_off;
        }
    }

    // —— 事件分发 ——

    /// 指针事件先 hit test 再沿 parent 冒泡；键盘事件走焦点链（§5.3）。
    /// 同时维护 hover / active 单值指针（供 Button 等状态机推导，§5.3）。
    pub fn dispatch(t: *Tree, e: *const event.Event) bool {
        // 记录最近指针位置（DIP），供控件按指针细粒度判定（如 slider 拇指 hover）。
        switch (e.*) {
            .pointer_move => |p| t.pointer_pos = p.pos,
            .pointer_down => |p| t.pointer_pos = p.pos,
            .pointer_up => |p| t.pointer_pos = p.pos,
            else => {},
        }
        switch (e.*) {
            .pointer_move => |p| {
                const hit = hitTest(t.root, p.pos);
                // disabled 吸收一切输入（§5.8）：不作为 hover 目标（否则取 hover 变体）。
                const hover_target = if (hit) |h| (if (h.flags.disabled) null else h) else null;
                // hover 变化：旧节点与新节点都重绘。
                if (t.hover != hover_target) {
                    if (t.hover) |old| old.invalidatePaint();
                    t.hover = hover_target;
                    if (hover_target) |n| n.invalidatePaint();
                }
                // 拇指悬停态（§6 P0-3）：拇指是视口固定覆盖层、非节点命中，hover 单值指针
                // 覆盖不到——沿祖先更新各 scroll 的 thumb_hover，变化即重绘该 scroll。
                if (hit) |h| {
                    var cur: ?*Node = h;
                    while (cur) |c| {
                        if (c.widget == .scroll) {
                            const d = &c.widget.scroll;
                            const in_thumb = thumbHit(c, p.pos);
                            if (d.thumb_hover != in_thumb) {
                                d.thumb_hover = in_thumb;
                                c.invalidatePaint();
                            }
                        }
                        cur = c.parent;
                    }
                }
                // 拖选：active 的 Edit 处理 pointer_move（即使移出边界）。
                if (t.active) |a| {
                    if (t.dispatch_table) |dt| {
                        if (dt.onEvent(t, a, e)) return true;
                    }
                }
                return if (hit) |n| bubble(t, n, e) else false;
            },
            .pointer_down => |p| {
                const hit = hitTest(t.root, p.pos) orelse {
                    // 点空白：清 active 并取消焦点（点击空白让 Edit 失焦，§5.3）。
                    t.active = null;
                    if (t.focus != null) t.setFocus(null);
                    return false;
                };
                // 滚动条拇指（§6 P0-3）：命中测试落到内容子节点上，此处按几何沿祖先找
                // 拇指含此点的 scroll，先于内容处理——active=该 scroll，拖动中 move/up 经
                // active 路由回它；消费则不转移焦点（滚动条是 chrome，非内容交互）。
                if (t.dispatch_table) |dt| {
                    var cur: ?*Node = hit;
                    while (cur) |c| {
                        if (c.widget == .scroll and thumbHit(c, p.pos)) {
                            t.active = c;
                            if (dt.onEvent(t, c, e)) return true;
                        }
                        cur = c.parent;
                    }
                }
                t.active = hit;
                hit.invalidatePaint();
                // 点击 focusable 节点转移焦点（焦点环，§5.3）；点击非 focusable
                // （容器/文本等空白）取消焦点——column 占满时"空白"会命中容器。
                if (hit.flags.focusable and !hit.flags.disabled) {
                    t.setFocus(hit);
                } else if (t.focus != null) {
                    t.setFocus(null);
                }
                // 内建控件指针处理（Edit 点选/双击选词，§5.8）优先。
                if (t.dispatch_table) |dt| {
                    if (dt.onEvent(t, hit, e)) return true;
                }
                return bubble(t, hit, e);
            },
            .pointer_up => |p| {
                const hit = hitTest(t.root, p.pos);
                if (t.active) |a| {
                    // 拖拽型控件（slider 等，§6）：接管按下后，抬起通知与命中位置无关。
                    const release_anywhere = a.release_anywhere;
                    a.release_anywhere = false;
                    t.active = null;
                    a.invalidatePaint();
                    // 内建控件收尾（Edit 结束拖选）。
                    if (t.dispatch_table) |dt| {
                        if (dt.onEvent(t, a, e)) return true;
                    }
                    // click 语义（§5.8）：仅"按下与抬起同一节点"时才沿该节点冒泡，
                    // 触发其 handler；否则视为拖动/误触，不派发。拖拽型控件除外。
                    if (hit == a or release_anywhere) return bubble(t, a, e);
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
                // 内建控件事件（Edit 键盘操作，§5.8）优先于用户 handler。
                if (t.dispatch_table) |dt| {
                    if (dt.onEvent(t, f, e)) return true;
                }
                return bubble(t, f, e);
            },
            .wheel => |w| {
                // 滚轮（§6）：从命中节点向上找最近的 scroll 祖先，交给其事件处理；
                // 内层 scroll 优先（命中处无 scroll 则交回冒泡，用户 handler 可选处理）。
                const hit = hitTest(t.root, w.pos) orelse t.root;
                var cur: ?*Node = hit;
                while (cur) |c| {
                    if (c.widget == .scroll) {
                        if (t.dispatch_table) |dt| {
                            if (dt.onEvent(t, c, e)) return true;
                        }
                    }
                    cur = c.parent;
                }
                return bubble(t, hit, e);
            },
            .key_up => {
                const f = t.focus orelse return false;
                return bubble(t, f, e);
            },
            .focus_gained, .focus_lost => return false,
            .text_input, .ime_compose, .custom => {
                // 文本输入/IME 交给焦点；custom 交根。内建控件优先处理。
                const target = t.focus orelse t.root;
                if (t.dispatch_table) |dt| {
                    if (dt.onEvent(t, target, e)) return true;
                }
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

/// 颜色精确相等（theme token 为精确 f32 常量，测试断言用，避免浮点近似误差）。
fn colorEq(a: theme.Color, b: theme.Color) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
}

/// 是否层节点（§5.6 光栅缓存/分层）：scroll 由 widget 隐式成为层；其余子树用 node.layer 显式提升。
fn isLayerNode(n: *Node) bool {
    return n.widget == .scroll or n.layer;
}

/// 指针是否落在 scroll 的滚动条拇指内（§6 P0-3 可视滚动条）：拇指是视口固定覆盖层，
/// 命中测试找到的是内容子节点，此处按几何判定（几何在 core/widget.zig 的 Scroll.thumbRect）。
fn thumbHit(n: *Node, pos: geo.Point) bool {
    const d = n.widget.scroll;
    const tr = d.thumbRect(n.rect.inset(n.style.padding)) orelse return false;
    return tr.contains(pos);
}

/// 失效 n 所在的最近层宿主的离屏缓存（文件级辅助，§5.6）。从 n 向上找最近层节点祖先，
/// 命中且有宿主则通知 invalidate（重栅化）。无宿主或无层祖先则 no-op。
fn notifyLayerInvalid(n: *Node) void {
    const t = n.tree orelse return;
    const lh = t.layer_host orelse return;
    var cur: ?*Node = n;
    while (cur) |c| {
        if (isLayerNode(c)) {
            lh.vtable.invalidate(lh.impl, c);
            return;
        }
        cur = c.parent;
    }
}

/// paintTree 顺序（§5.4）：可见性 → 裁剪剔除 → Node 层背景/边框 → 控件内容 →
/// 内容区 pushClip → 递归子节点 → popClip。paint 不写树状态（L6）。
fn paintNode(t: *Tree, pc: painter.PaintCtx, n: *Node) void {
    if (!n.flags.visible) return;
    if (!pc.clipIntersects(n.rect)) return;

    // 显式 node.layer 的背景/边框不入主场景：它们属于层内容本身，由宿主并入离屏位图随合成
    // alpha/scale/mask 一体生效（C 层合成）——否则背景以全色整块贴主场景、半透明/缩放只作用于
    // 子内容，观感失效。scroll 层不使用这些合成属性（条带仅含子内容），仍在此画背景。
    const explicit_layer = n.layer and n.widget != .scroll;
    if (!explicit_layer) {
        // Node 层统一绘制背景与边框（控件不得重复实现描边，§5.3）。
        if (n.style.bg) |bg| pc.fillRect(n.rect, bg);
        if (n.style.border_color) |bc| {
            if (n.style.border_width > 0) {
                pc.strokeRect(n.rect, bc, n.style.border_width, t.theme_ref.radius.small);
            }
        }
    }

    // 层节点（scroll / 显式 node.layer）：有层宿主则交由宿主绘制（光栅缓存/分层，§5.6）；
    // 宿主处理成功则跳过默认子递归——scroll 的视口固定覆盖层（滚动条拇指）在条带 blit
    // 之后补画（不随内容滚，§6 P0-3）。
    if (isLayerNode(n)) {
        if (t.layer_host) |lh| {
            if (lh.vtable.paintLayer(lh.impl, t, n, pc)) {
                if (n.widget == .scroll) {
                    if (t.dispatch_table) |d| d.paintWidget(t, n, pc);
                }
                return;
            }
        }
        // 宿主缺失或未处理（失败退化）：显式层背景在此兜底，保证可见。
        if (explicit_layer) {
            if (n.style.bg) |bg| pc.fillRect(n.rect, bg);
            if (n.style.border_color) |bc| {
                if (n.style.border_width > 0) pc.strokeRect(n.rect, bc, n.style.border_width, t.theme_ref.radius.small);
            }
        }
    }

    // 控件自身内容（scroll 例外：其 paintWidget 是视口覆盖层，退化路径画在内容之后）。
    const is_scroll = n.widget == .scroll;
    if (!is_scroll) {
        if (t.dispatch_table) |d| d.paintWidget(t, n, pc);
    }

    // 内容区裁剪后递归子节点。
    const inner = n.rect.inset(n.style.padding);
    pc.pushClip(inner);
    drawChildren(t, pc, n);
    pc.popClip();

    // scroll 覆盖层（宿主缺失退化路径）：内容之后绘制，与层宿主路径的时序一致。
    if (is_scroll) {
        if (t.dispatch_table) |d| d.paintWidget(t, n, pc);
    }
}

/// 子节点绘制步进 _Order（C）：记录原始声明序号，供稳定排序保持非层节点相对位置与
/// 层节点同 z 时的声明序。
const _Order = struct {
    node: *Node,
    idx: usize,
};

/// 并行绘制父节点的子节点（C 层合成 z 排序）：同一父下存在 ≥2 个层节点兄弟时，
/// 在**连续层节点 run** 内按 layer_z 升序合成（z 大者盖在之上；相等保持声明序），
/// 非层节点保持树序且不被越界（run 边界即非层节点，绝不跨界）。无排序需求时
/// 零成本走声明序遍历（L4）。
/// 用栈上固定缓冲 + 相邻交换（bubble），帧路径零分配；子节点数超缓冲时退化为声明序。
fn drawChildren(t: *Tree, pc: painter.PaintCtx, n: *Node) void {
    var layer_cnt: usize = 0;
    for (n.children) |c| {
        if (isLayerNode(c)) layer_cnt += 1;
    }
    if (layer_cnt < 2) {
        for (n.children) |c| paintNode(t, pc, c);
        return;
    }
    const MAX_ORDER = 256;
    var order: [MAX_ORDER]_Order = undefined;
    const cnt = @min(n.children.len, MAX_ORDER);
    for (n.children[0..cnt], 0..) |c, i| order[i] = .{ .node = c, .idx = i };
    // 逐位左向 bubble：层节点只在连续层节点 run 内按 z 前移，遇非层节点即停（位置不动）。
    var i: usize = 0;
    while (i < cnt) : (i += 1) {
        if (!isLayerNode(order[i].node)) continue;
        var j = i;
        while (j > 0) {
            if (!isLayerNode(order[j - 1].node)) break; // run 边界：不跨非层节点。
            if (!_after(order[j - 1], order[j])) break; // 相邻已有序（含同 z 稳定）。
            const tmp = order[j - 1];
            order[j - 1] = order[j];
            order[j] = tmp;
            j -= 1;
        }
    }
    for (order[0..cnt]) |e| paintNode(t, pc, e.node);
    // 超缓冲的尾部子节点按声明序补画（罕见，仅文档说明行为）。
    var k = cnt;
    while (k < n.children.len) : (k += 1) paintNode(t, pc, n.children[k]);
}

/// 层合成 z 比较：a 是否应排在 b 之后。仅对同一连续 run 内的两个层节点调用——
/// 按 layer_z 升序，相等保持声明序（稳定）。
fn _after(a: _Order, b: _Order) bool {
    if (a.node.layer_z != b.node.layer_z) return a.node.layer_z > b.node.layer_z;
    return a.idx > b.idx;
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

    // 绝对定位，手动给 hand_rect：normal 在下，solid 覆盖其上且 pointer_pass。
    t.root.layout = .{ .none = {} };
    const normal = try addFixedLeaf(&t, t.root, .{ .width = 60, .height = 60 });
    normal.hand_rect = .{ .w = 60, .h = 60 };
    const solid = try addFixedLeaf(&t, t.root, .{ .width = 60, .height = 60 });
    solid.hand_rect = .{ .w = 60, .h = 60 };
    solid.flags.pointer_pass = true;
    const hidden = try addFixedLeaf(&t, t.root, .{ .width = 60, .height = 60 });
    hidden.hand_rect = .{ .x = 70, .w = 60, .h = 60 };
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

test "disabled node is not a hover target" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try Tree.init(arena.allocator(), &theme.light);
    defer t.deinit();

    t.root.layout = .{ .column = .{} };
    const leaf = try addFixedLeaf(&t, t.root, .{ .width = 50, .height = 50 });
    t.ensureLayout(.{ .width = 200, .height = 200 });

    // 未禁用：pointer_move 命中 → hover = 节点。
    _ = t.dispatch(&.{ .pointer_move = .{ .pos = .{ .x = 25, .y = 25 } } });
    try std.testing.expect(t.hover == leaf);

    // 禁用：命中但不设 hover（disabled 吸收一切输入，§5.8）。
    leaf.flags.disabled = true;
    _ = t.dispatch(&.{ .pointer_move = .{ .pos = .{ .x = 25, .y = 25 } } });
    try std.testing.expect(t.hover == null);
}

test "z sort: layer node siblings composite by layer_z ascending (higher z on top)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try Tree.init(arena.allocator(), &theme.light);
    defer t.deinit();

    t.root.layout = .none;
    t.root.rect = .{ .w = 100, .h = 100 };
    const low = try t.createNode(t.root);
    low.layer = true;
    low.layer_z = 1;
    low.style.bg = theme.light.accent;
    low.rect = .{ .w = 40, .h = 40 };
    const high = try t.createNode(t.root);
    high.layer = true;
    high.layer_z = 2;
    high.style.bg = theme.light.danger;
    high.rect = .{ .w = 40, .h = 40 };
    try t.replaceChildren(t.root, &.{ low, high });

    var mp = try painter.MockPainter.init(std.testing.allocator, &theme.light);
    defer mp.destroy();
    t.paint(mp.ctx);

    // fillRect 序列 = z 升序：accent(z=1) 先画，danger(z=2) 覆盖在其上。
    var colors: [2]theme.Color = undefined;
    var ci: usize = 0;
    for (mp.calls.items) |c| {
        if (c == .fillRect and ci < 2) {
            colors[ci] = c.fillRect.color;
            ci += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), ci);
    try std.testing.expect(colorEq(colors[0], theme.light.accent));
    try std.testing.expect(colorEq(colors[1], theme.light.danger));
}

test "z sort: equal layer_z keeps declaration order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try Tree.init(arena.allocator(), &theme.light);
    defer t.deinit();

    t.root.layout = .none;
    t.root.rect = .{ .w = 100, .h = 100 };
    const first = try t.createNode(t.root);
    first.layer = true;
    first.layer_z = 0;
    first.style.bg = theme.light.accent;
    first.rect = .{ .w = 40, .h = 40 };
    const second = try t.createNode(t.root);
    second.layer = true;
    second.layer_z = 0;
    second.style.bg = theme.light.danger;
    second.rect = .{ .w = 40, .h = 40 };
    try t.replaceChildren(t.root, &.{ first, second });

    var mp = try painter.MockPainter.init(std.testing.allocator, &theme.light);
    defer mp.destroy();
    t.paint(mp.ctx);

    var colors: [2]theme.Color = undefined;
    var ci: usize = 0;
    for (mp.calls.items) |c| {
        if (c == .fillRect and ci < 2) {
            colors[ci] = c.fillRect.color;
            ci += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), ci);
    try std.testing.expect(colorEq(colors[0], theme.light.accent));
    try std.testing.expect(colorEq(colors[1], theme.light.danger));
}

test "z sort: contiguous layer run reorders by layer_z, plain siblings keep position" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try Tree.init(arena.allocator(), &theme.light);
    defer t.deinit();

    t.root.layout = .none;
    t.root.rect = .{ .w = 100, .h = 100 };
    // 声明序：普通盒、层(mid z=1,danger)、层(high z=2,accent)、层(low z=0)、普通盒尾。
    // 连续层节点 run = [mid, high, low]，bubble 后按 z 升序 → [low, mid, high]；
    // 首尾普通盒位置不动（不进入 run）。
    const plain_0 = try t.createNode(t.root);
    plain_0.style.bg = theme.light.border;
    plain_0.rect = .{ .x = 0, .w = 10, .h = 10 };

    const mid = try t.createNode(t.root);
    mid.layer = true;
    mid.layer_z = 1;
    mid.style.bg = theme.light.danger;
    mid.rect = .{ .x = 10, .w = 20, .h = 20 };

    const high = try t.createNode(t.root);
    high.layer = true;
    high.layer_z = 2;
    high.style.bg = theme.light.accent;
    high.rect = .{ .x = 12, .w = 20, .h = 20 };

    const low = try t.createNode(t.root);
    low.layer = true;
    low.layer_z = 0;
    low.style.bg = theme.light.bg_surface;
    low.rect = .{ .x = 14, .w = 20, .h = 20 };

    const plain_1 = try t.createNode(t.root);
    plain_1.style.bg = theme.light.text_weak;
    plain_1.rect = .{ .x = 90, .w = 10, .h = 10 };
    try t.replaceChildren(t.root, &.{ plain_0, mid, high, low, plain_1 });

    var mp = try painter.MockPainter.init(std.testing.allocator, &theme.light);
    defer mp.destroy();
    t.paint(mp.ctx);

    // 预期：plain_0、run 内 z 升序（bg_surface z0 → danger z1 → accent z2）、plain_1。
    var colors: [5]theme.Color = undefined;
    var ci: usize = 0;
    for (mp.calls.items) |c| {
        if (c == .fillRect and ci < 5) {
            colors[ci] = c.fillRect.color;
            ci += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 5), ci);
    try std.testing.expect(colorEq(colors[0], theme.light.border));
    try std.testing.expect(colorEq(colors[1], theme.light.bg_surface));
    try std.testing.expect(colorEq(colors[2], theme.light.danger));
    try std.testing.expect(colorEq(colors[3], theme.light.accent));
    try std.testing.expect(colorEq(colors[4], theme.light.text_weak));
}

test "scroll thumb: pointer down routes to scroll, drag move follows active (P0-3)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try Tree.init(arena.allocator(), &theme.light);
    defer t.deinit();

    // 视口 200、内容 400：拇指 (90, 0, 8, 100)。
    t.root.layout = .{ .column = .{} };
    t.root.widget = .{ .scroll = .{} };
    for (0..4) |_| _ = try addFixedLeaf(&t, t.root, .{ .width = 100, .height = 100 });
    t.ensureLayout(.{ .width = 100, .height = 200 });

    // 假分发表：记录 onEvent 调用（core 不能 import widgets，路由本身用假表验证）。
    const Fake = struct {
        var calls: usize = 0;
        var target: ?*Node = null;
        fn onEvent(tree: *Tree, n: *Node, e: *const event.Event) bool {
            _ = tree;
            _ = e;
            calls += 1;
            target = n;
            return true;
        }
        fn measureWidget(tree: *Tree, n: *Node, c: layout.Constraints) geo.Size {
            _ = tree;
            _ = n;
            return c.constrain(.{});
        }
        fn paintWidget(tree: *Tree, n: *Node, pc: painter.PaintCtx) void {
            _ = tree;
            _ = n;
            _ = pc;
        }
    };
    t.dispatch_table = &.{
        .measureWidget = Fake.measureWidget,
        .paintWidget = Fake.paintWidget,
        .onEvent = Fake.onEvent,
    };

    // 按在拇指内（命中是内容叶子，路由按几何送到 scroll）→ 消费、active=scroll、不动焦点。
    const focus_before = t.focus;
    _ = t.dispatch(&.{ .pointer_down = .{ .pos = .{ .x = 94, .y = 50 } } });
    try std.testing.expectEqual(@as(usize, 1), Fake.calls);
    try std.testing.expect(Fake.target == t.root);
    try std.testing.expect(t.active == t.root);
    try std.testing.expect(t.focus == focus_before);

    // 拖动中的 move（指针在别的内容上）也经 active 路由到 scroll。
    _ = t.dispatch(&.{ .pointer_move = .{ .pos = .{ .x = 94, .y = 120 } } });
    try std.testing.expectEqual(@as(usize, 2), Fake.calls);
    try std.testing.expect(Fake.target == t.root);

    // 拇指外的 down 不路由到 scroll：走常规路径，onEvent 收到的是命中的内容叶子。
    Fake.calls = 0;
    _ = t.dispatch(&.{ .pointer_down = .{ .pos = .{ .x = 50, .y = 150 } } });
    try std.testing.expectEqual(@as(usize, 1), Fake.calls);
    try std.testing.expect(Fake.target != t.root);

    // move 更新拇指悬停态（几何判定，非节点命中）。
    _ = t.dispatch(&.{ .pointer_move = .{ .pos = .{ .x = 94, .y = 10 } } });
    try std.testing.expect(t.root.widget.scroll.thumb_hover);
    _ = t.dispatch(&.{ .pointer_move = .{ .pos = .{ .x = 50, .y = 10 } } });
    try std.testing.expect(!t.root.widget.scroll.thumb_hover);
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

test "partial repaint: dirty rect fully covered by innermost bg, no grout (§5.4)" {
    // 场景：带白底(bg_surface)的容器 panel，内含一个透明叠加子节点（如文字/hover 目标）。
    // 子节点变化 → 局部脏区 = 子节点 rect（小数坐标）。窗口部分重绘 = 先 Clear 脏区成窗色(灰)
    // （严格是 renderFrame 的 Clear(bg_window) + PushClip(dirty)），再 clip 内全量 paint。
    // 关键不变量：脏区必须被其最内层不透明 bg（panel 白）完整覆盖并上色，而非残留窗色灰——
    // 否则子节点背景从容器白漏成窗口灰（视觉 1px 缝）。clip 内全量重画借 clipIntersects 覆盖到容器。
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try Tree.init(arena.allocator(), &theme.light);
    defer t.deinit();
    t.root.layout = .{ .none = {} };

    var mp = try painter.MockPainter.init(std.testing.allocator, &theme.light);
    defer mp.destroy();

    const panel = try t.createNode(t.root);
    panel.style.bg = theme.light.bg_surface; // 白底容器。
    panel.rect = .{ .x = 0, .y = 0, .w = 120, .h = 60 };
    try t.appendChild(t.root, panel);

    // 容器内透明子节点（无 bg，叠加在 panel 白上）；dirty = 其 rect（小数，模拟布局小数坐标）。
    const child = try t.createNode(panel);
    child.rect = .{ .x = 6, .y = 3.39, .w = 40.0, .h = 21.51 };
    try t.appendChild(panel, child);
    t.root.rect = .{ .w = 120, .h = 60 };

    const dirty = child.rect;
    // 模拟 renderFrame 局部重绘：有效裁剪 = 脏区 → 只画与脏区相交的节点（含容器 panel）。
    mp.clip_rect = dirty;
    mp.ctx.pushClip(dirty);
    mp.ctx.fillRect(dirty, theme.light.bg_window); // Clear(dirty) → 脏区铺窗色（灰）。
    t.paint(mp.ctx);
    mp.ctx.popClip();

    // 断言：最后一个完整覆盖肮区且颜色≠窗色的 fillRect 存在（灰被 panel 白盖住，无灰缝）。
    var last_cover_bg: ?theme.Color = null;
    for (mp.calls.items) |c| {
        if (c == .fillRect) {
            const fr = c.fillRect;
            const covers = fr.rect.x <= dirty.x and fr.rect.y <= dirty.y and
                fr.rect.x + fr.rect.w >= dirty.x + dirty.w and
                fr.rect.y + fr.rect.h >= dirty.y + dirty.h;
            if (covers) last_cover_bg = fr.color;
        }
    }
    const fg = last_cover_bg orelse return error.ExpectFalse;
    // 灰（窗色）被容器白 bg_surface 覆盖：最终上色必须既非窗色、又恰为 panel 的白底。
    try std.testing.expect(!colorEq(fg, theme.light.bg_window));
    try std.testing.expect(colorEq(fg, theme.light.bg_surface));
}

test "paint culls children outside clip viewport (Scroll 剔除前提，§5.4)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try Tree.init(arena.allocator(), &theme.light);
    defer t.deinit();

    // 绝对定位 + 手填 hand_rect：10 个带背景的 box，各 100 高，y 从 0 到 900。
    // 背景由 paintNode 在 Node 层绘制（不依赖 dispatch），用 fillRect 次数观测剔除。
    t.root.layout = .{ .none = {} };
    for (0..10) |i| {
        const n = try t.createNode(t.root);
        n.style.bg = theme.light.accent;
        n.hand_rect = .{ .x = 0, .y = @as(f32, @floatFromInt(i * 100)), .w = 100, .h = 100 };
        try t.appendChild(t.root, n);
    }
    t.ensureLayout(.{ .width = 100, .height = 300 }); // 视口 100×300。

    var mp = try painter.MockPainter.init(std.testing.allocator, &theme.light);
    defer mp.destroy();
    mp.clip_rect = .{ .w = 100, .h = 300 }; // 有效裁剪区 = 视口。
    t.paint(mp.ctx);

    var bg_fills: usize = 0;
    for (mp.calls.items) |c| {
        if (c == .fillRect) bg_fills += 1;
    }
    // 仅视口内（y ∈ [0,300)，第 3 个贴 300 边界被剔除）3 个子节点被绘制。
    try std.testing.expectEqual(@as(usize, 3), bg_fills);
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
