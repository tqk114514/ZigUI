//! core/layout.zig —— 布局类型与纯算术（规则 §5.5）。
//!
//! 模块不变量：
//! - 本文件只含纯类型与纯函数，**不 import 其他 core 模块**，可独立单测；
//! - 节点遍历（measure/arrange 的树操作）由 node.zig 编排，经本文件类型与辅助函数执行；
//! - measure 只读 measured/children/style/layout，禁止读 rect；arrange 不得改 measured（§5.5）；
//! - 子节点收到的约束必须是 loosen 过的（显式 stretch 例外）；
//! - **传播终止**：重测结果与缓存一致时，不再向父级继续标脏（根节点整档稳定的前提）。

const std = @import("std");
const geo = @import("geometry.zig");

pub const epsilon: f32 = 0.001;

/// 未约束时的"无穷"上限（DIP）。用大有限值而非 f32::inf，避免 clamp 溢出。
pub const max_dim: f32 = 1_000_000.0;

/// 布局约束：min/max 尺寸（DIP）。
pub const Constraints = struct {
    min: geo.Size = .{},
    max: geo.Size = .{ .width = max_dim, .height = max_dim },

    /// 取非约束形式：只保留 max（给子节点的默认约束，§5.5）。
    pub fn loosen(self: Constraints) Constraints {
        return .{ .max = self.max };
    }

    /// 把尺寸 clamp 到 [min, max] 区间。
    pub fn constrain(self: Constraints, s: geo.Size) geo.Size {
        const clamp = struct {
            fn run(v: f32, lo: f32, hi: f32) f32 {
                return @max(lo, @min(hi, v));
            }
        };
        return .{
            .width = clamp.run(s.width, self.min.width, self.max.width),
            .height = clamp.run(s.height, self.min.height, self.max.height),
        };
    }

    /// 缓存键相等判断（§5.5：约束与 cache_cons 相等即缓存命中）。
    pub fn eql(a: Constraints, b: Constraints) bool {
        return geo.approxEq(a.min.width, b.min.width) and
            geo.approxEq(a.min.height, b.min.height) and
            geo.approxEq(a.max.width, b.max.width) and
            geo.approxEq(a.max.height, b.max.height);
    }
};

/// 主轴方向。
pub const Axis = enum { horizontal, vertical };

/// 交叉轴对齐。
pub const CrossAlign = enum { start, center, stretch };

/// Stack（row / column）的参数。
pub const Stack = struct {
    gap: f32 = 0,
    cross: CrossAlign = .stretch,
};

/// Layout union：v1 只做 row / column / none（绝对定位）。（§5.5）
pub const Layout = union(enum) {
    none,
    row: Stack,
    column: Stack,
};

/// 计算一个 Stack 在给定子尺寸下的固有尺寸（含 padding）。
/// 仅纯算术；node.zig 在 measure 中消费。
pub fn stackSize(
    axis: Axis,
    child_sizes: []const geo.Size,
    stack: Stack,
    padding: geo.Edges,
) geo.Size {
    var main: f32 = 0;
    var cross: f32 = 0;
    const n: usize = child_sizes.len;

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const s = child_sizes[i];
        if (axis == .horizontal) {
            main += s.width;
            cross = @max(cross, s.height);
        } else {
            main += s.height;
            cross = @max(cross, s.width);
        }
    }
    if (n > 0) main += stack.gap * @as(f32, @floatFromInt(n - 1));

    return switch (axis) {
        .horizontal => .{
            .width = main + padding.left + padding.right,
            .height = cross + padding.top + padding.bottom,
        },
        .vertical => .{
            .width = cross + padding.left + padding.right,
            .height = main + padding.top + padding.bottom,
        },
    };
}

/// 把子节点按 Stack 排进 inner 区域，写满 out[i]。
/// out.len 必须 == child_sizes.len。
pub fn arrangeStack(
    axis: Axis,
    inner: geo.Rect,
    child_sizes: []const geo.Size,
    stack: Stack,
    out: []geo.Rect,
) void {
    std.debug.assert(out.len == child_sizes.len);

    const cross_len: f32 = if (axis == .horizontal) inner.h else inner.w;
    const main0: f32 = if (axis == .horizontal) inner.x else inner.y;
    const cross0: f32 = if (axis == .horizontal) inner.y else inner.x;

    var pos: f32 = main0;
    var i: usize = 0;
    while (i < child_sizes.len) : (i += 1) {
        const s = child_sizes[i];

        var cross_off: f32 = 0;
        var cross_size = s_cross(s, axis);
        if (stack.cross == .stretch) {
            cross_size = cross_len;
        } else {
            cross_size = @min(cross_size, cross_len);
            if (stack.cross == .center) {
                cross_off = @max(0, (cross_len - cross_size) * 0.5);
            }
        }

        const main_size = s_main(s, axis);
        out[i] = if (axis == .horizontal)
            geo.Rect{ .x = pos, .y = cross0 + cross_off, .w = main_size, .h = cross_size }
        else
            geo.Rect{ .x = cross0 + cross_off, .y = pos, .w = cross_size, .h = main_size };

        pos += main_size + stack.gap;
    }
}

fn s_main(s: geo.Size, axis: Axis) f32 {
    return if (axis == .horizontal) s.width else s.height;
}
fn s_cross(s: geo.Size, axis: Axis) f32 {
    return if (axis == .horizontal) s.height else s.width;
}

test "constraints loosen keeps max only" {
    const c: Constraints = .{ .max = .{ .width = 100, .height = 200 } };
    const l = c.loosen();
    try std.testing.expect(geo.approxEq(0, l.min.width));
    try std.testing.expect(geo.approxEq(0, l.min.height));
    try std.testing.expect(geo.approxEq(100, l.max.width));
    try std.testing.expect(geo.approxEq(200, l.max.height));
}

test "constraints constrain clamps to bounds" {
    const c: Constraints = .{
        .min = .{ .width = 10, .height = 10 },
        .max = .{ .width = 100, .height = 100 },
    };
    const small = c.constrain(.{ .width = 1, .height = 200 });
    try std.testing.expect(geo.approxEq(10, small.width));
    try std.testing.expect(geo.approxEq(100, small.height));
    const inside = c.constrain(.{ .width = 50, .height = 50 });
    try std.testing.expect(geo.approxEq(50, inside.width));
}

test "stackSize vertical sums heights + gap + padding" {
    const childs = [_]geo.Size{
        .{ .width = 100, .height = 20 },
        .{ .width = 80, .height = 30 },
        .{ .width = 50, .height = 25 },
    };
    const pad: geo.Edges = .{ .left = 4, .top = 6, .right = 4, .bottom = 6 };
    const s = stackSize(.vertical, &childs, .{ .gap = 8 }, pad);
    // 主轴：20+30+25 + 2*8 + 12 = 103；交叉轴：max(100,80,50) + 8 = 108
    try std.testing.expect(geo.approxEq(108, s.width));
    try std.testing.expect(geo.approxEq(103, s.height));
}

test "stackSize empty is padding only" {
    const pad: geo.Edges = .all(10);
    const s = stackSize(.horizontal, &.{}, .{ .gap = 8 }, pad);
    try std.testing.expect(geo.approxEq(20, s.width));
    try std.testing.expect(geo.approxEq(20, s.height));
}

test "arrangeStack vertical start aligns to top" {
    const inner = geo.Rect{ .x = 0, .y = 0, .w = 100, .h = 100 };
    const childs = [_]geo.Size{ .{ .width = 40, .height = 20 }, .{ .width = 40, .height = 30 } };
    var out: [2]geo.Rect = undefined;
    arrangeStack(.vertical, inner, &childs, .{ .gap = 10, .cross = .start }, &out);
    try std.testing.expect(geo.approxEq(0, out[0].x));
    try std.testing.expect(geo.approxEq(0, out[0].y));
    try std.testing.expect(geo.approxEq(40, out[0].w));
    try std.testing.expect(geo.approxEq(20, out[0].h));
    try std.testing.expect(geo.approxEq(30, out[1].y)); // 20 + 10
}

test "arrangeStack horizontal center" {
    const inner = geo.Rect{ .x = 0, .y = 0, .w = 200, .h = 50 };
    const childs = [_]geo.Size{.{ .width = 40, .height = 20 }};
    var out: [1]geo.Rect = undefined;
    arrangeStack(.horizontal, inner, &childs, .{ .gap = 0, .cross = .center }, &out);
    try std.testing.expect(geo.approxEq(15, out[0].y)); // (50-20)/2
    try std.testing.expect(geo.approxEq(40, out[0].w));
}

test "arrangeStack stretch fills cross" {
    const inner = geo.Rect{ .x = 10, .y = 10, .w = 100, .h = 60 };
    const childs = [_]geo.Size{.{ .width = 30, .height = 5 }};
    var out: [1]geo.Rect = undefined;
    arrangeStack(.horizontal, inner, &childs, .{ .gap = 0, .cross = .stretch }, &out);
    try std.testing.expect(geo.approxEq(10, out[0].y));
    try std.testing.expect(geo.approxEq(60, out[0].h));
    try std.testing.expect(geo.approxEq(30, out[0].w));
}

test "constraints eql cache key" {
    const a: Constraints = .{ .max = .{ .width = 100, .height = 100 } };
    const b: Constraints = .{ .max = .{ .width = 100, .height = 100 } };
    const c: Constraints = .{ .max = .{ .width = 101, .height = 100 } };
    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}
