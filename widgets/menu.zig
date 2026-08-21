//! widgets/menu.zig —— ContextMenu 控件行为 + 弹层模态控制器（规则 §5.8 / §6 P0-1）。
//!
//! 模块不变量：
//! - 纯行为，数据在 core/widget.zig 的 ContextMenu；视觉只取 theme token（L9）；
//! - 帧路径零分配（L4）：measure/paint 不分配（TextLayout 走 text_system 缓存）；
//! - show/dismiss 属事件路径：节点/items 拷贝入 tree arena（L5）；
//! - 模态契约（P0-1 弹层公共基建）：菜单显示期间，platform 在 tree.dispatch 之前
//!   调 Controller.filter——菜单消费全部指针/滚轮/键盘/文本事件（点击菜单内 = 交互，
//!   点击外部 = dismiss 且该次按下不作用于底层；Escape = dismiss），Tree.dispatch
//!   不会看到这些事件，因此无焦点/active 副作用；
//! - on_select 回调的 ctx 生命周期归调用方（§5.12 trampoline 一致）。
//!
//! 状态机（P0-1，驱动源 = 右键指针 / 模态过滤）：
//!   hidden → showing（右键命中带 Node.menu 声明的节点）→ hidden
//! - hidden → showing：platform 在右键 down 后沿命中祖先找 menu 声明 → show；
//! - showing → hidden：选择有效项（up 于 press 同项）/ 点击菜单外 / Escape / 失焦 / resize；
//! - showing 期间 hover 高亮由 filter 的 pointer_move 维护（L6：只事件路径写状态）。

const std = @import("std");
const geo = @import("../core/geometry.zig");
const layout = @import("../core/layout.zig");
const node = @import("../core/node.zig");
const painter = @import("../core/painter.zig");
const widget = @import("../core/widget.zig");
const event = @import("../core/event.zig");
const theme = @import("../theme.zig");
const tooltip = @import("tooltip.zig");

/// 菜单项槽高（DIP）：font_ui.size × 1.6 取整（13pt → 21）。paint/hit/measure 共用。
pub fn itemH(tree: *node.Tree) f32 {
    return @round(tree.theme_ref.font_ui.size * 1.6);
}

/// 求浮层固有尺寸：最宽项文本 + 双侧内边距；总高 = 各槽高之和 + 双侧内边距。
/// 分隔线槽 = ContextMenu.sep_h；项槽 = itemH。
pub fn measure(tree: *node.Tree, d: widget.ContextMenu, c: layout.Constraints) geo.Size {
    const th = tree.theme_ref;
    var w: f32 = 0;
    var h: f32 = 2 * widget.ContextMenu.pad_v;
    const ih = itemH(tree);
    if (tree.text_system) |ts| {
        for (d.items) |it| {
            if (it.separator) {
                h += widget.ContextMenu.sep_h;
                continue;
            }
            h += ih;
            if (ts.layout(it.label, &th.font_ui, c.max.width, .{})) |tl| {
                w = @max(w, tl.bounds.width);
            }
        }
    }
    return .{ .width = w + 2 * widget.ContextMenu.pad_h, .height = h };
}

/// 绘制浮层：圆角底 + 边框；逐项文本（hover = accent 高亮，disabled 弱化）；
/// 分隔线 = border 色横线（左右内缩 pad_h/2）。
pub fn paint(tree: *node.Tree, pc: painter.PaintCtx, rect: geo.Rect, d: widget.ContextMenu) void {
    const th = tree.theme_ref;
    pc.fillRoundedRect(rect, th.radius.small, th.bg_surface);
    pc.strokeRect(rect, th.border, 1, th.radius.small);
    if (tree.text_system == null) return;
    const ih = itemH(tree);
    var y = rect.y + widget.ContextMenu.pad_v;
    for (d.items, 0..) |it, i| {
        if (it.separator) {
            const cy = y + widget.ContextMenu.sep_h * 0.5;
            const inset = widget.ContextMenu.pad_h * 0.5;
            pc.strokeLine(rect.x + inset, cy, rect.x + rect.w - inset, cy, 1, th.border);
            y += widget.ContextMenu.sep_h;
            continue;
        }
        const row = geo.Rect{ .x = rect.x, .y = y, .w = rect.w, .h = ih };
        if (d.hover == i) {
            // hover 高亮（禁用项不高亮，视觉即"不可选"）。
            if (!it.disabled) pc.fillRect(row, th.accent);
        }
        const color: theme.Color = if (it.disabled)
            th.text_disabled
        else if (d.hover == i)
            th.accent_text
        else
            th.text;
        if (tree.text_system) |ts| {
            if (ts.layout(it.label, &th.font_ui, rect.w, .{})) |tl| {
                const tx = row.x + widget.ContextMenu.pad_h;
                const ty = row.y + (ih - tl.bounds.height) * 0.5;
                pc.drawText(.{ .x = tx, .y = ty, .w = tl.bounds.width, .h = tl.bounds.height }, tl, color);
            }
        }
        y += ih;
    }
}

/// 点 p（根空间 DIP）落在菜单第几项上；分隔线槽/内边距/出界返回 null。
pub fn hitItemIndex(tree: *node.Tree, n: *node.Node, p: geo.Point) ?usize {
    if (!n.rect.contains(p)) return null;
    const ih = itemH(tree);
    var y = n.rect.y + widget.ContextMenu.pad_v;
    for (n.widget.menu.items, 0..) |it, i| {
        const slot_h: f32 = if (it.separator) widget.ContextMenu.sep_h else ih;
        if (p.y >= y and p.y < y + slot_h) {
            return if (it.separator) null else i;
        }
        y += slot_h;
    }
    return null;
}

/// ContextMenu 生命周期控制器（P0-1 弹层公共基建：模态弹层首个消费者）。
/// UI 线程唯一（L7）；platform/window.zig 在 tree.dispatch 之前驱动 filter。
pub const Controller = struct {
    /// 目标树（浮层挂 tree.overlay 顶层槽）。
    tree: *node.Tree,
    /// 复用的浮层节点（首次 show 创建；arena 存活，flags.visible 控制显隐）。
    menu_node: ?*node.Node = null,
    /// 按下时所在项索引（click 语义：up 于同项才选择）。
    press: ?usize = null,
    /// 视口尺寸（DIP）：show 定位钳制用（platform sync 更新）。
    viewport: geo.Size = .{},

    /// 构造（UI 线程）。tree 须存活至窗口关闭。
    pub fn init(tree: *node.Tree) Controller {
        return .{ .tree = tree };
    }

    /// 是否显示中。
    pub fn visible(self: *const Controller) bool {
        const n = self.menu_node orelse return false;
        return n.flags.visible;
    }

    /// 从声明节点弹出菜单（事件路径，可分配：items/labels 拷贝入 arena，L5）。
    /// decl.menu 为声明（builder.contextMenu 设置）；pos = 右键位置（客户区 DIP）。
    pub fn show(self: *Controller, decl: *node.Node, pos: geo.Point) void {
        const d = decl.menu orelse return;
        const n = self.menu_node orelse blk: {
            const n = self.tree.createNode(self.tree.overlay) catch return;
            n.widget = .{ .menu = .{} };
            n.flags.pointer_pass = false; // 拦截命中（hitTestTop 先于 root；模态 filter 下仅语义占位）
            n.flags.visible = false;
            self.tree.appendChild(self.tree.overlay, n) catch return;
            self.menu_node = n;
            break :blk n;
        };
        // items 深拷贝入 arena（声明可来自调用方栈上切片，L5）。
        const items = self.tree.arena.allocator().alloc(widget.MenuItem, d.items.len) catch return;
        for (d.items, 0..) |it, i| {
            items[i] = .{
                .label = self.tree.allocStr(it.label) catch return,
                .separator = it.separator,
                .disabled = it.disabled,
            };
        }
        n.widget.menu.items = items;
        n.widget.menu.hover = null;
        n.widget.menu.on_select = d.on_select;
        n.widget.menu.on_select_ctx = d.on_select_ctx;
        self.press = null;
        // 模态打开：清除底层 hover/active——模态期间指针事件不进树，二者冻结在打开前
        // 的节点上（按钮残留悬停/按下视觉）。关闭时 platform 合成 move 重算 hover。
        if (self.tree.hover) |h| {
            self.tree.hover = null;
            h.invalidatePaint();
        }
        if (self.tree.active) |a| {
            self.tree.active = null;
            a.invalidatePaint();
        }
        // 尺寸经分发表测叶子（§5.4）；钳制到视口（超多项的菜单不越窗）。
        const raw: geo.Size = if (self.tree.dispatch_table) |dt|
            dt.measureWidget(self.tree, n, .{ .max = self.viewport })
        else
            .{};
        const size: geo.Size = .{
            .width = @min(raw.width, self.viewport.width),
            .height = @min(raw.height, self.viewport.height),
        };
        // 锚 = 光标点（零尺寸矩形）：下方优先，溢出翻转/钳制（复用 P0-1 定位 API）。
        n.hand_rect = tooltip.place(
            .{ .x = pos.x, .y = pos.y },
            size,
            self.viewport,
            0,
        );
        n.flags.visible = true;
        // rect 同步提升（§5.3 例外）：模态 filter 的命中判定（hitItemIndex 读 rect）在
        // 下一帧 ensureLayout 之前就要用——此处写入与 arrange 提升结果同值（幂等）。
        n.rect = n.hand_rect;
        n.invalidateLayout(); // hand_rect 变更 → 下轮 arrange 提升（§5.3 绝对定位）。
        self.tree.markDirtyRect(n.hand_rect);
    }

    /// 隐藏菜单（选择后 / 点击外部 / Escape / 失焦 / resize）。UI 线程唯一。
    pub fn dismiss(self: *Controller) void {
        self.press = null;
        const n = self.menu_node orelse return;
        if (!n.flags.visible) return;
        self.tree.markDirtyRect(n.rect);
        n.flags.visible = false;
        n.widget.menu.hover = null;
    }

    /// 模态输入过滤（P0-1 弹层公共基建）：菜单显示期间，platform 在 tree.dispatch
    /// 之前调用；返回 true = 事件被菜单消费（不得再进树）。
    /// - pointer_move：更新 hover 高亮；
    /// - pointer_down：菜单内记 press；菜单外 dismiss（该次按下不作用于底层）；
    /// - pointer_up：press 与命中同项且非禁用 → 回调 + dismiss；
    /// - key_down：Escape → dismiss；其余键盘/文本/滚轮一律消费（模态，防打字进底层 Edit）。
    pub fn filter(self: *Controller, e: *const event.Event) bool {
        const n = self.menu_node orelse return false;
        if (!n.flags.visible) return false;
        switch (e.*) {
            .pointer_move => |p| {
                // 维持 tree.pointer_pos"最近指针位置"不变量（模态期间 dispatch 不跑；
                // 关闭时 platform 合成 move 以它定位重算 hover）。
                self.tree.pointer_pos = p.pos;
                const idx = hitItemIndex(self.tree, n, p.pos);
                if (n.widget.menu.hover != idx) {
                    n.widget.menu.hover = idx;
                    n.invalidatePaint();
                }
                return true;
            },
            .pointer_down => |p| {
                self.press = hitItemIndex(self.tree, n, p.pos);
                if (self.press == null) self.dismiss(); // 点击外部关闭。
                return true; // 菜单内按下与外部关闭的按下都不作用于底层。
            },
            .pointer_up => |p| {
                const idx = hitItemIndex(self.tree, n, p.pos);
                const pressed = self.press;
                self.press = null;
                if (idx != null and pressed != null and idx.? == pressed.?) {
                    const it = n.widget.menu.items[idx.?];
                    if (!it.disabled) {
                        self.dismiss();
                        if (n.widget.menu.on_select) |f| {
                            f(n.widget.menu.on_select_ctx, idx.?);
                        }
                    }
                }
                return true;
            },
            .key_down => |k| {
                if (k.vk == event.VK.ESCAPE) self.dismiss();
                return true;
            },
            // 模态：滚轮/抬起外按键/文本输入/IME 一律消费（菜单打开时不作用于底层）。
            .wheel, .key_up, .text_input, .ime_compose => return true,
            .focus_gained, .focus_lost => return false, // 焦点事件非用户输入，放行。
            .custom => return true,
        }
    }
};

// —— 测试 ——

/// 假分发表：measure 固定 100×60（绕开 text_system 依赖）。
const Fake = struct {
    fn measureWidget(tree: *node.Tree, n: *node.Node, c: layout.Constraints) geo.Size {
        _ = tree;
        _ = n;
        return c.constrain(.{ .width = 100, .height = 60 });
    }
    fn paintWidget(tree: *node.Tree, n: *node.Node, pc: painter.PaintCtx) void {
        _ = tree;
        _ = n;
        _ = pc;
    }
    fn onEvent(tree: *node.Tree, n: *node.Node, e: *const event.Event) bool {
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

/// 假 TextSystem：label 长度 × 6 当宽，行高 16（measure/paint 几何可预期）。
const MockTs = struct {
    layout: painter.TextLayout = .{},
    fn layoutImpl(impl: *anyopaque, text: []const u8, _: *const theme.Font, _: f32, _: painter.TextLayoutOptions) ?*painter.TextLayout {
        const self: *MockTs = @ptrCast(@alignCast(impl));
        self.layout = .{ .bounds = .{
            .width = @as(f32, @floatFromInt(text.len)) * 6,
            .height = 16,
        } };
        return &self.layout;
    }
};

test "menu measure: slots and max width (mock text)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try node.Tree.init(arena.allocator(), &theme.light);
    defer t.deinit();
    var mock = MockTs{};
    t.text_system = .{ .vtable = &.{ .layout = &MockTs.layoutImpl }, .impl = &mock };

    const d = widget.ContextMenu{
        .items = &.{
            .{ .label = "cut" }, // 3×6=18
            .{ .label = "copy" }, // 4×6=24 ← 最宽
            .{ .separator = true },
            .{ .label = "x", .disabled = true }, // 6
        },
    };
    const s = measure(&t, d, .{ .max = .{ .width = 1000, .height = 1000 } });
    const ih = itemH(&t); // round(13×1.6)=21
    try std.testing.expect(geo.approxEq(24 + 2 * widget.ContextMenu.pad_h, s.width));
    try std.testing.expect(geo.approxEq(2 * widget.ContextMenu.pad_v + 3 * ih + widget.ContextMenu.sep_h, s.height));
}

test "menu paint: bg, hover highlight, separator (MockPainter)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try node.Tree.init(arena.allocator(), &theme.light);
    defer t.deinit();
    var mock = MockTs{};
    t.text_system = .{ .vtable = &.{ .layout = &MockTs.layoutImpl }, .impl = &mock };

    var mp = try painter.MockPainter.init(std.testing.allocator, &theme.light);
    defer mp.destroy();

    const ih = itemH(&t);
    const rect = geo.Rect{ .x = 0, .y = 0, .w = 80, .h = 2 * widget.ContextMenu.pad_v + 2 * ih + widget.ContextMenu.sep_h };
    const d = widget.ContextMenu{ .items = &.{
        .{ .label = "a" },
        .{ .separator = true },
        .{ .label = "b" },
    }, .hover = 0 };
    paint(&t, mp.ctx, rect, d);

    // 关键调用存在：圆角底、hover 行 accent 高亮、分隔线。
    var found_bg = false;
    var found_hover = false;
    var found_sep = false;
    for (mp.calls.items) |c| {
        switch (c) {
            .fillRoundedRect => |r| {
                if (geo.approxEq(r.rect.w, 80)) found_bg = true;
            },
            .fillRect => |r| {
                if (geo.approxEq(r.rect.h, ih) and colorEqHelper(r.color, theme.light.accent)) found_hover = true;
            },
            .strokeLine => found_sep = true,
            else => {},
        }
    }
    try std.testing.expect(found_bg);
    try std.testing.expect(found_hover);
    try std.testing.expect(found_sep);
}

fn colorEqHelper(a: theme.Color, b: theme.Color) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
}

test "controller: show places at cursor, filter selects/closes (mock table)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try node.Tree.init(arena.allocator(), &theme.light);
    defer t.deinit();
    t.dispatch_table = &fake_table;
    var mock = MockTs{};
    t.text_system = .{ .vtable = &.{ .layout = &MockTs.layoutImpl }, .impl = &mock };

    // 声明：两项 + 回调记录选择。
    var chosen: ?usize = null;
    const decl_node = try t.createNode(t.root);
    const decl = try t.alloc(widget.ContextMenu);
    decl.* = .{ .items = &.{
        .{ .label = "open" },
        .{ .label = "del" },
    }, .on_select = struct {
        fn f(ctx: ?*anyopaque, index: usize) void {
            const p: *?usize = @ptrCast(@alignCast(ctx.?));
            p.* = index;
        }
    }.f, .on_select_ctx = &chosen };
    decl_node.menu = decl;

    var ctrl = Controller.init(&t);
    ctrl.viewport = .{ .width = 400, .height = 300 };

    // 模态打开前模拟右键 down 的副作用：hover/active 落在触发节点上。
    t.hover = decl_node;
    t.active = decl_node;

    // 弹出：位于光标点（右键）；底层 hover/active 被清除（模态冻结防残留）。
    ctrl.show(decl_node, .{ .x = 100, .y = 50 });
    const mn = ctrl.menu_node.?;
    try std.testing.expect(mn.flags.visible);
    try std.testing.expect(mn.parent == t.overlay);
    try std.testing.expect(geo.approxEq(100, mn.hand_rect.x));
    try std.testing.expect(geo.approxEq(50, mn.hand_rect.y));
    try std.testing.expect(geo.approxEq(100, mn.hand_rect.w)); // 假表固定尺寸
    try std.testing.expect(t.hover == null);
    try std.testing.expect(t.active == null);
    // 声明未被修改（运行态是拷贝）。
    try std.testing.expect(decl_node.menu.?.items.len == 2);

    // 模态：move 到第 2 项（y = 50+pad_v+ih 内）→ hover=1。
    const ih = itemH(&t);
    const y2 = 50 + widget.ContextMenu.pad_v + ih + ih * 0.5;
    try std.testing.expect(ctrl.filter(&.{ .pointer_move = .{ .pos = .{ .x = 110, .y = y2 } } }));
    try std.testing.expect(mn.widget.menu.hover == 1);
    // 模态期间的 move 维持 tree.pointer_pos（关闭后合成 move 的定位来源，回归）。
    try std.testing.expect(geo.approxEq(110, t.pointer_pos.x));
    try std.testing.expect(geo.approxEq(y2, t.pointer_pos.y));
    // key_down 非 Escape：被消费。
    try std.testing.expect(ctrl.filter(&.{ .key_down = .{ .vk = event.VK.TAB } }));
    try std.testing.expect(ctrl.visible());
    // down 在第 2 项 → up 同项 → 回调 index=1 + dismiss。
    try std.testing.expect(ctrl.filter(&.{ .pointer_down = .{ .pos = .{ .x = 110, .y = y2 } } }));
    try std.testing.expect(ctrl.filter(&.{ .pointer_up = .{ .pos = .{ .x = 110, .y = y2 } } }));
    try std.testing.expect(chosen == 1);
    try std.testing.expect(!ctrl.visible());

    // 再弹 → 点击外部 dismiss 且事件被吃。
    ctrl.show(decl_node, .{ .x = 10, .y = 10 });
    try std.testing.expect(ctrl.visible());
    try std.testing.expect(ctrl.filter(&.{ .pointer_down = .{ .pos = .{ .x = 350, .y = 280 } } }));
    try std.testing.expect(!ctrl.visible());

    // 再弹 → Escape dismiss。
    ctrl.show(decl_node, .{ .x = 10, .y = 10 });
    try std.testing.expect(ctrl.filter(&.{ .key_down = .{ .vk = event.VK.ESCAPE } }));
    try std.testing.expect(!ctrl.visible());
    // 未显示时 filter 放行（事件正常进树）。
    try std.testing.expect(!ctrl.filter(&.{ .pointer_down = .{ .pos = .{ .x = 10, .y = 10 } } }));
}

test "controller: disabled item not selectable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try node.Tree.init(arena.allocator(), &theme.light);
    defer t.deinit();
    t.dispatch_table = &fake_table;

    var chosen: ?usize = null;
    const decl_node = try t.createNode(t.root);
    const decl = try t.alloc(widget.ContextMenu);
    decl.* = .{ .items = &.{
        .{ .label = "a", .disabled = true },
    }, .on_select = struct {
        fn f(ctx: ?*anyopaque, index: usize) void {
            const p: *?usize = @ptrCast(@alignCast(ctx.?));
            p.* = index;
        }
    }.f, .on_select_ctx = &chosen };
    decl_node.menu = decl;

    var ctrl = Controller.init(&t);
    ctrl.viewport = .{ .width = 400, .height = 300 };
    ctrl.show(decl_node, .{ .x = 0, .y = 0 });

    const ih = itemH(&t);
    const y = widget.ContextMenu.pad_v + ih * 0.5;
    _ = ctrl.filter(&.{ .pointer_down = .{ .pos = .{ .x = 10, .y = y } } });
    _ = ctrl.filter(&.{ .pointer_up = .{ .pos = .{ .x = 10, .y = y } } });
    // 禁用项：不回调；菜单保持显示（Windows 行为：点了没反应）。
    try std.testing.expect(chosen == null);
    try std.testing.expect(ctrl.visible());
}

test "controller: show clamps near right/bottom edge" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try node.Tree.init(arena.allocator(), &theme.light);
    defer t.deinit();
    t.dispatch_table = &fake_table;

    const decl_node = try t.createNode(t.root);
    const decl = try t.alloc(widget.ContextMenu);
    decl.* = .{ .items = &.{.{ .label = "x" }} };
    decl_node.menu = decl;

    var ctrl = Controller.init(&t);
    ctrl.viewport = .{ .width = 200, .height = 100 };
    // 光标在右下角：place 翻转上方 + 水平钳制。
    ctrl.show(decl_node, .{ .x = 199, .y = 99 });
    const mn = ctrl.menu_node.?;
    try std.testing.expect(mn.hand_rect.x + mn.hand_rect.w <= 200 + 0.001);
    try std.testing.expect(mn.hand_rect.y + mn.hand_rect.h <= 100 + 0.001);
}
