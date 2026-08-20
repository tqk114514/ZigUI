//! examples/bench —— §4.9：500 Text 节点绘制性能。
//! 顶部显示平均 FPS（30 帧滚动）；拖拽 resize 观察是否保持 60fps。
//! CI 只编译不跑（防抖动，§7.2）；每里程碑人工跑一次记录进 CHANGELOG。

const std = @import("std");
const ui = @import("zigui");

const theme = ui.theme;

// 高精度时钟（示例内声明；Zig 0.16 std 无 std.time.Timer）。
extern "kernel32" fn QueryPerformanceCounter(out: *i64) callconv(.winapi) i32;
extern "kernel32" fn QueryPerformanceFrequency(out: *i64) callconv(.winapi) i32;

const NODE_COUNT: usize = 500;
const FPS_WINDOW: u32 = 30;

pub fn main() anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var tree = try ui.core.node.Tree.init(arena.allocator(), &theme.dark);
    defer tree.deinit();

    tree.root.layout = .{ .column = .{ .gap = theme.dark.spacing.xxs } };
    tree.root.style = .{ .padding = .all(theme.dark.spacing.xs) };

    const fps_label = try ui.widgets.builder.text(&tree, tree.root, "FPS: --", .{});

    // 500 个静态文本节点（超出窗口高度也全量绘制，压测 paint）。
    var i: usize = 0;
    while (i < NODE_COUNT) : (i += 1) {
        const s = try std.fmt.allocPrint(arena.allocator(), "text node {d} — 中文 mixed", .{i});
        _ = try ui.widgets.builder.text(&tree, tree.root, s, .{});
    }

    const BenchCtx = struct {
        tree: *ui.core.node.Tree,
        label: *ui.core.node.Node,
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
            // 30 帧平均 FPS。
            const avg = @divTrunc(self.acc, @as(i64, @intCast(FPS_WINDOW)));
            const fps = @as(f64, @floatFromInt(self.freq)) / @as(f64, @floatFromInt(avg));
            self.label.widget.text.text = std.fmt.allocPrint(self.tree.arena.allocator(), "FPS: {d:.1} ({d} text nodes)", .{ fps, NODE_COUNT }) catch return;
            self.label.invalidateMeasure();
            self.label.invalidatePaint();
            self.frames = 0;
            self.acc = 0;
        }
    };
    var bench = BenchCtx{ .tree = &tree, .label = fps_label };
    _ = QueryPerformanceFrequency(&bench.freq);
    _ = QueryPerformanceCounter(&bench.last);

    const title = std.unicode.utf8ToUtf16LeStringLiteral("zigui M4 — bench 500 text");
    _ = try ui.platform.window.run(.{
        .title = title,
        .theme_ref = &theme.dark,
        .frame_hook = &BenchCtx.frame,
        .frame_hook_ctx = &bench,
    }, &tree);
}
