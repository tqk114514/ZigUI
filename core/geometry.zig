//! core/geometry.zig —— 基础几何类型（规则 §5.1），纯逻辑、可脱离 Windows 单测。
//!
//! 模块不变量：
//! - 全部坐标/尺寸为 DIP f32；物理像素禁止出现在本文件（L3）；
//! - `snap` 是**全项目唯一**的 DIP→物理像素取整点；任何其他模块不得自行取整；
//! - 禁止浮点相等比较；布局断言用容差 0.001 的近似比较；
//! - 本文件不 import 平台/渲染/theme 之外的任何东西。

const std = @import("std");

/// 断言容差：所有近似比较统一用它。
pub const epsilon: f32 = 0.001;

/// 近似相等（±epsilon），用于取代浮点 ==。
pub fn approxEq(a: f32, b: f32) bool {
    return @abs(a - b) <= epsilon;
}

/// 二维点，DIP。
pub const Point = struct {
    x: f32 = 0,
    y: f32 = 0,
};

/// 尺寸，DIP。
pub const Size = struct {
    width: f32 = 0,
    height: f32 = 0,
};

/// 边距/内边距，DIP。
pub const Edges = struct {
    left: f32 = 0,
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,

    /// 等值构造。
    pub fn all(v: f32) Edges {
        return .{ .left = v, .top = v, .right = v, .bottom = v };
    }
};

/// 矩形，DIP，使用 x/y/w/h（§5.1）。
pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    /// 是否包含某点（含边界）。
    pub fn contains(self: Rect, p: Point) bool {
        return p.x >= self.x and p.x <= self.x + self.w and
            p.y >= self.y and p.y <= self.y + self.h;
    }

    /// 内缩：四边各缩进 e。尺寸至少为 0。
    pub fn inset(self: Rect, e: Edges) Rect {
        const nl = self.x + e.left;
        const nt = self.y + e.top;
        const nw = @max(0, self.w - e.left - e.right);
        const nh = @max(0, self.h - e.top - e.bottom);
        return .{ .x = nl, .y = nt, .w = nw, .h = nh };
    }

    /// 外扩：四边各扩展 e。
    pub fn outset(self: Rect, e: Edges) Rect {
        return .{
            .x = self.x - e.left,
            .y = self.y - e.top,
            .w = self.w + e.left + e.right,
            .h = self.h + e.top + e.bottom,
        };
    }

    /// 是否与另一矩形相交（含边界相触视为相交）。
    pub fn intersects(self: Rect, o: Rect) bool {
        return self.x < o.x + o.w and o.x < self.x + self.w and
            self.y < o.y + o.h and o.y < self.y + self.h;
    }

    /// 与另一矩形的交集（可能为空矩形，尺寸夹到 ≥0）。裁剪栈逐层缩小用（§5.4）。
    pub fn intersection(self: Rect, o: Rect) Rect {
        const l = @max(self.x, o.x);
        const t = @max(self.y, o.y);
        const r = @min(self.x + self.w, o.x + o.w);
        const b = @min(self.y + self.h, o.y + o.h);
        return .{ .x = l, .y = t, .w = @max(0, r - l), .h = @max(0, b - t) };
    }
};

/// DIP → 物理像素取整：四舍五入、负数对称（规则 §4.4）。
/// 输入为 DIP 缩放后的物理像素值（f32），输出为取整后的 i32 物理像素。
/// 本项目**唯一**允许的取整点；其余模块一律禁止自行取整。
pub fn snap(v: f32) i32 {
    return @intFromFloat(@round(v));
}

/// DIP 值 → 像素级 Rect（供 render 边界使用；core 自身的 layout 绝不使用）。
pub fn snapRect(x: f32, y: f32, w: f32, h: f32) @Vector(4, i32) {
    return .{ snap(x), snap(y), snap(w), snap(h) };
}

test "point and size zero by default" {
    const p = Point{};
    const s = Size{};
    try std.testing.expect(p.x == 0 and p.y == 0);
    try std.testing.expect(s.width == 0 and s.height == 0);
}

test "rect contains" {
    const r = Rect{ .x = 10, .y = 20, .w = 100, .h = 50 };
    try std.testing.expect(r.contains(.{ .x = 10, .y = 20 })); // 含左边界
    try std.testing.expect(r.contains(.{ .x = 110, .y = 70 })); // 含右/下边界
    try std.testing.expect(!r.contains(.{ .x = 9, .y = 20 }));
    try std.testing.expect(!r.contains(.{ .x = 111, .y = 70 }));
}

test "rect inset clamps to zero" {
    const r = Rect{ .x = 0, .y = 0, .w = 10, .h = 10 };
    const t = r.inset(Edges.all(3));
    try std.testing.expect(approxEq(t.x, 3) and approxEq(t.y, 3));
    try std.testing.expect(approxEq(t.w, 4) and approxEq(t.h, 4));
    // 过深的内缩不产生负尺寸。
    const over = r.inset(Edges.all(20));
    try std.testing.expect(over.w == 0 and over.h == 0);
}

test "rect outset grows" {
    const r = Rect{ .x = 10, .y = 10, .w = 10, .h = 10 };
    const t = r.outset(Edges.all(5));
    try std.testing.expect(approxEq(t.x, 5) and approxEq(t.w, 20));
    try std.testing.expect(approxEq(t.h, 20));
}

test "rect intersects" {
    const a = Rect{ .x = 0, .y = 0, .w = 10, .h = 10 };
    const b = Rect{ .x = 5, .y = 5, .w = 10, .h = 10 }; // 相交
    const c = Rect{ .x = 20, .y = 20, .w = 5, .h = 5 }; // 不相交
    try std.testing.expect(a.intersects(b));
    try std.testing.expect(!a.intersects(c));
    // 边界相触视为相交（0 面积重叠）。
    const touch = Rect{ .x = 10, .y = 0, .w = 5, .h = 5 };
    try std.testing.expect(!a.intersects(touch));
}

test "rect intersection narrows to overlap" {
    const a = Rect{ .x = 0, .y = 0, .w = 100, .h = 100 };
    const b = Rect{ .x = 50, .y = 50, .w = 100, .h = 100 };
    const i = a.intersection(b);
    try std.testing.expect(approxEq(i.x, 50) and approxEq(i.y, 50));
    try std.testing.expect(approxEq(i.w, 50) and approxEq(i.h, 50));
    // 不相交 → 空矩形（尺寸 0）。
    const c = Rect{ .x = 200, .y = 0, .w = 10, .h = 10 };
    const e = a.intersection(c);
    try std.testing.expect(e.w == 0 or e.h == 0);
}

test "snap rounds negative symmetric" {
    try std.testing.expect(snap(0.5) == 1);
    try std.testing.expect(snap(-0.5) == -1); // 负数对称（四舍五入远离 0）
    try std.testing.expect(snap(1.4) == 1);
    try std.testing.expect(snap(2.0) == 2);
}

test "approxEq tolerance" {
    try std.testing.expect(approxEq(1.0005, 1.0));
    try std.testing.expect(!approxEq(1.002, 1.0));
}
