//! render/painter.zig —— PaintCtx 的 D2D 实现（规则 §5.6）。
//!
//! 模块不变量：
//! - 实现 core/painter.zig 的 PaintCtx vtable；
//! - DIP→物理像素的转换与取整只发生在 render/painter.zig 与 platform 边界（L3）；
//! - 矩形/颜色用 D2D 结构字面量（内存布局与 theme.Color 一致）；
//! - brush 一律走 cache（§5.6 强制，禁止现建）。

const std = @import("std");
const win32 = @import("../platform/win32.zig");
const d2d = win32.direct2d;
const geometry = @import("../core/geometry.zig");
const painter = @import("../core/painter.zig");
const theme = @import("../theme.zig");
const device_mod = @import("device.zig");
const text_mod = @import("text.zig");

/// 折线最大点数（帧路径栈上缓冲上限，L4 零分配）。
const MAX_POLY_PTS: usize = 32;

/// D2D 实现的 PaintCtx：持 device 引用，vtable 固定。
pub const D2DPainter = struct {
    /// 渲染设备引用（持有 target 与缓存）。
    device: *device_mod.Device,

    /// 裁剪栈（DIP）：pushClip/popClip 同步维护，clipIntersects 据此剔除（§5.4
    /// ScrollView 性能的前提）。有效裁剪区 = 栈内所有 clip 的交集；每帧 paint
    /// push/pop 成对出现，帧末深度归零。
    clip_stack: [128]geometry.Rect = undefined,
    clip_depth: usize = 0,

    var vtable: painter.PaintCtx.VTable = .{
        .fillRect = implFillRect,
        .strokeRect = implStrokeRect,
        .drawText = implDrawText,
        .pushClip = implPushClip,
        .popClip = implPopClip,
        .clipIntersects = implClipIntersects,
        .fillRoundedRect = implFillRoundedRect,
        .strokeLine = implStrokeLine,
        .strokePolyline = implStrokePolyline,
        .fillEllipse = implFillEllipse,
    };

    pub fn ctx(self: *D2DPainter, th: *const theme.Theme) painter.PaintCtx {
        return .{
            .vtable = &vtable,
            .impl = self,
            .theme_ref = th,
        };
    }

    fn selfOf(impl: *anyopaque) *D2DPainter {
        return @ptrCast(@alignCast(impl));
    }

    fn implFillRect(impl: *anyopaque, rect: geometry.Rect, color: theme.Color) void {
        const self = selfOf(impl);
        const r = snapRectToPixels(rect, self.device.dpi_scale);
        const d2d_rect = toD2DRect(r);
        if (brushFor(self, color)) |b| {
            self.device.rt.?.ID2D1RenderTarget.FillRectangle(&d2d_rect, brushCast(b));
        }
    }

    fn implStrokeRect(impl: *anyopaque, rect: geometry.Rect, color: theme.Color, width: f32, radius: f32) void {
        const self = selfOf(impl);
        if (brushFor(self, color)) |b| {
            // stroke 与 fill 共用同一像素基准（§5.6）：先对 rect 对齐整像素网格
            // （与 fillRect/fillRoundedRect 一致），再内缩半线宽。此时边界必落在
            // 像素中心（整像素 − half），1px 描边恰好覆盖单个像素带；四边与 fill
            // 无缝衔接、均匀锐利。若对原始 rect 独立对齐半像素，边界非半像素值时
            // 会漂移错位，出现某条边被抗锯齿摊薄（如上边模糊）。
            const base = snapRectToPixels(rect, self.device.dpi_scale);
            const inner = base.inset(geometry.Edges.all(width * 0.5));
            if (radius > 0) {
                const rr = d2d.D2D1_ROUNDED_RECT{
                    .rect = toD2DRect(inner),
                    .radiusX = radius,
                    .radiusY = radius,
                };
                self.device.rt.?.ID2D1RenderTarget.DrawRoundedRectangle(
                    &rr,
                    brushCast(b),
                    width,
                    null,
                );
            } else {
                self.device.rt.?.ID2D1RenderTarget.DrawRectangle(
                    &toD2DRect(inner),
                    brushCast(b),
                    width,
                    null,
                );
            }
        }
    }

    fn implFillRoundedRect(impl: *anyopaque, rect: geometry.Rect, radius: f32, color: theme.Color) void {
        const self = selfOf(impl);
        const r = snapRectToPixels(rect, self.device.dpi_scale);
        if (brushFor(self, color)) |b| {
            const rr = d2d.D2D1_ROUNDED_RECT{
                .rect = toD2DRect(r),
                .radiusX = radius,
                .radiusY = radius,
            };
            self.device.rt.?.ID2D1RenderTarget.FillRoundedRectangle(&rr, brushCast(b));
        }
    }

    fn implStrokeLine(impl: *anyopaque, x0: f32, y0: f32, x1: f32, y1: f32, width: f32, color: theme.Color) void {
        const pts = [_]geometry.Point{ .{ .x = x0, .y = y0 }, .{ .x = x1, .y = y1 } };
        implStrokePolyline(impl, &pts, width, color);
    }

    fn implStrokePolyline(impl: *anyopaque, points: []const geometry.Point, width: f32, color: theme.Color) void {
        const self = selfOf(impl);
        if (brushFor(self, color)) |b| {
            if (points.len < 2) return;
            const dev = self.device;
            // 取（或惰性创建）复用的 path geometry：单对象缓存复用（§5.6 禁止每帧建对象）。
            // 走 DrawGeometry 而非 DrawLine：Zig 0.16 x64 对 DrawLine 两个连续 by-value
            // D2D_POINT_2F 的传参 codegen 段错误（DrawTextLayout 单点正常），绕开之。
            const geo = dev.path_geometry orelse blk: {
                var g: *d2d.ID2D1PathGeometry = undefined;
                if (dev.d2d_factory.CreatePathGeometry(&g).failed) return;
                dev.path_geometry = g;
                break :blk g;
            };
            var sink: *d2d.ID2D1GeometrySink = undefined;
            if (geo.Open(&sink).failed) return;
            defer _ = sink.IUnknown.Release();
            const s = sink.ID2D1SimplifiedGeometrySink;
            s.BeginFigure(.{ .x = points[0].x, .y = points[0].y }, .HOLLOW);
            // 显式拷贝为 extern D2D_POINT_2F：不把普通 struct（geometry.Point）指针
            // @ptrCast 重解释给 D2D（普通 struct 布局不受保证），规避 ABI/布局问题。
            // 折线长度有界（勾号/图标 ≤ 数十点），栈上固定缓冲，帧路径零分配（L4）。
            var d2d_pts: [MAX_POLY_PTS]d2d.common.D2D_POINT_2F = undefined;
            const n = @min(points.len, MAX_POLY_PTS);
            var i: usize = 1;
            while (i < n) : (i += 1) {
                d2d_pts[i - 1] = .{ .x = points[i].x, .y = points[i].y };
            }
            s.AddLines(&d2d_pts, @intCast(n - 1));
            s.EndFigure(.OPEN);
            _ = s.Close();
            dev.rt.?.ID2D1RenderTarget.DrawGeometry(&geo.ID2D1Geometry, brushCast(b), width, null);
        }
    }

    fn implFillEllipse(impl: *anyopaque, center: geometry.Point, rx: f32, ry: f32, color: theme.Color) void {
        const self = selfOf(impl);
        // 圆心对齐像素网格（滑块拇指等小圆形锐利；§5.6）。
        const scale = self.device.dpi_scale;
        const c = geometry.Point{
            .x = @as(f32, @floatFromInt(geometry.snap(center.x * scale))) / scale,
            .y = @as(f32, @floatFromInt(geometry.snap(center.y * scale))) / scale,
        };
        if (brushFor(self, color)) |b| {
            const e = d2d.D2D1_ELLIPSE{
                .point = .{ .x = c.x, .y = c.y },
                .radiusX = rx,
                .radiusY = ry,
            };
            self.device.rt.?.ID2D1RenderTarget.FillEllipse(&e, brushCast(b));
        }
    }

    fn implDrawText(impl: *anyopaque, rect: geometry.Rect, tl: *const painter.TextLayout, color: theme.Color) void {
        const self = selfOf(impl);
        if (brushFor(self, color)) |b| {
            const entry: *text_mod.TextSystemImpl.LayoutEntry = @fieldParentPtr("tl", @constCast(tl));
            const origin = d2d.common.D2D_POINT_2F{ .x = rect.x, .y = rect.y };
            _ = self.device.rt.?.ID2D1RenderTarget.DrawTextLayout(
                origin,
                entry.dw_layout,
                brushCast(b),
                .{},
            );
        }
    }

    fn implPushClip(impl: *anyopaque, rect: geometry.Rect) void {
        const self = selfOf(impl);
        // 与 D2D PushAxisAlignedClip 同步维护裁剪栈（DIP）。
        if (self.clip_depth < self.clip_stack.len) {
            // 新 clip = 当前有效裁剪区 ∩ rect（保留模式裁剪栈是逐层缩小）。
            if (self.clip_depth == 0) {
                self.clip_stack[0] = rect;
            } else {
                const cur = self.clip_stack[self.clip_depth - 1];
                self.clip_stack[self.clip_depth] = cur.intersection(rect);
            }
            self.clip_depth += 1;
        }
        const clip = toD2DRect(rect);
        self.device.rt.?.ID2D1RenderTarget.PushAxisAlignedClip(
            &clip,
            .PER_PRIMITIVE,
        );
    }

    fn implPopClip(impl: *anyopaque) void {
        const self = selfOf(impl);
        if (self.clip_depth > 0) self.clip_depth -= 1;
        self.device.rt.?.ID2D1RenderTarget.PopAxisAlignedClip();
    }

    fn implClipIntersects(impl: *anyopaque, rect: geometry.Rect) bool {
        const self = selfOf(impl);
        // 无裁剪栈 → 整个窗口可见。
        if (self.clip_depth == 0) return true;
        // 与当前有效裁剪区相交即保留（含边界相触，§5.4 clipIntersects 剔除判定）。
        return self.clip_stack[self.clip_depth - 1].intersects(rect);
    }

    fn brushFor(self: *D2DPainter, color: theme.Color) ?*d2d.ID2D1SolidColorBrush {
        return self.device.brush_cache.brushFor(&self.device.rt.?.ID2D1RenderTarget, color);
    }
};

fn toD2DRect(r: geometry.Rect) d2d.common.D2D_RECT_F {
    return .{ .left = r.x, .top = r.y, .right = r.x + r.w, .bottom = r.y + r.h };
}

/// 矩形四边对齐物理像素网格（pixel snapping，§5.6）：DIP × scale 取整后再除回，
/// 使边界落在整像素上——fill/stroke 四边视觉均匀、无半像素抗锯齿错位。
/// 本项目唯一 DIP→物理像素取整点仍是 core/geometry.snap（§5.1），此处复用其规则。
fn snapRectToPixels(r: geometry.Rect, scale: f32) geometry.Rect {
    if (scale <= 0) return r;
    const x = @as(f32, @floatFromInt(geometry.snap(r.x * scale))) / scale;
    const y = @as(f32, @floatFromInt(geometry.snap(r.y * scale))) / scale;
    const x2 = @as(f32, @floatFromInt(geometry.snap((r.x + r.w) * scale))) / scale;
    const y2 = @as(f32, @floatFromInt(geometry.snap((r.y + r.h) * scale))) / scale;
    return .{ .x = x, .y = y, .w = x2 - x, .h = y2 - y };
}

/// SolidColorBrush → ID2D1Brush（extern union 同址，指针转换）。
fn brushCast(b: *d2d.ID2D1SolidColorBrush) ?*d2d.ID2D1Brush {
    return @ptrCast(b);
}

test "snapRectToPixels aligns edges to pixel grid" {
    // scale=1：边界取整。
    const r1 = snapRectToPixels(.{ .x = 10.5, .y = 3.2, .w = 5.4, .h = 4.6 }, 1.0);
    try std.testing.expect(geometry.approxEq(r1.x, 11));
    try std.testing.expect(geometry.approxEq(r1.y, 3));
    try std.testing.expect(geometry.approxEq(r1.w, 5)); // right=16 → 11+5
    try std.testing.expect(geometry.approxEq(r1.h, 5)); // bottom=8 → 3+5

    // scale=2（200%）：DIP 半像素也对齐到整物理像素。
    const r2 = snapRectToPixels(.{ .x = 10.25, .y = 10.25, .w = 5.5, .h = 5.5 }, 2.0);
    try std.testing.expect(geometry.approxEq(r2.x, 10.5)); // 20.5 → 21 / 2
    try std.testing.expect(geometry.approxEq(r2.w, 5.0)); // right 30.5→31 /2 =15.5 → 10.5+5
    // 负数对称。
    const r3 = snapRectToPixels(.{ .x = -10.5, .y = -10.5, .w = 4.0, .h = 4.0 }, 1.0);
    try std.testing.expect(geometry.approxEq(r3.x, -11));
    // 退化 scale。
    const r0 = snapRectToPixels(.{ .x = 1.5, .y = 1.5, .w = 2.0, .h = 2.0 }, 0.0);
    try std.testing.expect(geometry.approxEq(r0.x, 1.5));
}
