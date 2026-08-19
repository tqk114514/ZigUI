//! render/text.zig —— TextSystem 的 DWrite 实现（规则 §5.7）。
//!
//! 模块不变量：
//! - layout(text, font, max_width) → TextLayout，稳态命中缓存（L4）；
//! - 中文/拉丁 fallback 由 DWrite 系统字体集合自动处理（M2 DoD）；
//! - TextLayout 缓存键 = 文本 + 字号 + 字重 + 最大宽度；
//! - 缓存无界（M4 收敛为 LRU 256，§5.6）。

const std = @import("std");
const win32 = @import("../platform/win32.zig");
const dw = win32.direct_write;
const painter = @import("../core/painter.zig");
const theme = @import("../theme.zig");

const log = std.log.scoped(.text);

/// DWrite TextSystem 实现。持有工厂与缓存。
pub const TextSystemImpl = struct {
    allocator: std.mem.Allocator,
    factory: *dw.IDWriteFactory,
    /// 按 UTF-8 文本 + 尺寸键缓存 TextLayout（payload = IDWriteTextLayout）。
    cache: std.StringHashMapUnmanaged(*LayoutEntry) = .empty,

    /// 缓存条目：TextLayout（core 契约）+ DWrite 对象指针。
    pub const LayoutEntry = struct {
        tl: painter.TextLayout,
        dw_layout: *dw.IDWriteTextLayout,
    };

    pub fn layout(self: *TextSystemImpl, text: []const u8, font: *const theme.Font, max_width: f32) ?*painter.TextLayout {
        // 缓存键：text + 字号/字重/宽度（M4 收敛 LRU 上限）。
        const key = self.cacheKey(text, font, max_width) catch return null;
        if (self.cache.get(key)) |e| return &e.tl;

        // 创建 DWrite layout。
        const utf16 = std.unicode.utf8ToUtf16LeAlloc(self.allocator, text) catch return null;
        defer self.allocator.free(utf16);
        const utf16_z = self.allocator.dupeZ(u16, utf16) catch return null;
        defer self.allocator.free(utf16_z);

        // 字体族名（UTF-8）→ 零结尾 UTF-16（CreateTextFormat 用）。
        const family_utf16 = std.unicode.utf8ToUtf16LeAlloc(self.allocator, font.family) catch return null;
        defer self.allocator.free(family_utf16);
        const family_z = self.allocator.dupeZ(u16, family_utf16) catch return null;
        defer self.allocator.free(family_z);

        var fmt: *dw.IDWriteTextFormat = undefined;
        var hr = self.factory.CreateTextFormat(
            family_z,
            null,
            fontWeight(font.weight),
            .NORMAL,
            .NORMAL,
            font.size,
            std.unicode.utf8ToUtf16LeStringLiteral("zh-CN").ptr,
            &fmt,
        );
        if (hr.failed) {
            log.warn("CreateTextFormat failed", .{});
            return null;
        }
        defer _ = fmt.IUnknown.Release();

        // 单行：不换行。
        _ = fmt.SetWordWrapping(.NO_WRAP);

        const w = if (max_width > 0) max_width else 1_000_000.0;
        var dw_layout: *dw.IDWriteTextLayout = undefined;
        hr = self.factory.CreateTextLayout(
            utf16_z,
            @intCast(utf16.len),
            fmt,
            w,
            1_000_000.0,
            &dw_layout,
        );
        if (hr.failed) {
            log.warn("CreateTextLayout failed", .{});
            return null;
        }

        var metrics: dw.DWRITE_TEXT_METRICS = undefined;
        _ = dw_layout.GetMetrics(&metrics);

        const entry = self.allocator.create(LayoutEntry) catch {
            _ = dw_layout.IUnknown.Release();
            return null;
        };
        entry.* = .{
            .tl = .{
                .bounds = .{ .width = metrics.width, .height = metrics.height },
                .payload = dw_layout,
            },
            .dw_layout = dw_layout,
        };
        // 缓存无界（M4 收敛）。
        self.cache.put(self.allocator, key, entry) catch {
            _ = dw_layout.IUnknown.Release();
            self.allocator.destroy(entry);
            return null;
        };
        return &entry.tl;
    }

    /// 绘制文本：origin 为 DIP 坐标（render/painter 直接调 DrawTextLayout，此方法备用）。
    pub fn draw(self: *TextSystemImpl, tl: *const painter.TextLayout, origin: win32.direct2d.common.D2D_POINT_2F) void {
        _ = self;
        const entry: *LayoutEntry = @fieldParentPtr("tl", @constCast(tl));
        _ = entry.dw_layout.Draw(null, null, origin.x, origin.y);
    }

    fn cacheKey(self: *TextSystemImpl, text: []const u8, font: *const theme.Font, max_width: f32) ![]const u8 {
        // 简单拼接：text + 分隔符 + 字号位 + 字重位 + 宽度位（M4 换 LRU 结构化键）。
        var buf = std.ArrayListUnmanaged(u8).empty;
        defer buf.deinit(self.allocator);
        try buf.appendSlice(self.allocator, text);
        try buf.appendSlice(self.allocator, "|");
        const fs: u32 = @bitCast(font.size);
        const mw: u32 = @bitCast(max_width);
        var tmp: [64]u8 = undefined;
        const suffix = try std.fmt.bufPrint(&tmp, "{d}|{d}|{x}", .{ @intFromEnum(font.weight), fs, mw });
        try buf.appendSlice(self.allocator, suffix);
        return buf.toOwnedSlice(self.allocator);
    }

    pub fn deinit(self: *TextSystemImpl) void {
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            _ = entry.value_ptr.*.dw_layout.IUnknown.Release();
            self.allocator.destroy(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.cache.deinit(self.allocator);
    }
};

fn fontWeight(w: theme.Weight) dw.DWRITE_FONT_WEIGHT {
    return switch (w) {
        .thin => .THIN,
        .light => .LIGHT,
        .regular => .NORMAL,
        .medium => .MEDIUM,
        .semibold => .DEMI_BOLD,
        .bold => .BOLD,
    };
}

// 供 Device 装配：把 TextSystemImpl 暴露为 core 的 TextSystem 接口。
pub fn asTextSystem(impl: *TextSystemImpl) painter.TextSystem {
    return .{
        .vtable = &.{ .layout = &systemLayout },
        .impl = impl,
    };
}

fn systemLayout(impl: *anyopaque, text: []const u8, font: *const theme.Font, max_width: f32) ?*painter.TextLayout {
    const self: *TextSystemImpl = @ptrCast(@alignCast(impl));
    return self.layout(text, font, max_width);
}

test "text weight mapping" {
    try std.testing.expect(fontWeight(.regular) == .NORMAL);
    try std.testing.expect(fontWeight(.bold) == .BOLD);
    try std.testing.expect(fontWeight(.semibold) == .DEMI_BOLD);
}
