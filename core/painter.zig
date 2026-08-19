//! core/painter.zig —— PaintCtx 接口与 MockPainter（规则 §5.6）。
//!
//! 模块不变量：
//! - 本文件只定义接口（vtable）与测试用 MockPainter，不实现真实渲染；
//! - render/ 提供 D2D 实现，必须实现同一 vtable；
//! - 圆角矩形等组合便捷方法在接口层实现，实现侧只提供原语（§5.6）；
//! - MockPainter 把调用记录进数组，测试断言 draw call 序列。

const std = @import("std");
const geo = @import("geometry.zig");
const theme = @import("../theme.zig");

/// 文本布局句柄：render/text.zig 生产，measure 直接消费（§5.7）。
pub const TextLayout = struct {
    /// 紧致包围盒（DIP），measure 直接使用。
    bounds: geo.Size = .{},
    /// 实现私有 payload（DWrite layout 等）。M4 填充。
    payload: *anyopaque = undefined,
};

/// PaintCtx 接口：render 实现必须满足（§5.6）。
/// `impl` 是实现侧对象指针，vtable 方法以其为 opaque 参数被调用。
pub const PaintCtx = struct {
    vtable: *const VTable,
    impl: *anyopaque,
    theme_ref: *const theme.Theme,

    pub const VTable = struct {
        fillRect: *const fn (impl: *anyopaque, rect: geo.Rect, color: theme.Color) void,
        strokeRect: *const fn (impl: *anyopaque, rect: geo.Rect, color: theme.Color, width: f32, radius: f32) void,
        drawText: *const fn (impl: *anyopaque, rect: geo.Rect, tl: *const TextLayout, color: theme.Color) void,
        pushClip: *const fn (impl: *anyopaque, rect: geo.Rect) void,
        popClip: *const fn (impl: *anyopaque) void,
        clipIntersects: *const fn (impl: *anyopaque, rect: geo.Rect) bool,
    };

    pub fn fillRect(self: PaintCtx, rect: geo.Rect, color: theme.Color) void {
        self.vtable.fillRect(self.impl, rect, color);
    }
    pub fn strokeRect(self: PaintCtx, rect: geo.Rect, color: theme.Color, width: f32, radius: f32) void {
        self.vtable.strokeRect(self.impl, rect, color, width, radius);
    }
    pub fn drawText(self: PaintCtx, rect: geo.Rect, tl: *const TextLayout, color: theme.Color) void {
        self.vtable.drawText(self.impl, rect, tl, color);
    }
    pub fn pushClip(self: PaintCtx, rect: geo.Rect) void {
        self.vtable.pushClip(self.impl, rect);
    }
    pub fn popClip(self: PaintCtx) void {
        self.vtable.popClip(self.impl);
    }
    pub fn clipIntersects(self: PaintCtx, rect: geo.Rect) bool {
        return self.vtable.clipIntersects(self.impl, rect);
    }
};

/// MockPainter：录制 draw call 序列供测试断言。
pub const MockPainter = struct {
    calls: std.ArrayListUnmanaged(Call) = .empty,
    allocator: std.mem.Allocator,
    ctx: PaintCtx = undefined,

    pub const Call = union(enum) {
        fillRect: struct { rect: geo.Rect, color: theme.Color },
        strokeRect: struct { rect: geo.Rect, color: theme.Color, width: f32, radius: f32 },
        drawText: struct { rect: geo.Rect, color: theme.Color },
        pushClip: geo.Rect,
        popClip,
    };

    var vtable: PaintCtx.VTable = .{
        .fillRect = implFillRect,
        .strokeRect = implStrokeRect,
        .drawText = implDrawText,
        .pushClip = implPushClip,
        .popClip = implPopClip,
        .clipIntersects = implClipIntersects,
    };

    /// 在堆上构造并返回（impl 指针须稳定指向自身体例，值类型会被拷贝导致悬垂）。
    pub fn init(allocator: std.mem.Allocator, th: *const theme.Theme) !*MockPainter {
        const p = try allocator.create(MockPainter);
        p.* = .{ .allocator = allocator };
        p.ctx = .{ .vtable = &vtable, .impl = p, .theme_ref = th };
        return p;
    }

    pub fn destroy(self: *MockPainter) void {
        self.calls.deinit(self.allocator);
        const a = self.allocator;
        a.destroy(self);
    }

    pub fn reset(self: *MockPainter) void {
        self.calls.clearRetainingCapacity();
    }

    fn implFillRect(impl: *anyopaque, rect: geo.Rect, color: theme.Color) void {
        const s: *MockPainter = @ptrCast(@alignCast(impl));
        s.calls.append(s.allocator, .{ .fillRect = .{ .rect = rect, .color = color } }) catch unreachable;
    }
    fn implStrokeRect(impl: *anyopaque, rect: geo.Rect, color: theme.Color, width: f32, radius: f32) void {
        const s: *MockPainter = @ptrCast(@alignCast(impl));
        s.calls.append(s.allocator, .{ .strokeRect = .{ .rect = rect, .color = color, .width = width, .radius = radius } }) catch unreachable;
    }
    fn implDrawText(impl: *anyopaque, rect: geo.Rect, tl: *const TextLayout, color: theme.Color) void {
        _ = tl;
        const s: *MockPainter = @ptrCast(@alignCast(impl));
        s.calls.append(s.allocator, .{ .drawText = .{ .rect = rect, .color = color } }) catch unreachable;
    }
    fn implPushClip(impl: *anyopaque, rect: geo.Rect) void {
        const s: *MockPainter = @ptrCast(@alignCast(impl));
        s.calls.append(s.allocator, .{ .pushClip = rect }) catch unreachable;
    }
    fn implPopClip(impl: *anyopaque) void {
        const s: *MockPainter = @ptrCast(@alignCast(impl));
        s.calls.append(s.allocator, .popClip) catch unreachable;
    }
    fn implClipIntersects(impl: *anyopaque, rect: geo.Rect) bool {
        _ = impl;
        _ = rect;
        return true; // Mock 默认不剔除；测试可覆盖。
    }
};

test "mock painter records fill and stroke call sequence" {
    const m = try MockPainter.init(std.testing.allocator, &theme.light);
    defer m.destroy();

    m.ctx.fillRect(.{ .x = 1, .y = 2, .w = 10, .h = 5 }, theme.light.bg_surface);
    m.ctx.strokeRect(.{ .x = 0, .y = 0, .w = 4, .h = 4 }, theme.light.border, 1, 4);

    try std.testing.expect(m.calls.items.len == 2);
    try std.testing.expect(m.calls.items[0] == .fillRect);
    try std.testing.expect(geo.approxEq(1, m.calls.items[0].fillRect.rect.x));
    try std.testing.expect(m.calls.items[1] == .strokeRect);
    try std.testing.expect(geo.approxEq(4, m.calls.items[1].strokeRect.radius));
}

test "mock painter handles clip stack" {
    const m = try MockPainter.init(std.testing.allocator, &theme.dark);
    defer m.destroy();

    m.ctx.pushClip(.{ .x = 0, .y = 0, .w = 50, .h = 50 });
    m.ctx.popClip();

    try std.testing.expect(m.calls.items.len == 2);
    try std.testing.expect(m.calls.items[0] == .pushClip);
    try std.testing.expect(m.calls.items[1] == .popClip);
}
