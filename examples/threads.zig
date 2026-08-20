//! examples/threads —— 快照模式（规则 §5.12）。
//! worker 线程产出不可变结果 → post 回 UI 线程 → 更新文本。
//! 演示 Ui.post 的唯一正确用法：post 保证 FIFO + happens-before + 消息泵线程执行。
//! 正确关闭顺序：window.run 的 on_close 钩子里 SetEvent 唤醒 worker → join
//! （worker 立即放弃，不 post），之后任务桥才销毁——关闭无延迟且无 UAF。
//!
//! 注意：本示例的关闭安全依赖示例自己 join worker。
//! TODO(M7)：改为库内引用计数版——PostBridge.post 先 refs++ 借用 → 检查 closed → 入队 →
//! refs--，close 置 closed 后 spin 等 refs 归零再销毁，关闭安全由库保证、调用方无需 join。

const std = @import("std");
const ui = @import("zigui");

pub const std_options: std.Options = .{ .networking = false };

const theme = ui.theme;

// —— 演示用工具：事件等待（worker 模拟耗时且可被关闭唤醒）——
// Zig 0.16 的 std 已移除 std.Thread.sleep / std.time.sleep（std.Io.sleep 需 Io
// 上下文，过重），故在本示例内直接声明 Win32 事件 API。
// 注意：这是示例内部演示代码，不构成库 API。
const HANDLE = usize;
const WAIT_OBJECT_0: u32 = 0; // 事件被触发
const WAIT_TIMEOUT: u32 = 0x102; // 超时
extern "kernel32" fn CreateEventW(attrs: ?*anyopaque, manual: i32, initial: i32, name: ?[*:0]const u16) callconv(.winapi) HANDLE;
extern "kernel32" fn SetEvent(h: HANDLE) callconv(.winapi) i32;
extern "kernel32" fn WaitForSingleObject(h: HANDLE, ms: u32) callconv(.winapi) u32;
extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) i32;

pub fn main() anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var tree = try ui.core.node.Tree.init(arena.allocator(), &theme.dark);
    defer tree.deinit();

    tree.root.layout = .{ .column = .{ .gap = theme.dark.spacing.sm } };
    tree.root.style = .{ .padding = .all(theme.dark.spacing.md) };

    const label = try ui.widgets.builder.text(&tree, tree.root, "worker: idle", .{});
    const btn = try ui.widgets.builder.button(&tree, tree.root, "Start worker");

    // 任务桥回填：worker 线程经它 post 回 UI 线程（run 内部赋值）。
    var bridge: *ui.Ui = undefined;
    const title = std.unicode.utf8ToUtf16LeStringLiteral("zigui M3 — threads");

    // 手动重置事件：关闭窗口时 SetEvent 唤醒所有等待的 worker（§5.12 协作式取消）。
    const exit_event = CreateEventW(null, 1, 0, null);
    if (exit_event == 0) return error.CreateEventFailed;

    // UI 线程上下文（快照 applier 的 owner；同时持有 worker 句柄供 on_close join）。
    const ApplierCtx = struct {
        label: *ui.core.node.Node,
        tree: *ui.core.node.Tree,
        exit_event: HANDLE,
        /// 当前 worker 线程（不 detach；on_close 里 join，保证先退桥后销毁）。
        worker: ?std.Thread = null,
        fn apply(self: *anyopaque) void {
            const s: *@This() = @ptrCast(@alignCast(self));
            // 快照已产出：在 UI 线程重建/更新（§5.12 批准模式）。
            s.label.widget.text.text = std.fmt.allocPrint(s.tree.arena.allocator(), "worker: done ({d} ms)", .{@as(u32, @intFromFloat(1200))}) catch "worker: done";
            s.label.invalidateMeasure();
            s.label.invalidatePaint();
        }
    };
    var applier = ApplierCtx{ .label = label, .tree = &tree, .exit_event = exit_event };

    // 点击 → 启动 worker 线程（树外并行，不碰树）。
    const WorkerCtx = struct {
        bridge: *ui.Ui,
        applier: *ApplierCtx,
        fn run(self: *@This()) void {
            // 等 1200ms 模拟耗时；窗口关闭会 SetEvent 唤醒 → 立即放弃，不 post。
            const r = WaitForSingleObject(self.applier.exit_event, 1200);
            if (r == WAIT_OBJECT_0) return;
            // post 保证：applier 前的写入对 UI 线程可见（互斥锁 happens-before）。
            self.bridge.post(self.applier, &ApplierCtx.apply);
        }
    };
    var worker_ctx = WorkerCtx{ .bridge = undefined, .applier = &applier };

    const ClickCtx = struct {
        /// 指向 bridge 槽（run 内部回填）。
        bridge: **ui.Ui,
        worker: *WorkerCtx,
        applier: *ApplierCtx,
        fn onClick(_: *ui.core.node.Node, c: ?*anyopaque, e: *const ui.core.event.Event) bool {
            // 只在 click 完成（pointer_up 命中自身）时启动 worker；忽略 move/down（§5.8）。
            if (e.* != .pointer_up) return false;
            const s: *@This() = @ptrCast(@alignCast(c.?));
            if (s.applier.worker != null) return false; // 已有 worker 在跑，忽略（示例简化）
            s.worker.bridge = s.bridge.*;
            s.applier.worker = std.Thread.spawn(.{}, WorkerCtx.run, .{s.worker}) catch null;
            return true;
        }
    };
    var click_ctx = ClickCtx{ .bridge = &bridge, .worker = &worker_ctx, .applier = &applier };
    btn.handler_ctx = &click_ctx;
    btn.handler = &ClickCtx.onClick;

    // 正确关闭顺序（§5.12）：run 返回前回调，桥尚未销毁。
    const CloseCtx = struct {
        applier: *ApplierCtx,
        fn run(c: ?*anyopaque) void {
            const s: *@This() = @ptrCast(@alignCast(c.?));
            // 1) 通知 worker 放弃；2) join（被唤醒后立即退出，关闭无延迟）。
            _ = SetEvent(s.applier.exit_event);
            if (s.applier.worker) |t| t.join();
            _ = CloseHandle(s.applier.exit_event);
        }
    };
    var close_ctx = CloseCtx{ .applier = &applier };

    _ = try ui.platform.window.run(.{
        .title = title,
        .theme_ref = &theme.dark,
        .post_out = &bridge,
        .on_close = &CloseCtx.run,
        .on_close_ctx = &close_ctx,
    }, &tree);
    // 至此 worker 已 join 且 exit_event 已关闭；bridge 已失效，不再触碰。
}
