//! core/ticker.zig —— 单调时钟驱动的调度 / 动画推进（后续面：时钟/动画/时机子系统）。
//!
//! 模块不变量：
//! - **L4**：帧路径零分配——定时器/动画槽是固定数组池，`advance` 只读写池、不带 allocator；
//! - 时间单位一律**秒（f64）**，由调用方提供单调时钟（平台 QPC）；`advance(now)` 幂等推进；
//! - 惰性唤醒：`hasActive()` 为假时平台可完全收手（空闲 CPU 0%，§4.9）；
//! - `advance` 只推进状态并调用回调，不改树结构（L6 语义在回调侧保证）；
//! - 回调的 ctx 生命周期归调用方（与 §5.12 trampoline 一致），`clear*` 取消后不得再回调。
//!
//! 定位：先解决"定时回调 + 基础动画推进"的统一时钟；平滑滚动/opacity 动画等逐帧动画
//! 后续经动画槽接入（TODO(动画)：与 vsync 对齐的每帧推进另行细化，当前按平台惰性 tick 推进）。

const std = @import("std");

pub const MAX_TIMERS: usize = 16;
pub const MAX_ANIMS: usize = 16;

/// 缓动曲线（线性 / 出缓 / 出入缓）。随时间推进把进度 p∈[0,1] 映射为 e∈[0,1] 喂给回调。
pub const Ease = enum {
    linear,
    ease_out,
    ease_in_out,
    pub fn apply(self: Ease, p: f32) f32 {
        return switch (self) {
            .linear => p,
            .ease_out => 1.0 - std.math.pow(f32, 1.0 - p, 3),
            .ease_in_out => if (p < 0.5) 4 * p * p * p else 1.0 - std.math.pow(f32, -2 * p + 2, 3) / 2,
        };
    }
};

pub const TimerSlot = struct {
    active: bool = false,
    /// 周期（秒）。0 = 一次性，触发即停；>0 = 周期重复。
    period: f64 = 0,
    /// 下次触发绝对时刻（秒，单调钟）。
    next: f64 = 0,
    ctx: ?*anyopaque = null,
    cb: *const fn (ctx: ?*anyopaque) void = cbNoop,
};

pub const AnimSlot = struct {
    active: bool = false,
    start: f64 = 0,
    duration: f64 = 0,
    ease: Ease = .linear,
    ctx: ?*anyopaque = null,
    /// 每帧回调：eased ∈ [0,1]。返回是否继续（false → 结束）。
    cb: *const fn (ctx: ?*anyopaque, eased: f32) bool = animNoop,
};

fn cbNoop(ctx: ?*anyopaque) void {
    _ = ctx;
}
fn animNoop(ctx: ?*anyopaque, eased: f32) bool {
    _ = ctx;
    _ = eased;
    return false;
}

fn initTimers() [MAX_TIMERS]TimerSlot {
    var a: [MAX_TIMERS]TimerSlot = undefined;
    for (&a) |*s| s.* = .{};
    return a;
}
fn initAnims() [MAX_ANIMS]AnimSlot {
    var a: [MAX_ANIMS]AnimSlot = undefined;
    for (&a) |*s| s.* = .{};
    return a;
}

pub const Ticker = struct {
    timers: [MAX_TIMERS]TimerSlot = initTimers(),
    anims: [MAX_ANIMS]AnimSlot = initAnims(),

    /// `advance` 的返回：本次推进结果。
    pub const Step = struct {
        /// 是否有定时器触发 / 动画被推进（调用方据此决定是否重绘）。
        moved: bool = false,
        /// 是否仍有活跃定时器或动画（调用方据此决定是否继续唤醒）。
        active: bool = false,
    };

    /// 注册一次性定时（秒）。返回句柄（下标），池满返回 null。
    pub fn setTimeout(t: *Ticker, cb: *const fn (?*anyopaque) void, ctx: ?*anyopaque, delay: f64, now: f64) ?usize {
        return putTimer(t, cb, ctx, 0, now + @max(0, delay));
    }
    /// 注册周期定时（秒）。返回句柄，池满返回 null。
    pub fn setInterval(t: *Ticker, cb: *const fn (?*anyopaque) void, ctx: ?*anyopaque, period: f64, now: f64) ?usize {
        return putTimer(t, cb, ctx, @max(0, period), now + @max(0, period));
    }
    fn putTimer(t: *Ticker, cb: *const fn (?*anyopaque) void, ctx: ?*anyopaque, period: f64, next: f64) ?usize {
        for (&t.timers, 0..) |*s, i| {
            if (!s.active) {
                s.* = .{ .active = true, .period = period, .next = next, .ctx = ctx, .cb = cb };
                return i;
            }
        }
        return null;
    }

    /// 注册动画（秒）。返回句柄，池满返回 null。
    pub fn animate(t: *Ticker, cb: *const fn (?*anyopaque, f32) bool, ctx: ?*anyopaque, duration: f64, ease: Ease, now: f64) ?usize {
        if (duration <= 0) return null;
        for (&t.anims, 0..) |*a, i| {
            if (!a.active) {
                a.* = .{ .active = true, .start = now, .duration = duration, .ease = ease, .ctx = ctx, .cb = cb };
                return i;
            }
        }
        return null;
    }

    pub fn clearTimer(t: *Ticker, handle: usize) void {
        if (handle < MAX_TIMERS) t.timers[handle] = .{};
    }
    pub fn clearAnim(t: *Ticker, handle: usize) void {
        if (handle < MAX_ANIMS) t.anims[handle] = .{};
    }

    /// 是否还有活跃定时器/动画（平台据此挂/停惰性唤醒定时器）。
    pub fn hasActive(t: *const Ticker) bool {
        for (&t.timers) |s| if (s.active) return true;
        for (&t.anims) |a| if (a.active) return true;
        return false;
    }

    /// 按单调钟推进一次：触发到期定时器、推进动画。任何触发/推进都置 moved=true。
    pub fn advance(t: *Ticker, now: f64) Step {
        var moved = false;
        // 定时器（独立于动画处理，避免借用冲突）。
        for (&t.timers) |*s| {
            if (!s.active) continue;
            if (s.next <= now) {
                s.cb(s.ctx);
                if (s.period > 0) {
                    // 周期：推进到"不超过 now"的最近触发点，避免长时间阻塞后一次触发堆叠。
                    const steps = @floor((now - s.next) / s.period) + 1.0;
                    s.next += s.period * steps;
                } else {
                    s.active = false;
                }
                moved = true;
            }
        }
        // 动画。
        for (&t.anims) |*a| {
            if (!a.active) continue;
            const raw: f64 = (now - a.start) / a.duration;
            if (raw >= 1.0) {
                _ = a.cb(a.ctx, 1.0); // 末帧补 e=1，保证目标态落定。
                a.active = false;
            } else {
                const p: f32 = @floatCast(@max(0.0, raw));
                if (!a.cb(a.ctx, a.ease.apply(p))) a.active = false;
            }
            moved = true;
        }
        return .{ .moved = moved, .active = t.hasActive() };
    }
};

// —— 测试 ——

test "setTimeout fires once then deactivates" {
    var t = Ticker{};
    var fired: usize = 0;
    const h = t.setTimeout(&struct {
        fn f(ctx: ?*anyopaque) void {
            const p: *usize = @ptrCast(@alignCast(ctx.?));
            p.* += 1;
        }
    }.f, &fired, 1.0, 0.0).?;
    _ = h;
    var s = t.advance(0.5);
    try std.testing.expect(!s.moved);
    try std.testing.expect(s.active);
    s = t.advance(1.0);
    try std.testing.expect(s.moved);
    try std.testing.expect(fired == 1);
    // 一次性：触发后停，不再活跃。
    try std.testing.expect(!t.hasActive());
    s = t.advance(2.0);
    try std.testing.expect(fired == 1);
}

test "setInterval fires repeatedly with catch-up" {
    var t = Ticker{};
    var n: usize = 0;
    _ = t.setInterval(&struct {
        fn f(ctx: ?*anyopaque) void {
            const p: *usize = @ptrCast(@alignCast(ctx.?));
            p.* += 1;
        }
    }.f, &n, 0.5, 0.0);
    try std.testing.expect(t.hasActive());
    _ = t.advance(1.0); // 0.5 处触发一次。
    try std.testing.expect(n == 1);
    _ = t.advance(1.6); // 1.0 处再触发。
    try std.testing.expect(n == 2);
    _ = t.advance(2.0); // 1.5 处再触发。
    try std.testing.expect(n == 3);
}

test "animate maps progress through easing and completes" {
    var t = Ticker{};
    var last: f32 = -1;
    const h = t.animate(&struct {
        fn f(ctx: ?*anyopaque, eased: f32) bool {
            const p: *f32 = @ptrCast(@alignCast(ctx.?));
            p.* = eased;
            return true;
        }
    }.f, &last, 2.0, .linear, 0.0).?;
    _ = h;
    _ = t.advance(1.0); // 中途：eased=0.5
    try std.testing.expect(last > 0.4 and last < 0.6);
    try std.testing.expect(t.hasActive());
    _ = t.advance(2.0); // 完成：补 e=1，停。
    try std.testing.expect(last == 1.0);
    try std.testing.expect(!t.hasActive());
}

test "animate callback returning false stops early" {
    var t = Ticker{};
    var calls: usize = 0;
    _ = t.animate(&struct {
        fn f(ctx: ?*anyopaque, eased: f32) bool {
            _ = eased;
            const p: *usize = @ptrCast(@alignCast(ctx.?));
            p.* += 1;
            return false; // 立刻停。
        }
    }.f, &calls, 2.0, .linear, 0.0);
    _ = t.advance(0.5);
    try std.testing.expect(calls == 1);
    try std.testing.expect(!t.hasActive());
}

test "clearTimer cancels pending fire" {
    var t = Ticker{};
    var n: usize = 0;
    const h = t.setTimeout(&struct {
        fn f(ctx: ?*anyopaque) void {
            const p: *usize = @ptrCast(@alignCast(ctx.?));
            p.* += 1;
        }
    }.f, &n, 1.0, 0.0).?;
    t.clearTimer(h);
    _ = t.advance(5.0);
    try std.testing.expect(n == 0);
    try std.testing.expect(!t.hasActive());
}
