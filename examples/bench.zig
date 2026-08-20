//! examples/bench —— §4.9：Text 节点绘制性能。
//! 顶部显示平均 FPS（30 帧滚动）；拖拽 resize 观察是否保持 60fps。
//! 节点数默认 10000，可 `zig build run-bench -- <N>` 覆盖（§7.2 接受节点数参数；
//! 1M 级应力测试可传 1000000，注意首次建树与 measure 会较慢）。
//! CI 只编译不跑（防抖动，§7.2）；每里程碑人工跑一次记录进 CHANGELOG。

const std = @import("std");
const ui = @import("zigui");

pub const std_options: std.Options = .{ .networking = false };

const theme = ui.theme;

// 高精度时钟（示例内声明；Zig 0.16 std 无 std.time.Timer）。
extern "kernel32" fn QueryPerformanceCounter(out: *i64) callconv(.winapi) i32;
extern "kernel32" fn QueryPerformanceFrequency(out: *i64) callconv(.winapi) i32;

const DEFAULT_NODES: usize = 10000;
const FPS_WINDOW: u32 = 30;

pub fn main(init: std.process.Init) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var tree = try ui.core.node.Tree.init(arena.allocator(), &theme.dark);
    defer tree.deinit();

    // 节点数：默认 10000；首个参数可覆盖（§7.2）。
    var node_count: usize = DEFAULT_NODES;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 1) node_count = std.fmt.parseUnsigned(usize, args[1], 10) catch DEFAULT_NODES;

    tree.root.layout = .{ .column = .{ .gap = theme.dark.spacing.xxs } };
    tree.root.style = .{ .padding = .all(theme.dark.spacing.xs) };

    const fps_label = try ui.widgets.builder.text(&tree, tree.root, "FPS: --", .{});

    // 静态文本节点（超出窗口高度也全量绘制，压测 paint）。
    // 批量 replaceChildren 建树（§4.3：列表变更走重建而非增量 append——后者在
    // arena 语义下是 O(n²) 内存膨胀，1M 级直接 OOM）。
    var children: std.ArrayListUnmanaged(*ui.core.node.Node) = .empty;
    defer children.deinit(arena.allocator());
    // fps_label 需在树内才能被 frame_hook 更新，故先加入 children 列表打头。
    try children.append(arena.allocator(), fps_label);
    var i: usize = 0;
    while (i < node_count) : (i += 1) {
        const s = try std.fmt.allocPrint(arena.allocator(), "text node {d} — 中文 mixed", .{i});
        const n = try tree.createNode(tree.root);
        n.widget = .{ .text = .{ .text = s } };
        try children.append(arena.allocator(), n);
    }
    try tree.replaceChildren(tree.root, children.items);

    const BenchCtx = struct {
        tree: *ui.core.node.Tree,
        label: *ui.core.node.Node,
        nodes: usize,
        freq: i64 = 0,
        last: i64 = 0,
        acc: i64 = 0, // 累积帧耗时（ticks）
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
            // 30 帧平均 FPS 与帧耗时（§4.9 记录项）。
            const avg = @divTrunc(self.acc, @as(i64, @intCast(FPS_WINDOW)));
            const fps = @as(f64, @floatFromInt(self.freq)) / @as(f64, @floatFromInt(avg));
            const ms = @as(f64, @floatFromInt(avg)) * 1000.0 / @as(f64, @floatFromInt(self.freq));
            self.label.widget.text.text = std.fmt.allocPrint(self.tree.arena.allocator(), "FPS: {d:.1}  {d:.2}ms ({d} text nodes)", .{ fps, ms, self.nodes }) catch return;
            self.label.invalidateMeasure();
            self.label.invalidatePaint();
            self.frames = 0;
            self.acc = 0;
        }
    };
    var bench = BenchCtx{ .tree = &tree, .label = fps_label, .nodes = node_count };
    _ = QueryPerformanceFrequency(&bench.freq);
    _ = QueryPerformanceCounter(&bench.last);

    const title_utf8 = try std.fmt.allocPrint(arena.allocator(), "zigui M4 — bench {d} text", .{node_count});
    const title = try std.unicode.utf8ToUtf16LeAllocZ(arena.allocator(), title_utf8);
    _ = try ui.platform.window.run(.{
        .title = title,
        .theme_ref = &theme.dark,
        .frame_hook = &BenchCtx.frame,
        .frame_hook_ctx = &bench,
    }, &tree);
}
