//! platform/post.zig —— 跨线程任务桥（规则 §5.12）。
//!
//! 契约：
//! - `Ui.post` 是唯一可从任意线程调用的公共 API（L7 例外）；
//! - 保证：FIFO 顺序；任务在消息泵线程执行；post 前的写入对任务可见
//!   （内部互斥锁提供 happens-before）；任务内可再 post（下一轮 drain 执行）；
//!   窗口销毁后调用为未定义行为（调用方负责关闭顺序）；
//! - 机制：post 加锁入队 → PostMessage(WM_APP+1) 唤醒泵；drainTasks 分批取走执行；
//! - 任务队列用普通分配器（page_allocator），不进树 arena（§5.12）。

const std = @import("std");
const w32 = @import("win32.zig");
const wm = w32.windows_and_messaging;

const log = std.log.scoped(.post);

/// 任务：type + owner 指针 + 方法（comptime trampoline，§5.8）。
pub const Task = struct {
    owner: *anyopaque,
    run: *const fn (owner: *anyopaque) void,
};

/// 跨线程任务桥。由 window.run 创建并绑定 hwnd；post 可从任意线程调用。
pub const PostBridge = struct {
    allocator: std.mem.Allocator,
    hwnd: w32.HWND = undefined,
    /// Zig 0.16：std.atomic.Mutex（自旋锁，临界区极短适用；提供 acquire/release happens-before）。
    mutex: std.atomic.Mutex = .unlocked,
    queue: std.ArrayListUnmanaged(Task) = .empty,

    /// 构造空任务桥。
    pub fn init(allocator: std.mem.Allocator) PostBridge {
        return .{ .allocator = allocator };
    }

    /// 释放任务队列。
    pub fn deinit(self: *PostBridge) void {
        self.queue.deinit(self.allocator);
    }

    /// 自旋获取锁（临界区仅入队/出队，极短）。
    fn lock(self: *PostBridge) void {
        while (!self.mutex.tryLock()) {
            std.atomic.spinLoopHint();
        }
    }

    /// post 任务：任意线程可调。FIFO + happens-before（§5.12）。
    pub fn post(self: *PostBridge, owner: *anyopaque, run: *const fn (owner: *anyopaque) void) void {
        self.lock();
        defer self.mutex.unlock();
        self.queue.append(self.allocator, .{ .owner = owner, .run = run }) catch {
            log.err("post: task queue OOM", .{});
            return;
        };
        // 唤醒消息泵（跨线程 PostMessage 是安全的）。
        _ = w32.user32.PostMessageW(self.hwnd, wm.WM_APP + 1, 0, 0);
    }

    /// 消息泵线程调用（WM_APP+1）：取出全部任务执行。
    /// 任务内可再 post（本轮暂不取，下一轮 drain 执行，§5.12）。
    pub fn drainTasks(self: *PostBridge) void {
        // 批量取出（FIFO）。
        var batch: std.ArrayListUnmanaged(Task) = .empty;
        defer batch.deinit(self.allocator);

        self.lock();
        if (self.queue.items.len == 0) {
            self.mutex.unlock();
            return;
        }
        batch.appendSlice(self.allocator, self.queue.items) catch unreachable;
        self.queue.clearRetainingCapacity();
        self.mutex.unlock();

        for (batch.items) |task| task.run(task.owner);
    }
};

// —— 测试：FIFO 顺序 + 可见性 ——
test "post bridge delivers tasks in FIFO order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bridge = PostBridge.init(arena.allocator());
    defer bridge.deinit();

    var order = std.ArrayListUnmanaged(u8).empty;
    defer order.deinit(std.testing.allocator);

    const Ctx = struct {
        order: *std.ArrayListUnmanaged(u8),
        id: u8,
        fn run(self: *anyopaque) void {
            const c: *@This() = @ptrCast(@alignCast(self));
            c.order.append(std.testing.allocator, c.id) catch unreachable;
        }
    };
    var c1 = Ctx{ .order = &order, .id = 1 };
    var c2 = Ctx{ .order = &order, .id = 2 };
    var c3 = Ctx{ .order = &order, .id = 3 };

    bridge.post(&c1, &Ctx.run);
    bridge.post(&c2, &Ctx.run);
    bridge.post(&c3, &Ctx.run);

    // drain（模拟消息泵线程）。
    bridge.drainTasks();

    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, order.items);
}

test "post bridge no-op when queue empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bridge = PostBridge.init(arena.allocator());
    defer bridge.deinit();
    bridge.drainTasks(); // 不应崩溃/报错
}
