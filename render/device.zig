//! render/device.zig —— D3D11+flip 设备：D2D/DWrite/D3D11 + DXGI 翻转交换链（规则 §5.6/§5.9）。
//!
//! 模块不变量：
//! - 这是 render/ 的根：持有 D2D/DWrite 工厂、D3D11 设备与 DXGI flip-model 交换链；
//! - 交换链惰性创建（首帧按真实客户区尺寸建，避免隐藏窗口 0 尺寸退化链）；
//! - 每帧 SetTarget + SetDpi 后全程逻辑坐标（§5.6）；Present(1) 对齐下一 v-sync；
//! - EndDraw/Present 返回设备丢失错误 → 整建 GPU 管线与全部缓存并重绘一次（§5.6）；
//! - COM 调用走 win32 包的 vtable struct，本项目不手写 COM 声明（§5.6）；
//! - 对象缓存强制：brush 按颜色惰性缓存（cache.zig），绘制循环禁止现建对象。

const std = @import("std");
const win32 = @import("../platform/win32.zig");
const d2d = win32.direct2d;
const dw = win32.direct_write;
const d3d11 = win32.direct3d11;
const d3d = win32.direct3d;
const dxgi = win32.dxgi;
const cache = @import("cache.zig");
const text = @import("text.zig");

const log = std.log.scoped(.render);

/// 离屏光栅表面（§5.6 光栅缓存）：独立 DC + TARGET 位图，滚动容器内容条带缓存，
/// 滚动时 DrawSurface 平移复用像素，越出条带才重栅化。
pub const RenderSurface = struct {
    /// 离屏 DC（从同 d2d_device 另建，独立于主 rt；避免与主 target 争用）。
    dc: ?*d2d.ID2D1DeviceContext = null,
    /// 离屏 TARGET 位图（CreateBitmap 建，非交换链表面）。物理像素尺寸。
    bitmap: ?*d2d.ID2D1Bitmap1 = null,
    /// 位图物理像素宽高。
    px_w: u32 = 0,
    px_h: u32 = 0,
    /// 是否正被本帧占用（栅格化中；用完即解绑 target）。
    in_use: bool = false,

    // —— 复用判定元数据（§5.6）：条带（strip）参数（DIP，内容坐标）——
    /// 上次栅格化关联的 scroll 节点（地址标识，换节点强制重栅化；不代入核心类型避免依赖）。
    node_id: usize = 0,
    /// 上次栅格化的 scroll 视口（DIP，内区尺寸）。
    view_w: f32 = 0,
    view_h: f32 = 0,
    /// 上次栅格化时的 scroll 内容偏移（DIP）：此刻条带中心对齐视口。
    anchor_off: f32 = 0,
};

/// 渲染设备：持有 D3D11/D2D 设备与翻转交换链，负责创建/重设/设备丢失恢复。
pub const Device = struct {
    /// 分配器（init 传入，页面级）。
    allocator: std.mem.Allocator,
    /// 当前 render target 所属 D2D 工厂（path geometry 必须用它创建——与 rt 同域，
    /// 否则 DrawGeometry 报 D2DERR_WRONG_FACTORY；设备重建后工厂变化，geometry 一并重建）。
    path_factory: ?*d2d.ID2D1Factory = null,
    /// DWrite 工厂（线程安全，单例）。
    dwrite_factory: *dw.IDWriteFactory,
    /// 绑定的窗口句柄（L2：整个 UI 一个顶层 HWND）。
    hwnd: win32.HWND,
    /// DXGI 工厂（交换链惰性创建用，§5.6）。
    dxgi_factory: ?*dxgi.IDXGIFactory2 = null,
    /// D3D11 设备（BGRA，D2D 需要）与立即上下文。
    d3d11_device: ?*d3d11.ID3D11Device = null,
    d3d11_context: ?*d3d11.ID3D11DeviceContext = null,
    /// DXGI flip-model 交换链（FLIP_DISCARD × 2 buffer，Present(1) 对齐 v-sync）。惰性创建。
    swap_chain: ?*dxgi.IDXGISwapChain1 = null,
    /// D2D 设备（与 D3D11 设备关联，创建 device context 用）。
    d2d_device: ?*d2d.ID2D1Device = null,
    /// 可为 null：窗口未显示前延迟创建（首次 beginFrame 时确保）。
    rt: ?*d2d.ID2D1DeviceContext = null,
    /// 交换链后缓冲绑定的 D2D target bitmap。
    target_bitmap: ?*d2d.ID2D1Bitmap1 = null,
    /// 持久帧缓冲（§5.6 部分重绘的基石）：内容每帧画到这块跨帧不变的 CUSTOM bitmap，
    /// 帧末整体 blit 到交换链后缓冲。翻转双缓冲下后缓冲轮流使用，若直接局部重绘画后缓冲，
    /// 非脏区会依赖"上帧另一 buffer 的陈旧/垃圾像素"→ 移入闪烁与滚动撕裂；持久帧缓冲
    /// 保证非脏区来自本帧同一 bitmap，全局一致。
    frame_bitmap: ?*d2d.ID2D1Bitmap1 = null,
    /// 帧缓冲物理像素宽高（尺寸不符时重建）。
    frame_w: u32 = 0,
    frame_h: u32 = 0,
    /// 当前 DIP 缩放（1.0 = 96 DPI）。WM_DPICHANGED 时更新。
    dpi_scale: f32 = 1.0,
    /// 内容区物理像素尺寸；WM_SIZE/ensureTarget 时更新。
    px_width: u32 = 0,
    px_height: u32 = 0,
    /// 颜色 → 实心画刷 缓存（§5.6 对象缓存强制）。
    brush_cache: cache.BrushCache,
    /// DWrite 文本系统（TextFormat + TextLayout 缓存，§5.7）。
    text_system: text.TextSystemImpl,
    /// 折线绘制用 path geometry（strokePolyline 复用，惰性创建；§5.6 禁止每帧建对象）。
    path_geometry: ?*d2d.ID2D1PathGeometry = null,
    /// 离屏光栅表面（§5.6）：滚动容器内容缓存的单例可复用表面。
    surface: RenderSurface = .{},
    /// 离屏绘制专用 brush 缓存：brush 绑离屏 target，与主 rt 隔离（D2DERR_WRONG_TARGET 前提，§5.6）。
    surface_brush: cache.BrushCache,
    /// 表面内容是否已脏：内容/几何变化或首次置脏，下帧重栅化；滚动偏移变化不置脏（复用前提）。
    surface_dirty: bool = true,

    /// 创建设备。失败返回错误（可失败边界，§4.2）。
    pub fn init(allocator: std.mem.Allocator, hwnd: win32.HWND) !*Device {
        const self = try allocator.create(Device);
        errdefer allocator.destroy(self);

        // DWrite 工厂（线程安全，单例）。
        var dwrite_factory: *dw.IDWriteFactory = undefined;
        const hr = win32.dwrite.DWriteCreateFactory(
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
            .dwrite_factory = dwrite_factory,
            .hwnd = hwnd,
            .brush_cache = cache.BrushCache.init(allocator),
            .surface_brush = cache.BrushCache.init(allocator),
            .text_system = text.TextSystemImpl.init(allocator, dwrite_factory),
        };
        // GPU 管线（D3D11 设备 + DXGI 工厂 + D2D 设备；交换链惰性创建）失败时清理已建的 COM 对象。
        self.createGpuPipeline() catch {
            self.releaseGpu();
            return error.DeviceInitFailed;
        };
        return self;
    }

    /// 创建 GPU 管线（D3D11 设备 → DXGI 设备/工厂 → D2D 设备）。init 与设备丢失共用。
    /// 工厂（D2D/DWrite）与缓存不在此重建；交换链由 ensureTarget 按实际尺寸惰性创建。
    fn createGpuPipeline(self: *Device) !void {
        // D3D11 设备（BGRA 支持，D2D 依赖）：硬件优先，失败回退 WARP 软件光栅化。
        const feature_levels = [_]d3d.D3D_FEATURE_LEVEL{ .@"11_1", .@"11_0", .@"10_1", .@"10_0" };
        var d3d11_device: *d3d11.ID3D11Device = undefined;
        var d3d11_ctx: *d3d11.ID3D11DeviceContext = undefined;
        var hr = win32.d3d11.D3D11CreateDevice(
            null,
            .HARDWARE,
            null,
            d3d11.D3D11_CREATE_DEVICE_BGRA_SUPPORT,
            &feature_levels,
            feature_levels.len,
            d3d11.D3D11_SDK_VERSION,
            &d3d11_device,
            null,
            &d3d11_ctx,
        );
        if (hr.failed) {
            // 无硬件驱动（远程桌面/虚拟 GPU 等）时回退 WARP。
            hr = win32.d3d11.D3D11CreateDevice(
                null,
                .WARP,
                null,
                d3d11.D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                &feature_levels,
                feature_levels.len,
                d3d11.D3D11_SDK_VERSION,
                &d3d11_device,
                null,
                &d3d11_ctx,
            );
        }
        if (hr.failed) {
            log.err("D3D11CreateDevice failed", .{});
            return error.D3DDeviceFailed;
        }
        self.d3d11_device = d3d11_device;
        self.d3d11_context = d3d11_ctx;

        // DXGI 设备（D2D1CreateDevice 需要）。
        var dxgi_device: *dxgi.IDXGIDevice = undefined;
        if (d3d11_device.IUnknown.QueryInterface(dxgi.IID_IDXGIDevice, @ptrCast(&dxgi_device)).failed) {
            log.err("QueryInterface IDXGIDevice failed", .{});
            return error.DxgiDeviceFailed;
        }
        defer _ = dxgi_device.IUnknown.Release();
        // 限制排队帧为 1：全局翻转交换链的帧延迟基准（§5.6），可显著减少 resize/高速
        // 交互时 DWM 合成到过期缓冲的拖影与闪屏。
        var dxgi_device1: *dxgi.IDXGIDevice1 = undefined;
        if (!d3d11_device.IUnknown.QueryInterface(dxgi.IID_IDXGIDevice1, @ptrCast(&dxgi_device1)).failed) {
            _ = dxgi_device1.SetMaximumFrameLatency(1);
            _ = dxgi_device1.IUnknown.Release();
        }

        // DXGI 工厂（交换链惰性创建用）。
        var factory: *dxgi.IDXGIFactory2 = undefined;
        hr = win32.dxgi_dll.CreateDXGIFactory2(0, dxgi.IID_IDXGIFactory2, @ptrCast(&factory));
        if (hr.failed) {
            log.err("CreateDXGIFactory2 failed", .{});
            return error.DxgiFactoryFailed;
        }
        self.dxgi_factory = factory;
        // 禁止 Alt+Enter 切换全屏（UI 工具包不需要）。
        _ = factory.IDXGIFactory.MakeWindowAssociation(self.hwnd, dxgi.DXGI_MWA_NO_ALT_ENTER);

        // D2D 设备（同一 D3D11 设备上）。
        var d2d_device: ?*d2d.ID2D1Device = undefined;
        hr = win32.d2d1.D2D1CreateDevice(dxgi_device, null, &d2d_device);
        if (hr.failed) {
            log.err("D2D1CreateDevice failed", .{});
            return error.D2DDeviceFailed;
        }
        self.d2d_device = d2d_device;
        const client = self.getClientPx();
        self.px_width = @max(1, client.width);
        self.px_height = @max(1, client.height);
        self.rt = null;
        self.target_bitmap = null;
    }

    /// 惰性创建 flip 交换链（首帧按真实客户区尺寸建，避免隐藏窗口 0 尺寸退化链）。
    fn createSwapChain(self: *Device, width: u32, height: u32) !void {
        const desc = dxgi.DXGI_SWAP_CHAIN_DESC1{
            .Width = width,
            .Height = height,
            .Format = dxgi.common.DXGI_FORMAT.B8G8R8A8_UNORM,
            .Stereo = 0,
            .SampleDesc = .{ .Count = 1, .Quality = 0 },
            .BufferUsage = dxgi.DXGI_USAGE_RENDER_TARGET_OUTPUT,
            .BufferCount = 2,
            // NONE：DWM 不在 resize 时把旧帧拉伸到新尺寸（STRETCH 会显示"拉伸后回弹"）。
            // 交换链尺寸始终与客户区对齐（WM_SIZE 里 ResizeBuffers），无需 DWM 缩放。
            .Scaling = dxgi.DXGI_SCALING_NONE,
            .SwapEffect = dxgi.DXGI_SWAP_EFFECT_FLIP_DISCARD,
            .AlphaMode = dxgi.common.DXGI_ALPHA_MODE.IGNORE,
            .Flags = 0,
        };
        var swap_chain: *dxgi.IDXGISwapChain1 = undefined;
        const hr = self.dxgi_factory.?.CreateSwapChainForHwnd(&self.d3d11_device.?.IUnknown, self.hwnd, &desc, null, null, &swap_chain);
        if (hr.failed) {
            log.err("CreateSwapChainForHwnd failed", .{});
            return error.SwapChainFailed;
        }
        self.swap_chain = swap_chain;
        self.px_width = width;
        self.px_height = height;
        // 翻转模型：新建交换链后的第一次 Present 被 DXGI 丢弃（用于建立呈现）。
        // 预热一次，确保随后真实内容 present 能上屏（否则首帧白屏到下次输入）。
        self.primePresent();
    }

    /// 空 present 预热翻转交换链（flip 模型丢弃 create/ResizeBuffers 后的首次 present）。
    fn primePresent(self: *Device) void {
        _ = self.swap_chain.?.IDXGISwapChain.Present(0, 0);
    }

    /// 确保 render target 存在（窗口未显示时延迟创建）。返回 false = 暂不可绘制。
    pub fn ensureTarget(self: *Device) bool {
        if (self.rt != null and self.target_bitmap != null) return true;
        self.createRenderTarget() catch return false;
        return self.rt != null and self.target_bitmap != null;
    }

    /// 创建/重建 render target（首帧与自愈共用）：惰性建交换链 → device context → bitmap。
    fn createRenderTarget(self: *Device) !void {
        const client = self.getClientPx();
        if (client.width == 0 or client.height == 0) return error.EmptyClient;
        // 交换链惰性创建（首帧）；已存在且尺寸不符则 ResizeBuffers 对齐。
        if (self.swap_chain == null) {
            try self.createSwapChain(client.width, client.height);
        } else if (client.width != self.px_width or client.height != self.px_height) {
            // 翻转丢弃：先解绑 DC 对 bitmap 的引用再 ResizeBuffers（同 resize()）。
            self.clearTarget();
            if (self.target_bitmap) |b| {
                _ = b.IUnknown.Release();
                self.target_bitmap = null;
            }
            if (self.swap_chain.?.IDXGISwapChain.ResizeBuffers(0, client.width, client.height, dxgi.common.DXGI_FORMAT.B8G8R8A8_UNORM, 0).failed) {
                return error.SwapChainResizeFailed;
            }
            self.px_width = client.width;
            self.px_height = client.height;
        }
        if (self.rt == null) {
            var dc: *d2d.ID2D1DeviceContext = undefined;
            if (self.d2d_device.?.CreateDeviceContext(d2d.D2D1_DEVICE_CONTEXT_OPTIONS_NONE, &dc).failed) return error.D2DDeviceContextFailed;
            self.rt = dc;
        }
        // path geometry 必须与 rt 同工厂创建（§5.6：否则 DrawGeometry 报 D2DERR_WRONG_FACTORY）。
        // 设备重建后此工厂变化，releaseGpu 已释放旧 geometry，这里随 rt 刷新。
        {
            var f: *d2d.ID2D1Factory = undefined;
            self.rt.?.ID2D1Resource.GetFactory(&f);
            self.path_factory = f;
        }
        self.createBitmap() catch return error.D2DBitmapFailed;
        self.brush_cache.reset(); // 旧 brush 绑定旧 target，必须清空。
    }

    /// 从交换链后缓冲创建 D2D bitmap target（调用方保证 rt/swap_chain 已存在、旧 bitmap 已释放）。
    fn createBitmap(self: *Device) !void {
        var surface: *dxgi.IDXGISurface = undefined;
        if (self.swap_chain.?.IDXGISwapChain.GetBuffer(0, dxgi.IID_IDXGISurface, @ptrCast(&surface)).failed) return error.SwapChainGetBufferFailed;
        defer _ = surface.IUnknown.Release();
        const props = d2d.D2D1_BITMAP_PROPERTIES1{
            .pixelFormat = .{
                .format = .B8G8R8A8_UNORM,
                .alphaMode = d2d.common.D2D1_ALPHA_MODE.IGNORE,
            },
            .dpiX = 96.0,
            .dpiY = 96.0,
            .bitmapOptions = .{ .TARGET = 1, .CANNOT_DRAW = 1 },
            .colorContext = null,
        };
        var bitmap: *d2d.ID2D1Bitmap1 = undefined;
        if (self.rt.?.CreateBitmapFromDxgiSurface(surface, &props, &bitmap).failed) return error.D2DBitmapFailed;
        self.target_bitmap = bitmap;
    }

    /// 读取客户端矩形（物理像素）。
    fn getClientPx(self: *Device) d2d.common.D2D_SIZE_U {
        var rc: win32.RECT = undefined;
        _ = win32.user32.GetClientRect(self.hwnd, &rc);
        const w: u32 = @intCast(@max(0, rc.right - rc.left));
        const h: u32 = @intCast(@max(0, rc.bottom - rc.top));
        return .{ .width = w, .height = h };
    }

    /// WM_SIZE：重设交换链尺寸并重绑 bitmap target。
    /// 失败只释放交换链（下一帧 ensureTarget 惰性重建自愈），不整建 GPU 管线。
    pub fn resize(self: *Device, px_w: u32, px_h: u32) !void {
        self.px_width = px_w;
        self.px_height = px_h;
        // 交换链尚未创建（首帧前）：仅记录尺寸，createRenderTarget 按新尺寸创建。
        if (self.swap_chain == null) return;
        // 释放对后缓冲的全部引用再 ResizeBuffers：device context 也持有 target bitmap
        // 引用，必须先 SetTarget(null) 解除，否则翻转模式下 ResizeBuffers 返回 INVALID_CALL。
        self.clearTarget();
        if (self.target_bitmap) |b| {
            _ = b.IUnknown.Release();
            self.target_bitmap = null;
        }
        if (self.swap_chain.?.IDXGISwapChain.ResizeBuffers(0, @max(1, px_w), @max(1, px_h), dxgi.common.DXGI_FORMAT.B8G8R8A8_UNORM, 0).failed) {
            log.debug("ResizeBuffers failed, swap chain will be recreated", .{});
            self.releaseSwapChain();
            return error.RenderTargetResizeFailed;
        }
        // rt 已存在则重绑 bitmap（后缓冲已变化）；未创建则由 createRenderTarget 完成。
        if (self.rt != null) {
            self.createBitmap() catch {
                self.releaseSwapChain();
                return error.RenderTargetResizeFailed;
            };
        }
    }

    /// 释放 device context 对 target bitmap 的引用（§5.6 对象缓存强制：翻转丢弃模式
    /// 下后缓冲被引用则无法 ResizeBuffers/release，故任何重设尺寸/释放前必须先解绑）。
    fn clearTarget(self: *Device) void {
        if (self.rt) |dc| dc.SetTarget(null);
    }

    /// 释放交换链与其 bitmap（ResizeBuffers 失败等非设备丢失场景；D3D11/D2D 设备保留）。
    fn releaseSwapChain(self: *Device) void {
        self.clearTarget();
        if (self.target_bitmap) |b| _ = b.IUnknown.Release();
        if (self.swap_chain) |s| _ = s.IUnknown.Release();
        self.target_bitmap = null;
        self.swap_chain = null;
        self.releaseFrameTarget();
    }

    /// 释放持久帧缓冲与相关尺寸记录（尺寸变化/设备重建/废弃时）。
    fn releaseFrameTarget(self: *Device) void {
        if (self.frame_bitmap) |b| _ = b.IUnknown.Release();
        self.frame_bitmap = null;
        self.frame_w = 0;
        self.frame_h = 0;
    }

    /// 确保持久帧缓冲存在且尺寸与客户区一致（首帧/尺寸变化/设备重建后）。失败静默
    /// （OOM）：beginFrame 回落直接画后缓冲（全窗，性能退化但行为正确）。
    fn ensureFrameTarget(self: *Device) void {
        const dc = self.rt orelse return;
        if (self.px_width == 0 or self.px_height == 0) return;
        if (self.frame_bitmap != null and self.frame_w == self.px_width and self.frame_h == self.px_height) return;
        self.releaseFrameTarget();
        const props = d2d.D2D1_BITMAP_PROPERTIES1{
            .pixelFormat = .{
                .format = .B8G8R8A8_UNORM,
                .alphaMode = d2d.common.D2D1_ALPHA_MODE.IGNORE,
            },
            .dpiX = 96.0,
            .dpiY = 96.0,
            // 仅 TARGET、不带 CANNOT_DRAW：帧缓冲既作内容 target 又在帧末作为 blit 的 source。
            // CANNOT_DRAW 会阻止 DrawBitmap 以它为源（0x88990021）。
            .bitmapOptions = .{ .TARGET = 1 },
            .colorContext = null,
        };
        var b: *d2d.ID2D1Bitmap1 = undefined;
        const size = d2d.common.D2D_SIZE_U{ .width = self.px_width, .height = self.px_height };
        if (dc.CreateBitmap(size, null, 0, &props, &b).failed) return;
        self.frame_bitmap = b;
        self.frame_w = self.px_width;
        self.frame_h = self.px_height;
    }

    /// 释放离屏表面（DC + 位图 + 表面 brush），设备丢失重建/废弃时调用。
    fn releaseSurface(self: *Device) void {
        self.surface_dirty = true;
        if (self.surface.in_use) {
            if (self.surface.dc) |d| d.SetTarget(null); // 先解绑 target 再释放（§5.6 翻转丢弃前提）。
            self.surface.in_use = false;
        }
        if (self.surface.bitmap) |b| _ = b.IUnknown.Release();
        if (self.surface.dc) |d| _ = d.IUnknown.Release();
        self.surface = .{};
        self.surface_brush.reset();
    }

    /// 准备离屏表面到 ≥ 指定物理像素尺寸（首帧/尺寸不足时建 DC 与位图并绑定 target）。
    /// 调用方随后负责 SetDpi/SetTransform/BeginDraw/画内容/EndDraw，并 SetTarget(null) 归还。
    pub fn beginSurface(self: *Device, px_w: u32, px_h: u32) !void {
        if (px_w == 0 or px_h == 0) return error.EmptySurface;
        const dpi = 96.0 * self.dpi_scale;
        if (self.surface.dc == null) {
            // 从同 d2d_device 另建独立 DC：避免与主 rt 争用 target（§5.6 光栅缓存）。
            var dc: *d2d.ID2D1DeviceContext = undefined;
            if (self.d2d_device.?.CreateDeviceContext(d2d.D2D1_DEVICE_CONTEXT_OPTIONS_NONE, &dc).failed) {
                return error.SurfaceDcFailed;
            }
            self.surface.dc = dc;
        }
        // 尺寸不足 → 重建更大位图（条带变化；view/node 变化由 paintScroll 判定重栅化）。
        if (self.surface.bitmap == null or px_w > self.surface.px_w or px_h > self.surface.px_h) {
            if (self.surface.bitmap) |b| _ = b.IUnknown.Release();
            const props = d2d.D2D1_BITMAP_PROPERTIES1{
                .pixelFormat = .{
                    .format = .B8G8R8A8_UNORM,
                    .alphaMode = d2d.common.D2D1_ALPHA_MODE.PREMULTIPLIED,
                },
                .dpiX = dpi,
                .dpiY = dpi,
                .bitmapOptions = .{ .TARGET = 1, .CANNOT_DRAW = 0 },
                .colorContext = null,
            };
            var bmp: *d2d.ID2D1Bitmap1 = undefined;
            if (self.surface.dc.?.CreateBitmap(.{ .width = px_w, .height = px_h }, null, 0, &props, &bmp).failed) {
                return error.SurfaceBitmapFailed;
            }
            self.surface.bitmap = bmp;
            self.surface.px_w = px_w;
            self.surface.px_h = px_h;
        }
        self.surface.in_use = true;
        // 绑定离屏位图为绘制目标（与主交换链 target 相互独立，§5.6）。
        self.surface.dc.?.SetTarget(&self.surface.bitmap.?.ID2D1Image);
    }

    /// 释放 GPU 管线对象与 brush 缓存（设备丢失/重建共用；text 系统保留）。
    fn releaseGpu(self: *Device) void {
        self.releaseSurface();
        self.releaseSwapChain();
        if (self.rt) |rt| _ = rt.IUnknown.Release();
        if (self.d2d_device) |d| _ = d.IUnknown.Release();
        if (self.dxgi_factory) |f| _ = f.IUnknown.Release();
        if (self.d3d11_context) |c| _ = c.IUnknown.Release();
        if (self.d3d11_device) |d| _ = d.IUnknown.Release();
        // path geometry 绑定旧设备工厂，随设备一并释放（§5.6 设备丢失路径）。
        if (self.path_geometry) |g| _ = g.IUnknown.Release();
        self.path_geometry = null;
        self.path_factory = null;
        self.rt = null;
        self.d2d_device = null;
        self.dxgi_factory = null;
        self.d3d11_context = null;
        self.d3d11_device = null;
        self.brush_cache.reset();
    }

    /// WM_DPICHANGED：更新缩放。DIP 逻辑坐标不变，SetDpi 折算物理像素。
    pub fn setDpi(self: *Device, scale: f32) void {
        self.dpi_scale = scale;
    }

    /// 帧开始：绑定持久帧缓冲为绘制目标 + 设 DPI + BeginDraw（§5.6）。调用方须先 ensureTarget。
    /// 内容画到 frame_bitmap（跨帧一致），帧末由 endFrame 整体 blit 到交换链后缓冲。
    pub fn beginFrame(self: *Device) void {
        const dc = self.rt.?;
        self.ensureFrameTarget();
        const target: *d2d.ID2D1Image = if (self.frame_bitmap) |fb|
            &fb.ID2D1Image
        else
            &self.target_bitmap.?.ID2D1Image; // frame 缺失（OOM）回退直接画后缓冲（全窗）。
        dc.SetTarget(target);
        const dpi = 96.0 * self.dpi_scale;
        dc.ID2D1RenderTarget.SetDpi(dpi, dpi);
        dc.ID2D1RenderTarget.BeginDraw();
    }

    /// 帧结束：EndDraw（内容帧）→ 整体 blit frame→后缓冲 → Present(1)。
    /// 返回 true 表示设备丢失已重建、需要重绘一次。
    pub fn endFrame(self: *Device) bool {
        const dc = self.rt.?;
        const hr = dc.ID2D1RenderTarget.EndDraw(null, null);
        if (hr.failed) {
            log.debug("EndDraw failed (0x{x}), rebuilding device", .{@as(u32, @bitCast(hr))});
            self.rebuildGpu() catch {
                log.err("device rebuild failed", .{});
                return false;
            };
            return true;
        }
        // frame → 交换链后缓冲整体 blit：非脏区来自持久帧缓冲，翻转双缓冲下也全局一致。
        if (self.frame_bitmap) |fb| {
            const dpi = 96.0 * self.dpi_scale;
            const dest = d2d.common.D2D_RECT_F{
                .left = 0,
                .top = 0,
                .right = @as(f32, @floatFromInt(self.px_width)) / self.dpi_scale,
                .bottom = @as(f32, @floatFromInt(self.px_height)) / self.dpi_scale,
            };
            const src = d2d.common.D2D_RECT_F{
                .left = 0,
                .top = 0,
                .right = @floatFromInt(self.px_width),
                .bottom = @floatFromInt(self.px_height),
            };
            dc.SetTarget(&self.target_bitmap.?.ID2D1Image);
            dc.ID2D1RenderTarget.SetDpi(dpi, dpi);
            dc.ID2D1RenderTarget.BeginDraw();
            dc.ID2D1RenderTarget.DrawBitmap(&fb.ID2D1Bitmap, &dest, 1.0, .LINEAR, &src);
            const hr2 = dc.ID2D1RenderTarget.EndDraw(null, null);
            if (hr2.failed) {
                log.debug("blit EndDraw failed (0x{x}), rebuilding device", .{@as(u32, @bitCast(hr2))});
                self.rebuildGpu() catch {
                    log.err("device rebuild failed", .{});
                    return false;
                };
                return true;
            }
        }
        // Present(1)：对齐下一 v-sync（§5.6 高刷标准做法，避免撕裂并帧对齐刷新）。
        const pr = self.swap_chain.?.IDXGISwapChain.Present(1, 0);
        if (pr.failed) {
            log.debug("Present failed (0x{x}), rebuilding device", .{@as(u32, @bitCast(pr))});
            self.rebuildGpu() catch {
                log.err("device rebuild failed", .{});
                return false;
            };
            return true;
        }
        return false;
    }

    /// 整建 GPU 管线（设备丢失/断连：D3D11 设备 + 交换链 + D2D 设备 + render target）。
    fn rebuildGpu(self: *Device) !void {
        self.releaseGpu();
        try self.createGpuPipeline();
        try self.createRenderTarget();
    }

    /// 释放设备与全部缓存（GPU 管线 / render target / brush / 工厂）。
    pub fn deinit(self: *Device) void {
        // releaseGpu 释放 GPU 管线、surface、brush 与 path geometry（保留 text 系统/dwrite 工厂）。
        self.releaseGpu();
        self.brush_cache.deinit();
        self.surface_brush.deinit();
        _ = self.dwrite_factory.IUnknown.Release();
        const a = self.allocator;
        a.destroy(self);
    }
};

test "render device module compiles" {
    // render 依赖真实 Win32/D3D11/D2D，无法在 CI 单测；此处仅确保类型可引用。
    _ = Device;
    _ = cache.BrushCache;
}
