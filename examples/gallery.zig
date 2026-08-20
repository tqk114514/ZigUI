//! examples/gallery —— M6 控件画廊：Scroll / Checkbox / Slider / Edit(undo)。
//! 演示：滚轮滚动 10000 行内容（clipIntersects 剔除，§5.4）、checkbox/slider 反应式
//! 更新标签、Edit 的 Ctrl+Z/Y 撤销重做、顶部 FPS（30 帧平均，§4.9）。

const std = @import("std");
const ui = @import("zigui");

const theme = ui.theme;
const b = ui.widgets.builder;

// 高精度时钟（示例内声明；Zig 0.16 std 无 std.time.Timer，与 bench.zig 一致）。
extern "kernel32" fn QueryPerformanceCounter(out: *i64) callconv(.winapi) i32;
extern "kernel32" fn QueryPerformanceFrequency(out: *i64) callconv(.winapi) i32;

const FPS_WINDOW: u32 = 30;

/// 画布状态：控件引用 + 反应式标签。
const Ctx = struct {
    tree: *ui.core.node.Tree,
    boxes: []const *ui.core.node.Node, // 三个复选框。
    count_label: *ui.core.node.Node,
    slider: *ui.core.node.Node,
    slider_label: *ui.core.node.Node,

    /// 复选框点击（pointer_up，§6）：重算勾选数并更新标签。
    fn onCheck(_: *ui.core.node.Node, c: ?*anyopaque, e: *const ui.core.event.Event) bool {
        if (e.* != .pointer_up) return false;
        const s: *@This() = @ptrCast(@alignCast(c.?));
        var n: usize = 0;
        for (s.boxes) |box| {
            if (box.widget.checkbox.checked) n += 1;
        }
        const txt = std.fmt.allocPrint(s.tree.arena.allocator(), "已勾选：{d}", .{n}) catch "";
        setText(s.tree, s.count_label, txt);
        return true;
    }

    /// 滑块释放（pointer_up，§6）：更新值标签。
    fn onSlider(_: *ui.core.node.Node, c: ?*anyopaque, e: *const ui.core.event.Event) bool {
        if (e.* != .pointer_up) return false;
        const s: *@This() = @ptrCast(@alignCast(c.?));
        const v = s.slider.widget.slider.value;
        const txt = std.fmt.allocPrint(s.tree.arena.allocator(), "滑块值：{d:.1}", .{v}) catch "";
        setText(s.tree, s.slider_label, txt);
        return true;
    }
};

/// 30 帧平均 FPS 显示（frame_hook 每帧调用，§4.9）。
const Fps = struct {
    tree: *ui.core.node.Tree,
    label: *ui.core.node.Node,
    freq: i64 = 0,
    last: i64 = 0,
    acc: i64 = 0,
    frames: u32 = 0,
    fn frame(c: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(c.?));
        var now: i64 = undefined;
        _ = QueryPerformanceCounter(&now);
        const dt = now - self.last;
        self.last = now;
        if (dt <= 0 or self.freq == 0) return;
        self.acc += dt;
        self.frames += 1;
        if (self.frames < FPS_WINDOW) return;
        const avg = @divTrunc(self.acc, @as(i64, @intCast(FPS_WINDOW)));
        const fps = @as(f64, @floatFromInt(self.freq)) / @as(f64, @floatFromInt(avg));
        self.label.widget.text.text = std.fmt.allocPrint(self.tree.arena.allocator(), "FPS: {d:.1} — 滚轮滚动长内容", .{fps}) catch return;
        self.label.invalidateMeasure();
        self.label.invalidatePaint();
        self.frames = 0;
        self.acc = 0;
    }
};

/// 更新文本节点内容（arena 分配 + 标脏）。
fn setText(tree: *ui.core.node.Tree, n: *ui.core.node.Node, s: []const u8) void {
    n.widget.text.text = tree.allocStr(s) catch return;
    n.invalidateMeasure();
    n.invalidatePaint();
}

pub fn main() anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var tree = try ui.core.node.Tree.init(arena.allocator(), &theme.dark);
    defer tree.deinit();

    // 整窗滚动：根 = scroll 容器（column 内容，§6）。控件随内容滚动（设置页式布局）。
    tree.root.widget = .{ .scroll = .{} };
    tree.root.layout = .{ .column = .{ .gap = theme.dark.spacing.xs } };
    tree.root.style = .{ .padding = .all(theme.dark.spacing.md) };

    const fps_label = try b.text(&tree, tree.root, "FPS: --", .{});
    _ = try b.text(&tree, tree.root, "zigui M6 gallery — scroll / checkbox / slider / edit(undo)", .{});
    _ = try b.text(&tree, tree.root, "滚轮滚动；Tab 切焦点；Space 切换复选框；Ctrl+Z/Y 撤销重做。", .{});

    // 复选框组 + 计数标签（handler 在 pointer_up 后反应式更新）。
    const c1 = try b.checkbox(&tree, tree.root, "选项 A");
    const c2 = try b.checkbox(&tree, tree.root, "选项 B");
    const c3 = try b.checkbox(&tree, tree.root, "选项 C");
    const count_label = try b.text(&tree, tree.root, "已勾选：0", .{});

    // 滑块 + 值标签。
    const slider = try b.slider(&tree, tree.root, 40, 0, 100);
    const slider_label = try b.text(&tree, tree.root, "滑块值：40.0", .{});

    // Edit（undo/redo：Ctrl+Z / Ctrl+Y）。
    _ = try b.edit(&tree, tree.root, "可撤销输入：");

    var ctx = Ctx{
        .tree = &tree,
        .boxes = &.{ c1, c2, c3 },
        .count_label = count_label,
        .slider = slider,
        .slider_label = slider_label,
    };
    for ([_]*ui.core.node.Node{ c1, c2, c3 }) |box| {
        box.handler_ctx = &ctx;
        box.handler = &Ctx.onCheck;
    }
    slider.handler_ctx = &ctx;
    slider.handler = &Ctx.onSlider;

    // 长内容：10000 行，验证滚动时 clipIntersects 剔除（§6 DoD）。
    var i: usize = 0;
    while (i < 10000) : (i += 1) {
        const line = std.fmt.allocPrint(tree.arena.allocator(), "第 {d} 行：zigui 滚动演示内容。", .{i}) catch "";
        _ = try b.text(&tree, tree.root, line, .{});
    }

    var fps = Fps{ .tree = &tree, .label = fps_label };
    _ = QueryPerformanceFrequency(&fps.freq);
    _ = QueryPerformanceCounter(&fps.last);

    const title = std.unicode.utf8ToUtf16LeStringLiteral("zigui M6 — gallery");
    _ = try ui.platform.window.run(
        .{
            .title = title,
            .width = 900,
            .height = 620,
            .theme_ref = &theme.dark,
            .frame_hook = &Fps.frame,
            .frame_hook_ctx = &fps,
        },
        &tree,
    );
}
