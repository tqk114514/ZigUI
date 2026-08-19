//! examples/threads —— M3：快照模式（规则 §5.12）。
//! worker 线程产出不可变结果 → post 回 UI 线程 → 更新文本。
//! 演示 Ui.post 的唯一正确用法：post 保证 FIFO + happens-before + 消息泵线程执行。

const std = @import("std");
const ui = @import("zigui");

const theme = ui.theme;

// —— 演示用工具：worker 模拟耗时睡眠 ——
// Zig 0.16 的 std 已移除 std.Thread.sleep / std.time.sleep（std.Io.sleep 需 Io
// 上下文，过重），故在本示例内直接声明 Win32 Sleep。
// 注意：这是示例内部演示代码，不构成库 API；库的线程工具在 platform/。
extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;
fn sleepMs(ms: u32) void {
    Sleep(ms);
}

pub fn main() anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var tree = try ui.core.node.Tree.init(arena.allocator(), &theme.dark);
    defer tree.deinit();

    tree.root.layout = .{ .column = .{ .gap = theme.dark.spacing.sm } };
    tree.root.style = .{ .padding = .all(theme.dark.spacing.md) };

    const label = try ui.widgets.builder.text(&tree, tree.root, "worker: idle");
    const btn = try ui.widgets.builder.button(&tree, tree.root, "Start worker");

    // 任务桥回填：worker 线程经它 post 回 UI 线程（run 内部赋值）。
    var bridge: *ui.Ui = undefined;
    const title = std.unicode.utf8ToUtf16LeStringLiteral("zigui M3 — threads");
    // UI 线程上下文（快照 applier 的 owner）。
    const ApplierCtx = struct {
        label: *ui.core.node.Node,
        tree: *ui.core.node.Tree,
        fn apply(self: *anyopaque) void {
            const s: *@This() = @ptrCast(@alignCast(self));
            // 快照已产出：在 UI 线程重建/更新（§5.12 批准模式）。
            s.label.widget.text.text = std.fmt.allocPrint(s.tree.arena.allocator(), "worker: done ({d} ms)", .{@as(u32, @intFromFloat(1200))}) catch "worker: done";
            s.label.invalidateMeasure();
            s.label.invalidatePaint();
        }
    };
    var applier = ApplierCtx{ .label = label, .tree = &tree };

    // 点击 → 启动 worker 线程（树外并行，不碰树）。
    const WorkerCtx = struct {
        bridge: *ui.Ui,
        applier: *ApplierCtx,
        fn run(self: *@This()) void {
            sleepMs(1200);
            // post 保证：applier 前的写入对 UI 线程可见（互斥锁 happens-before）。
            self.bridge.post(self.applier, &ApplierCtx.apply);
        }
    };
    var worker_ctx = WorkerCtx{ .bridge = undefined, .applier = &applier };

    const ClickCtx = struct {
        /// 指向 bridge 槽（run 内部回填）。
        bridge: **ui.Ui,
        worker: *WorkerCtx,
        fn onClick(_: *ui.core.node.Node, c: ?*anyopaque, e: *const ui.core.event.Event) bool {
            // 只在 click 完成（pointer_up 命中自身）时启动 worker；忽略 move/down（§5.8）。
            if (e.* != .pointer_up) return false;
            const s: *@This() = @ptrCast(@alignCast(c.?));
            s.worker.bridge = s.bridge.*;
            const t = std.Thread.spawn(.{}, WorkerCtx.run, .{s.worker}) catch return false;
            t.detach();
            return true;
        }
    };
    var click_ctx = ClickCtx{ .bridge = &bridge, .worker = &worker_ctx };
    btn.handler_ctx = &click_ctx;
    btn.handler = &ClickCtx.onClick;

    _ = try ui.platform.window.run(.{
        .title = title,
        .theme_ref = &theme.dark,
        .post_out = &bridge,
    }, &tree);
    // 注意：bridge 在此已失效（run 返回即销毁）；线程须在窗口关闭前完成 post。
}
