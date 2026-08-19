//! render/cache.zig —— 对象缓存（规则 §5.6 强制）。
//!
//! 模块不变量：
//! - brush 按颜色惰性缓存；绘制循环里现建 D2D 对象是禁止的（§5.6）；
//! - 设备丢失重建 render target 时必须 reset（旧 brush 绑定旧 target）；
//! - 键 = 颜色（packed u32），值与 D2D_COLOR_F 内存布局一致。

const std = @import("std");
const win32 = @import("../platform/win32.zig");
const d2d = win32.direct2d;
const theme = @import("../theme.zig");

/// 颜色 → 实心画刷 缓存。
pub const BrushCache = struct {
    allocator: std.mem.Allocator,
    factory: *d2d.ID2D1Factory,
    map: std.hash_map.AutoHashMap(u32, *d2d.ID2D1SolidColorBrush),
    /// 当前绑定的 render target（brush 由其创建，绑定时记录）。
    rt: ?*d2d.ID2D1RenderTarget = null,

    pub fn init(allocator: std.mem.Allocator, factory: *d2d.ID2D1Factory) BrushCache {
        return .{
            .allocator = allocator,
            .factory = factory,
            .map = std.hash_map.AutoHashMap(u32, *d2d.ID2D1SolidColorBrush).init(allocator),
        };
    }

    pub fn deinit(self: *BrushCache) void {
        self.reset();
        self.map.deinit();
    }

    /// 设备丢失后调用：释放全部 brush。
    pub fn reset(self: *BrushCache) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            _ = entry.value_ptr.*.IUnknown.Release();
        }
        self.map.clearRetainingCapacity();
        self.rt = null;
    }

    /// 取（或惰性创建）指定颜色的画刷。绘制路径专用。
    pub fn brushFor(self: *BrushCache, rt: *d2d.ID2D1RenderTarget, color: theme.Color) ?*d2d.ID2D1SolidColorBrush {
        // 目标换了 → 全部失效（设备丢失/重建路径已 reset；此处防御）。
        if (self.rt != null and self.rt.? != rt) self.reset();
        self.rt = rt;

        const key = packColor(color);
        if (self.map.get(key)) |b| return b;

        const d2d_color = d2d.common.D2D_COLOR_F{ .r = color.r, .g = color.g, .b = color.b, .a = color.a };
        var brush: *d2d.ID2D1SolidColorBrush = undefined;
        const hr = rt.CreateSolidColorBrush(&d2d_color, null, &brush);
        if (hr.failed) return null;
        self.map.put(key, brush) catch {
            _ = brush.IUnknown.Release();
            return null;
        };
        return brush;
    }
};

/// 颜色压成 u32 键（RGBA 各 8bit，近似即可；不同色必不同键）。
fn packColor(c: theme.Color) u32 {
    const r: u32 = @intFromFloat(@min(255, @max(0, c.r * 255.0)));
    const g: u32 = @intFromFloat(@min(255, @max(0, c.g * 255.0)));
    const b: u32 = @intFromFloat(@min(255, @max(0, c.b * 255.0)));
    const a: u32 = @intFromFloat(@min(255, @max(0, c.a * 255.0)));
    return (a << 24) | (r << 16) | (g << 8) | b;
}

test "brush cache key packs color uniquely" {
    const c1 = theme.Color.rgb(1, 0, 0);
    const c2 = theme.Color.rgb(0, 1, 0);
    try std.testing.expect(packColor(c1) != packColor(c2));
    try std.testing.expect(packColor(c1) == packColor(c1));
}
