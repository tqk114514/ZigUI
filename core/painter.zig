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
    /// 紧致包围盒（DIP），measure 直接使用（宽度不含尾随空白）。
    bounds: geo.Size = .{},
    /// 含尾随空白的宽度（caret 定位用，§5.8）。DWrite metrics.width 不含尾随空白，
    /// 前缀"hello " 若用 bounds.width 会漏算空格导致光标偏位。
    width_with_ws: f32 = 0,
    /// 实现私有 payload（DWrite layout 等）。
    payload: *anyopaque = undefined,
};

/// 文本布局选项（wrap / ellipsis）。
pub const TextLayoutOptions = struct {
    /// 超过 max_width 是否换行（多行文本）。
    wrap: bool = false,
    /// 超宽时尾部省略号（单行，与 wrap 互斥）。
    ellipsis: bool = false,
};

/// TextSystem 接口（§5.7）：layout 必须命中缓存（L4 稳态零分配）。
/// core 只定义接口；render/text.zig 提供 DWrite 实现，测试用 Mock 提供假尺寸。
pub const TextSystem = struct {
    /// 实现 vtable。
    vtable: *const VTable,
    /// 实现实例（render 提供）。
    impl: *anyopaque,

    pub const VTable = struct {
        /// 生成文本布局。max_width ≤ 0 表示不换行。返回 TextLayout 指针（实现侧持有，勿释放）。
        layout: *const fn (impl: *anyopaque, text: []const u8, font: *const theme.Font, max_width: f32, options: TextLayoutOptions) ?*TextLayout,
    };

    pub fn layout(self: TextSystem, text: []const u8, font: *const theme.Font, max_width: f32, options: TextLayoutOptions) ?*TextLayout {
        return self.vtable.layout(self.impl, text, font, max_width, options);
    }
};

/// PaintCtx 接口：render 实现必须满足（§5.6）。
/// `impl` 是实现侧对象指针，vtable 方法以其为 opaque 参数被调用。
pub const PaintCtx = struct {
    /// 实现 vtable（render/D2D 或 MockPainter）。
    vtable: *const VTable,
    /// 实现实例指针。
    impl: *anyopaque,
    /// 主题引用（L9：控件视觉只取 token）。
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
    /// 录制的 draw call 序列（测试断言用）。
    calls: std.ArrayListUnmanaged(Call) = .empty,
    /// 分配器（init 时传入）。
    allocator: std.mem.Allocator,
    /// 装配好的 PaintCtx（impl 指向自身）。
    ctx: PaintCtx = undefined,
    /// 可选有效裁剪区：非 null 时 clipIntersects 按其判定（测试 Scroll 剔除，§5.4）。
    clip_rect: ?geo.Rect = null,

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
        const s: *MockPainter = @ptrCast(@alignCast(impl));
        if (s.clip_rect) |c| return c.intersects(rect);
        return true; // Mock 默认不剔除；测试可设 clip_rect。
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
