//! render/device.zig —— D2D/DWrite 设备：工厂 + HwndRenderTarget（规则 §5.6/§5.9）。
//!
//! 模块不变量：
//! - 这是 render/ 的根：持有 D2D 工厂、DWrite 工厂与 HwndRenderTarget；
//! - 每帧 BeginDraw 后设一次 DIP 缩放矩阵，此后全程逻辑坐标（§5.6）；
//! - EndDraw 返回设备丢失错误 → 整建 render target 与全部缓存并重绘一次（§5.6）；
//! - COM 调用走 win32 包的 vtable struct，本项目不手写 COM 声明（§5.6）；
//! - 对象缓存强制：brush 按颜色惰性缓存（cache.zig），绘制循环禁止现建对象。

const std = @import("std");
const win32 = @import("../platform/win32.zig");
const d2d = win32.direct2d;
const dw = win32.direct_write;
const cache = @import("cache.zig");
const text = @import("text.zig");

const log = std.log.scoped(.render);

/// 渲染设备：持有工厂与 render target，负责创建/重设/设备丢失恢复。
pub const Device = struct {
    /// 分配器（init 传入，页面级）。
    allocator: std.mem.Allocator,
    /// D2D 工厂（UI 单线程）。
    d2d_factory: *d2d.ID2D1Factory,
    /// DWrite 工厂（线程安全，单例）。
    dwrite_factory: *dw.IDWriteFactory,
    /// 绑定的窗口句柄（L2：整个 UI 一个顶层 HWND）。
    hwnd: win32.HWND,
    /// 可为 null：窗口未显示前延迟创建（首次 beginFrame 时确保）。
    rt: ?*d2d.ID2D1HwndRenderTarget = null,
    /// 当前 DIP 缩放（1.0 = 96 DPI）。WM_DPICHANGED 时更新。
    dpi_scale: f32 = 1.0,
    /// 内容区物理像素尺寸（像素）；WM_SIZE 时更新。
    px_width: u32 = 0,
    px_height: u32 = 0,
    /// 颜色 → 实心画刷 缓存（§5.6 对象缓存强制）。
    brush_cache: cache.BrushCache,
    /// DWrite 文本系统（TextFormat + TextLayout 缓存，§5.7）。
    text_system: text.TextSystemImpl,
    /// 折线绘制用 path geometry（strokePolyline 复用，惰性创建；§5.6 禁止每帧建对象）。
    path_geometry: ?*d2d.ID2D1PathGeometry = null,

    /// 创建设备。失败返回错误（可失败边界，§4.2）。
    pub fn init(allocator: std.mem.Allocator, hwnd: win32.HWND) !*Device {
        const self = try allocator.create(Device);
        errdefer allocator.destroy(self);

        // D2D 工厂（UI 单线程，免 debug 层）。
        var d2d_factory: *d2d.ID2D1Factory = undefined;
        var hr = win32.d2d1.D2D1CreateFactory(
            .SINGLE_THREADED,
            d2d.IID_ID2D1Factory,
            null,
            @ptrCast(&d2d_factory),
        );
        if (hr.failed) {
            log.err("D2D1CreateFactory failed", .{});
            return error.D2DFactoryFailed;
        }

        // DWrite 工厂（线程安全，单例）。
        var dwrite_factory: *dw.IDWriteFactory = undefined;
        hr = win32.dwrite.DWriteCreateFactory(
            .SHARED,
            dw.IID_IDWriteFactory,
            @ptrCast(&dwrite_factory),
        );
        if (hr.failed) {
            log.err("DWriteCreateFactory failed", .{});
            return error.DWriteFactoryFailed;
        }

        self.* = .{
            .allocator = allocator,
            .d2d_factory = d2d_factory,
            .dwrite_factory = dwrite_factory,
            .hwnd = hwnd,
            .brush_cache = cache.BrushCache.init(allocator, d2d_factory),
            .text_system = text.TextSystemImpl.init(allocator, dwrite_factory),
        };
        return self;
    }

    /// 确保 render target 存在（窗口未显示时延迟创建）。返回 false = 暂不可绘制。
    pub fn ensureTarget(self: *Device) bool {
        if (self.rt != null) return true;
        self.createRenderTarget() catch return false;
        return self.rt != null;
    }

    /// 创建/重建 render target（init 与设备丢失共用）。
    fn createRenderTarget(self: *Device) !void {
        // 用实际客户端尺寸（像素），避免 0 尺寸 target。
        const client = self.getClientPx();
        if (client.width == 0 or client.height == 0) return error.EmptyClient;

        const props = d2d.D2D1_RENDER_TARGET_PROPERTIES{
            .type = .DEFAULT,
            .pixelFormat = .{
                .format = .B8G8R8A8_UNORM,
                .alphaMode = .PREMULTIPLIED,
            },
            .dpiX = 96.0,
            .dpiY = 96.0,
            .usage = .{},
            .minLevel = .DEFAULT,
        };
        const hwnd_props = d2d.D2D1_HWND_RENDER_TARGET_PROPERTIES{
            .hwnd = self.hwnd,
            .pixelSize = .{ .width = client.width, .height = client.height },
            .presentOptions = .{ .RETAIN_CONTENTS = 1 },
        };
        var rt: *d2d.ID2D1HwndRenderTarget = undefined;
        const hr = self.d2d_factory.CreateHwndRenderTarget(&props, &hwnd_props, &rt);
        if (hr.failed) {
            log.err("CreateHwndRenderTarget failed", .{});
            return error.RenderTargetFailed;
        }
        self.rt = rt;
        self.px_width = client.width;
        self.px_height = client.height;
        self.brush_cache.reset(); // 旧 brush 绑定旧 target，必须清空。
    }

    /// 读取客户端矩形（物理像素）。
    fn getClientPx(self: *Device) d2d.common.D2D_SIZE_U {
        var rc: win32.RECT = undefined;
        _ = win32.user32.GetClientRect(self.hwnd, &rc);
        const w: u32 = @intCast(@max(0, rc.right - rc.left));
        const h: u32 = @intCast(@max(0, rc.bottom - rc.top));
        return .{ .width = w, .height = h };
    }

    /// WM_SIZE：重设 render target 像素尺寸（DIP 尺寸由调用方乘 scale 传入）。
    pub fn resize(self: *Device, px_w: u32, px_h: u32) !void {
        self.px_width = px_w;
        self.px_height = px_h;
        // rt 可能尚未创建（窗口未显示）；尺寸先记录，ensureTarget 时生效。
        if (self.rt == null) return;
        const hr = self.rt.?.Resize(&.{
            .width = @max(1, px_w),
            .height = @max(1, px_h),
        });
        if (hr.failed) {
            // 拖动过程 D2D 常报 RECREATE_TARGET 等；释放旧 target，下次
            // ensureTarget 用 GetClientRect 实际尺寸重建（自愈，避免死循环）。
            log.debug("rt.Resize failed (0x{x}), target will be rebuilt", .{@as(u32, @bitCast(hr))});
            self.releaseTarget();
            return error.RenderTargetResizeFailed;
        }
    }

    /// 释放当前 render target 并清空 brush 缓存（设备丢失 / resize 失败共用）。
    fn releaseTarget(self: *Device) void {
        if (self.rt) |rt| _ = rt.IUnknown.Release();
        self.rt = null;
        self.brush_cache.reset();
    }

    /// WM_DPICHANGED：更新缩放。DIP 逻辑坐标不变，只改矩阵。
    pub fn setDpi(self: *Device, scale: f32) void {
        self.dpi_scale = scale;
    }

    /// 帧开始：BeginDraw + 设置 DIP 缩放矩阵。调用方须先 ensureTarget。
    pub fn beginFrame(self: *Device) void {
        const rt = self.rt.?;
        rt.ID2D1RenderTarget.BeginDraw();
        // DIP → 物理像素矩阵（§5.6：每帧设一次，此后全程逻辑坐标）。
        const scale = self.dpi_scale;
        const mat = d2d.common.D2D_MATRIX_3X2_F{
            .Anonymous = .{ .Anonymous1 = .{ .m11 = scale, .m12 = 0, .m21 = 0, .m22 = scale, .dx = 0, .dy = 0 } },
        };
        rt.ID2D1RenderTarget.SetTransform(&mat);
    }

    /// 帧结束：EndDraw。返回 true 表示设备丢失已重建、需要重绘一次。
    pub fn endFrame(self: *Device) bool {
        const rt = self.rt.?;
        const hr = rt.ID2D1RenderTarget.EndDraw(null, null);
        if (hr.failed) {
            log.debug("EndDraw failed (0x{x}), rebuilding target", .{@as(u32, @bitCast(hr))});
            self.releaseTarget();
            self.createRenderTarget() catch {
                log.err("render target rebuild failed", .{});
                return false;
            };
            return true;
        }
        return false;
    }

    /// 释放设备与全部缓存（render target / brush / 工厂）。
    pub fn deinit(self: *Device) void {
        // 注意：不可在此调用 releaseTarget()（它也会 reset brush_cache）。
        // brush_cache.deinit() 内部已 reset 释放全部 brush 并 deinit map；
        // rt 在此直接释放，避免重复 reset 已释放的 map（incorrect alignment）。
        if (self.rt) |rt| _ = rt.IUnknown.Release();
        if (self.path_geometry) |g| _ = g.IUnknown.Release();
        self.brush_cache.deinit();
        _ = self.dwrite_factory.IUnknown.Release();
        _ = self.d2d_factory.IUnknown.Release();
        const a = self.allocator;
        a.destroy(self);
    }
};

test "render device module compiles" {
    // render 依赖真实 Win32/D2D，无法在 CI 单测；此处仅确保类型可引用。
    _ = Device;
    _ = cache.BrushCache;
}
