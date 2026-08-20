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

/// D2D 实现的 PaintCtx：持 device 引用，vtable 固定。
pub const D2DPainter = struct {
    device: *device_mod.Device,

    var vtable: painter.PaintCtx.VTable = .{
        .fillRect = implFillRect,
        .strokeRect = implStrokeRect,
        .drawText = implDrawText,
        .pushClip = implPushClip,
        .popClip = implPopClip,
        .clipIntersects = implClipIntersects,
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
        const d2d_rect = toD2DRect(rect);
        if (brushFor(self, color)) |b| {
            self.device.rt.?.ID2D1RenderTarget.FillRectangle(&d2d_rect, brushCast(b));
        }
    }

    fn implStrokeRect(impl: *anyopaque, rect: geometry.Rect, color: theme.Color, width: f32, radius: f32) void {
        const self = selfOf(impl);
        if (brushFor(self, color)) |b| {
            if (radius > 0) {
                const rr = d2d.D2D1_ROUNDED_RECT{
                    .rect = toD2DRect(rect),
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
                    &toD2DRect(rect),
                    brushCast(b),
                    width,
                    null,
                );
            }
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
        const clip = toD2DRect(rect);
        self.device.rt.?.ID2D1RenderTarget.PushAxisAlignedClip(
            &clip,
            .PER_PRIMITIVE,
        );
    }

    fn implPopClip(impl: *anyopaque) void {
        const self = selfOf(impl);
        self.device.rt.?.ID2D1RenderTarget.PopAxisAlignedClip();
    }

    fn implClipIntersects(impl: *anyopaque, rect: geometry.Rect) bool {
        _ = impl;
        _ = rect;
        // 剔除在 WM_PAINT 剪裁区之外由 BeginDraw 的更新区域处理；
        // 简化：全部绘制；TODO(M6)：Scroll 引入精确剔除。
        return true;
    }

    fn brushFor(self: *D2DPainter, color: theme.Color) ?*d2d.ID2D1SolidColorBrush {
        return self.device.brush_cache.brushFor(&self.device.rt.?.ID2D1RenderTarget, color);
    }
};

fn toD2DRect(r: geometry.Rect) d2d.common.D2D_RECT_F {
    return .{ .left = r.x, .top = r.y, .right = r.x + r.w, .bottom = r.y + r.h };
}

/// SolidColorBrush → ID2D1Brush（extern union 同址，指针转换）。
fn brushCast(b: *d2d.ID2D1SolidColorBrush) ?*d2d.ID2D1Brush {
    return @ptrCast(b);
}
