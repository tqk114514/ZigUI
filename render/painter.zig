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
const cache = @import("cache.zig");
const geometry = @import("../core/geometry.zig");
const painter = @import("../core/painter.zig");
const node = @import("../core/node.zig");
const theme = @import("../theme.zig");
const device_mod = @import("device.zig");
const text_mod = @import("text.zig");

/// 折线最大点数（帧路径栈上缓冲上限，L4 零分配）。
const MAX_POLY_PTS: usize = 32;
/// 滚动条带缓冲倍数（§5.6 光栅缓存）：surface 高 = 视口高 × 本倍数，视口居条带中央，
/// 上下各留缓冲，滚动越出条带才重栅化。
const SURFACE_MULT: f32 = 3.0;

/// D2D 实现的 PaintCtx：持 device 引用，vtable 固定。
pub const D2DPainter = struct {
    /// 渲染设备引用（持有 target 与缓存）。
    device: *device_mod.Device,
    /// 是否绘制到离屏表面（§5.6）：true 时绘制目标设备是 device.surface.dc，brush 用
    /// surface_brush（与主 rt 隔离，防 D2DERR_WRONG_TARGET）。
    surf: bool = false,

    /// 裁剪栈（DIP）：pushClip/popClip 同步维护，clipIntersects 据此剔除（§5.4
    /// ScrollView 性能的前提）。有效裁剪区 = 栈内所有 clip 的交集；每帧 paint
    /// push/pop 成对出现，帧末深度归零。
    clip_stack: [128]geometry.Rect = undefined,
    clip_depth: usize = 0,

    /// 当前绘制 target（主 rt 或离屏表面 dc），以 ID2D1RenderTarget 视之（COM 继承基址同址）。
    fn rt(self: *D2DPainter) *d2d.ID2D1RenderTarget {
        return if (self.surf)
            &self.device.surface.dc.?.ID2D1RenderTarget
        else
            &self.device.rt.?.ID2D1RenderTarget;
    }

    /// 当前 brush 缓存（主 或 离屏 独立缓存；目标必须匹配，§5.6）。
    fn brushBank(self: *D2DPainter) *cache.BrushCache {
        return if (self.surf) &self.device.surface_brush else &self.device.brush_cache;
    }

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
            self.rt().FillRectangle(&d2d_rect, brushCast(b));
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
                self.rt().DrawRoundedRectangle(
                    &rr,
                    brushCast(b),
                    width,
                    null,
                );
            } else {
                self.rt().DrawRectangle(
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
            self.rt().FillRoundedRectangle(&rr, brushCast(b));
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
            // 必须用 render target 所属工厂创建（dev.path_factory，与 rt 同域）——用显式
            // D2D1CreateFactory 建的工厂会导致 D2DERR_WRONG_FACTORY（首帧 EndDraw 失败后整建）。
            // 走 DrawGeometry 而非 DrawLine：Zig 0.16 x64 对 DrawLine 两个连续 by-value
            // D2D_POINT_2F 的传参 codegen 段错误（DrawTextLayout 单点正常），绕开之。
            const geo = dev.path_geometry orelse blk: {
                const fac = dev.path_factory orelse return;
                var g: *d2d.ID2D1PathGeometry = undefined;
                if (fac.CreatePathGeometry(&g).failed) return;
                dev.path_geometry = g;
                break :blk g;
            };
            var sink: *d2d.ID2D1GeometrySink = undefined;
            if (geo.Open(&sink).failed) return;
            defer _ = sink.IUnknown.Release();
            // 取字段指针而非拷贝：COM 对象的方法经 vtable 派发，D2D 实现要读对象内部状态，
            // 传栈上拷贝的地址会读到垃圾（首帧 BeginFigure 段错误）。字段在 union 偏移 0，
            // 取址即原对象指针。
            const s = &sink.ID2D1SimplifiedGeometrySink;
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
            self.rt().DrawGeometry(&geo.ID2D1Geometry, brushCast(b), width, null);
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
            self.rt().FillEllipse(&e, brushCast(b));
        }
    }

    fn implDrawText(impl: *anyopaque, rect: geometry.Rect, tl: *const painter.TextLayout, color: theme.Color) void {
        const self = selfOf(impl);
        if (brushFor(self, color)) |b| {
            const entry: *text_mod.TextSystemImpl.LayoutEntry = @fieldParentPtr("tl", @constCast(tl));
            const origin = d2d.common.D2D_POINT_2F{ .x = rect.x, .y = rect.y };
            _ = self.rt().DrawTextLayout(
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
        self.rt().PushAxisAlignedClip(
            &clip,
            .PER_PRIMITIVE,
        );
    }

    fn implPopClip(impl: *anyopaque) void {
        const self = selfOf(impl);
        if (self.clip_depth > 0) self.clip_depth -= 1;
        self.rt().PopAxisAlignedClip();
    }

    fn implClipIntersects(impl: *anyopaque, rect: geometry.Rect) bool {
        const self = selfOf(impl);
        // 无裁剪栈 → 整个窗口可见。
        if (self.clip_depth == 0) return true;
        // 与当前有效裁剪区相交即保留（含边界相触，§5.4 clipIntersects 剔除判定）。
        return self.clip_stack[self.clip_depth - 1].intersects(rect);
    }

    fn brushFor(self: *D2DPainter, color: theme.Color) ?*d2d.ID2D1SolidColorBrush {
        return self.brushBank().brushFor(self.rt(), color);
    }
};

const log = std.log.scoped(.render);

fn toD2DRect(r: geometry.Rect) d2d.common.D2D_RECT_F {
    return .{ .left = r.x, .top = r.y, .right = r.x + r.w, .bottom = r.y + r.h };
}

/// 装配层宿主（§5.6 光栅缓存/分层）。impl = device。层节点 = scroll（隐式）或 node.layer（显式）。
pub fn asLayerHost(dev: *device_mod.Device) node.LayerHost {
    return .{
        .vtable = &.{
            .paintLayer = &implPaintLayer,
            .invalidate = &implSurfaceInvalidate,
        },
        .impl = dev,
    };
}

/// 内部：内容/几何变化 → 置脏离屏表面，下帧重栅化（§5.6；变换变化——如滚动平移——不经过此路径）。
fn implSurfaceInvalidate(impl: *anyopaque, n: *node.Node) void {
    _ = n;
    const dev: *device_mod.Device = @ptrCast(@alignCast(impl));
    dev.surface_dirty = true;
}

/// 层节点离屏绘制入口（§5.6 光栅缓存/分层）：scroll 层走条带+平移复用；其余显式 node.layer
/// 子树走整块静态缓存层。两者都返回 true（已处理，跳过默认子递归）。
fn implPaintLayer(impl: *anyopaque, t: *node.Tree, n: *node.Node, pc: painter.PaintCtx) bool {
    const dev: *device_mod.Device = @ptrCast(@alignCast(impl));
    return if (n.widget == .scroll)
        implScrollLayer(dev, t, n, pc)
    else
        implStaticLayer(dev, t, n, pc);
}

/// 通用静态缓存层（§5.6 分层）：把 node.layer 子树整体光栅化到离屏位图（节点 rect 大小），
/// 内容变才重栅化（invalidate）；否则直接 blit 复用。用于任意"静态但父级常变"的子块，
/// 使其不随父级 hover/变换每帧重绘。注意：本轮为单活动层（与 scroll 层共享单表面，互斥使用；
/// 完整分层=多并发层池，留后续）。
fn implStaticLayer(dev: *device_mod.Device, t: *node.Tree, n: *node.Node, pc: painter.PaintCtx) bool {
    const view = n.rect;
    if (view.w <= 0 or view.h <= 0 or n.children.len == 0) return false;
    const node_id: usize = @intFromPtr(n);
    const view_w = view.w;
    const view_h = view.h;
    const sf = &dev.surface;
    // 复用：缓存已含该 node 内容 → 直接 blit（内容未变，无平移 offset）。
    if (!dev.surface_dirty and sf.node_id == node_id and
        geometry.approxEq(sf.view_w, view_w) and geometry.approxEq(sf.view_h, view_h))
    {
        if (sf.bitmap != null) blitSurface(dev, view, .{ .x = 0, .y = 0, .w = view_w, .h = view_h });
        return true;
    }
    // 栅化：把该子树画到离屏位图（本地坐标对齐位图原点，对齐物理像素）。
    const dpi = 96.0 * dev.dpi_scale;
    const px_w: u32 = @intFromFloat(std.math.ceil(view_w * dev.dpi_scale));
    const px_h: u32 = @intFromFloat(std.math.ceil(view_h * dev.dpi_scale));
    dev.beginSurface(px_w, px_h) catch return false;
    const sdc = dev.surface.dc.?;
    const srt = &sdc.ID2D1RenderTarget;
    srt.SetDpi(dpi, dpi);
    const sc = dev.dpi_scale;
    const dx = @as(f32, @floatFromInt(geometry.snap(-view.x * sc))) / sc;
    const dy = @as(f32, @floatFromInt(geometry.snap(-view.y * sc))) / sc;
    var mat = d2d.common.D2D_MATRIX_3X2_F{
        .Anonymous = .{ .Anonymous1 = .{ .m11 = 1, .m12 = 0, .m21 = 0, .m22 = 1, .dx = dx, .dy = dy } },
    };
    srt.SetTransform(&mat);
    srt.BeginDraw();
    // 透明填充：露出主场景已绘的背景（Node 层绘制）。
    srt.Clear(&d2d.common.D2D_COLOR_F{ .r = 0, .g = 0, .b = 0, .a = 0 });
    var sp = D2DPainter{ .device = dev, .surf = true };
    const spc = sp.ctx(pc.theme_ref);
    t.paintChildrenInto(spc, n, view);
    const herr = srt.EndDraw(null, null);
    sdc.SetTarget(null);
    dev.surface.in_use = false;
    if (herr.failed) {
        dev.surface_dirty = true;
        return false;
    }
    sf.node_id = node_id;
    sf.view_w = view_w;
    sf.view_h = view_h;
    sf.anchor_off = 0;
    dev.surface_dirty = false;
    blitSurface(dev, view, .{ .x = 0, .y = 0, .w = view_w, .h = view_h });
    return true;
}

/// 滚动层离屏绘制（scroll widget，§5.6 光栅缓存）：未命中条带则整条带重栅化到离屏位图，
/// 命中则直接 DrawBitmap 平移复用像素（本帧零文本栅格化）。返回 true（已处理）。
fn implScrollLayer(dev: *device_mod.Device, t: *node.Tree, n: *node.Node, pc: painter.PaintCtx) bool {
    const view = n.rect.inset(n.style.padding); // 视口（DIP，scroll 本地坐标）。
    if (view.w <= 0 or view.h <= 0 or n.children.len == 0) return false; // 无可见视口/内容 → 走默认递归
    const off = n.widget.scroll.offset_y;
    const node_id: usize = @intFromPtr(n);
    const view_w = view.w;
    const view_h = view.h;
    const strip_h = view_h * SURFACE_MULT;

    const sf = &dev.surface;
    const strip_half = strip_h * 0.5;
    // 复用判定（§5.6）：内容未脏、仍属该 scroll、视口尺寸未变、平移仍在条带内 → 直接平移位图。
    const reuse_src_y = (strip_half - view_h * 0.5) + (off - sf.anchor_off);
    if (!dev.surface_dirty and sf.node_id == node_id and
        geometry.approxEq(sf.view_w, view_w) and geometry.approxEq(sf.view_h, view_h) and
        reuse_src_y >= 0 and reuse_src_y + view_h <= strip_h + 0.01)
    {
        if (sf.bitmap != null) {
            blitSurface(dev, .{ .x = view.x, .y = view.y, .w = view_w, .h = view_h }, .{ .x = 0, .y = reuse_src_y, .w = view_w, .h = view_h });
        }
        return true;
    }

    // —— 重栅化：把当前可见区放条带中央，整条带光栅化到离屏位图 ——
    const dpi = 96.0 * dev.dpi_scale;
    const px_w: u32 = @intFromFloat(std.math.ceil(view_w * dev.dpi_scale));
    const px_h: u32 = @intFromFloat(std.math.ceil(strip_h * dev.dpi_scale));
    dev.beginSurface(px_w, px_h) catch return false;
    const sdc = dev.surface.dc.?;
    const srt = &sdc.ID2D1RenderTarget;
    srt.SetDpi(dpi, dpi);
    // 表面坐标 = 本地坐标 + (dx, dy)：把条带原点折到表面 (0,0)，children（本地坐标）随之落入条带。
    // dx/dy 对齐物理像素（§5.1 snap）：若条带内容落在半像素，配合 blit 的像素对齐 snap，
    // 不同 rebake anchor 下内容行会在 0/1px 间往返（滚动观感"没对齐"）。对齐后条带内容整体
    // 落在整像素栅格上，blit 平移也保持整像素步进，内容位置稳定无往返。
    const sc = dev.dpi_scale;
    const dy = @as(f32, @floatFromInt(geometry.snap((strip_half - view_h * 0.5 - view.y) * sc))) / sc;
    const dx = @as(f32, @floatFromInt(geometry.snap(-view.x * sc))) / sc;
    var mat = d2d.common.D2D_MATRIX_3X2_F{
        .Anonymous = .{ .Anonymous1 = .{ .m11 = 1, .m12 = 0, .m21 = 0, .m22 = 1, .dx = dx, .dy = dy } },
    };
    srt.SetTransform(&mat);
    srt.BeginDraw();
    // 透明填充：露出主场景已绘的 scroll 背景（Node 层绘制）。
    srt.Clear(&d2d.common.D2D_COLOR_F{ .r = 0, .g = 0, .b = 0, .a = 0 });
    // 离屏绘制：独立 painter 绑离屏 target & surface_brush（§5.6 目标必须匹配，防 D2DERR_WRONG_TARGET）。
    var sp = D2DPainter{ .device = dev, .surf = true };
    const spc = sp.ctx(pc.theme_ref);
    // 条带裁剪（本地坐标；D2D 经 SetTransform 自动折换）。核心负责子节点绘制与 clipIntersects 剔除。
    const strip_clip = geometry.Rect{ .x = view.x, .y = view.y + view_h * 0.5 - strip_half, .w = view_w, .h = strip_h };
    t.paintChildrenInto(spc, n, strip_clip);
    const herr = srt.EndDraw(null, null);
    sdc.SetTarget(null);
    dev.surface.in_use = false;
    if (herr.failed) {
        dev.surface_dirty = true; // 失败置脏，下帧重试。
        return false;
    }
    // 记录本次条带元数据供后续复用判定。
    sf.node_id = node_id;
    sf.view_w = view_w;
    sf.view_h = view_h;
    sf.anchor_off = off;
    dev.surface_dirty = false;
    // 视口此时居条带中央：源 y = strip_half - view_h/2。
    const rebaked_src_y = (strip_half - view_h * 0.5) + (off - sf.anchor_off);
    blitSurface(dev, .{ .x = view.x, .y = view.y, .w = view_w, .h = view_h }, .{ .x = 0, .y = rebaked_src_y, .w = view_w, .h = view_h });
    return true;
}

/// 离屏表面位图 → 主场景平移绘制（§5.6）：dest 为主场景矩形（DIP），src 为条带内源矩形（DIP）。
/// 平移是原样移动、不改内容尺寸：**只把位置对齐物理像素（§5.1 snap），尺寸保留原始 view 宽高**——
/// 若连 w/h 一起取整，会把内容拖到偶/奇整数尺寸，顶行被拉伸/+1px 缝隙（滚动"没对齐"）。
/// 位置对齐 + 尺寸不变 → 内容 1:1、以整像素步进平移，无缩放、无顶行残边。
fn blitSurface(dev: *device_mod.Device, dest: geometry.Rect, src: geometry.Rect) void {
    const rt = dev.rt orelse return;
    const bmp = dev.surface.bitmap orelse return;
    const scale = dev.dpi_scale;
    const w = dest.w;
    const h = dest.h;
    const d = geometry.Rect{
        .x = @as(f32, @floatFromInt(geometry.snap(dest.x * scale))) / scale,
        .y = @as(f32, @floatFromInt(geometry.snap(dest.y * scale))) / scale,
        .w = w,
        .h = h,
    };
    const s = geometry.Rect{
        .x = @as(f32, @floatFromInt(geometry.snap(src.x * scale))) / scale,
        .y = @as(f32, @floatFromInt(geometry.snap(src.y * scale))) / scale,
        .w = w,
        .h = h,
    };
    rt.DrawBitmap(&bmp.ID2D1Bitmap, &toD2DRect(d), 1.0, d2d.D2D1_INTERPOLATION_MODE.LINEAR, &toD2DRect(s), null);
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
