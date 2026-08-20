//! render/text.zig —— TextSystem 的 DWrite 实现（规则 §5.7）。
//!
//! 模块不变量：
//! - layout(text, font, max_width, options) → TextLayout，稳态命中缓存（L4）；
//! - 两级缓存：TextFormat 按（字族+字号+字重）缓存（theme 字体槽极少，无界）；
//!   TextLayout 按（文本+字体+宽度+wrap/ellipsis）LRU，内存预算按物理内存自适应（§5.6）；
//! - wrap/ellipsis 在 TextLayout 级设置，不污染缓存的 TextFormat（避免键冲突）；
//! - 缓存命中率经 debug 开关周期性输出（§8.5）；
//! - 中文/拉丁 fallback 由 DWrite 系统字体集合自动处理。
//!
//! 设计注记：TextLayout 缓存复用 render/cache.zig 的通用 ObjectCache（预算/LRU/驱逐统一）。

const std = @import("std");
const win32 = @import("../platform/win32.zig");
const dw = win32.direct_write;
const painter = @import("../core/painter.zig");
const theme = @import("../theme.zig");
const cache_mod = @import("cache.zig");

const log = std.log.scoped(.text);

/// TextLayout 条目内存估算（预算治理用，无需精确）。
const ENTRY_BASE_BYTES: usize = 4096;
const TEXT_BYTES_PER_CHAR: usize = 64;

/// 缓存键栈缓冲容量：覆盖常见短文本键（帧路径零分配，L4）；超长才走堆。
const KEY_STACK_CAP: usize = 256;

/// 粗估条目内存（缓存治理用，无需精确）。
fn entrySize(text_len: usize) usize {
    return ENTRY_BASE_BYTES + text_len * TEXT_BYTES_PER_CHAR;
}

/// DWrite TextSystem 实现。持有工厂与两级缓存。
pub const TextSystemImpl = struct {
    /// 分配器（页面级，缓存键/条目归属）。
    allocator: std.mem.Allocator,
    /// DWrite 工厂（线程安全）。
    factory: *dw.IDWriteFactory,
    /// TextFormat 按（字族+字号+字重）缓存。数量少（theme 两槽），无界。
    format_cache: std.StringHashMapUnmanaged(*dw.IDWriteTextFormat) = .empty,
    /// TextLayout 缓存：基于通用 ObjectCache（LRU + 内存预算自适应，§5.6）。
    layouts: cache_mod.ObjectCache(LayoutEntry, TextLayoutCtx),

    /// 装配入口：预算按系统物理内存比例算定（§5.6），内部定值。
    pub fn init(allocator: std.mem.Allocator, factory: *dw.IDWriteFactory) TextSystemImpl {
        return .{
            .allocator = allocator,
            .factory = factory,
            .layouts = cache_mod.ObjectCache(LayoutEntry, TextLayoutCtx).init(allocator, cache_mod.defaultBudgetBytes()),
        };
    }

    /// 缓存条目：TextLayout（core 契约）+ DWrite 对象指针。
    pub const LayoutEntry = struct {
        /// core 契约的 TextLayout（bounds + payload 指向下方 DWrite 对象）。
        tl: painter.TextLayout,
        /// DWrite 布局对象（随条目释放）。
        dw_layout: *dw.IDWriteTextLayout,
        /// ellipsis 的修剪符号（若有）。随条目释放，避免悬垂/泄漏。
        ellipsis_sign: ?*dw.IDWriteInlineObject = null,
    };

    /// 文本条目生命周期钩子（ObjectCache Ctx）：key 堆化、驱逐时释放 COM 对象。
    pub const TextLayoutCtx = struct {
        pub fn dupKey(a: std.mem.Allocator, key: []const u8) ![]const u8 {
            return a.dupe(u8, key);
        }
        pub fn freeKey(a: std.mem.Allocator, owned: []const u8) void {
            a.free(owned);
        }
        pub fn destroyValue(a: std.mem.Allocator, owned_key: []const u8, value: *LayoutEntry) void {
            _ = value.dw_layout.IUnknown.Release();
            if (value.ellipsis_sign) |s| _ = s.IUnknown.Release();
            a.free(owned_key);
        }
    };

    pub fn layout(self: *TextSystemImpl, text: []const u8, font: *const theme.Font, max_width: f32, options: painter.TextLayoutOptions) ?*painter.TextLayout {
        // 键优先写入栈缓冲：measure/paint 是帧路径（L4），缓存命中零分配。
        var stack_key: [KEY_STACK_CAP]u8 = undefined;
        const key = cacheKey(&stack_key, self.allocator, text, font, max_width, options) catch return null;
        // 命中：容器内移链表头（LRU 保序），释放临时堆键（栈键无需释放）。
        if (self.layouts.get(key.data)) |e| {
            if (key.heap) self.allocator.free(key.data);
            return &e.tl;
        }
        // miss：构造条目后交由容器缓存（容器内 dupKey 持久化 key）。
        const value = self.createValue(text, font, max_width, options) catch {
            if (key.heap) self.allocator.free(key.data);
            return null;
        };
        const e = self.layouts.add(key.data, value, entrySize(text.len)) catch {
            self.destroyValue(value);
            if (key.heap) self.allocator.free(key.data);
            return null;
        };
        if (key.heap) self.allocator.free(key.data);
        self.logStatsMaybe();
        return &e.tl;
    }

    /// 释放一个未入缓存的 LayoutEntry 内部 COM 对象（add 失败回滚用）。
    fn destroyValue(self: *TextSystemImpl, value: LayoutEntry) void {
        _ = self;
        _ = value.dw_layout.IUnknown.Release();
        if (value.ellipsis_sign) |s| _ = s.IUnknown.Release();
    }

    /// 创建 TextLayout 条目（失败返回 error，调用方不拥有任何已分配资源）。
    fn createValue(self: *TextSystemImpl, text: []const u8, font: *const theme.Font, max_width: f32, options: painter.TextLayoutOptions) !LayoutEntry {
        const fmt = self.formatFor(font) orelse return error.FormatFailed;

        const utf16 = try std.unicode.utf8ToUtf16LeAlloc(self.allocator, text);
        defer self.allocator.free(utf16);
        const utf16_z = try self.allocator.dupeZ(u16, utf16);
        defer self.allocator.free(utf16_z);

        // —— 统一失败清理（成功时返回前把所有权交出）——
        var dw_layout: ?*dw.IDWriteTextLayout = null;
        var ellipsis_sign: ?*dw.IDWriteInlineObject = null;
        defer if (dw_layout != null) {
            if (ellipsis_sign) |s| _ = s.IUnknown.Release();
            _ = dw_layout.?.IUnknown.Release();
        };

        const w = if (max_width > 0) max_width else 1_000_000.0;
        var raw_layout: *dw.IDWriteTextLayout = undefined;
        const hr = self.factory.CreateTextLayout(utf16_z, @intCast(utf16.len), fmt, w, 1_000_000.0, &raw_layout);
        if (hr.failed) {
            log.warn("CreateTextLayout failed", .{});
            return error.CreateLayoutFailed;
        }
        dw_layout = raw_layout;

        // wrap/ellipsis：经内嵌基类 IDWriteTextFormat 接口设置（COM 继承），
        // 不污染缓存的 TextFormat（§5.6 键稳定）。
        _ = raw_layout.IDWriteTextFormat.SetWordWrapping(if (options.wrap) .WRAP else .NO_WRAP);

        // ellipsis：单行尾部省略（DWrite trimming）。
        if (options.ellipsis) {
            var trimming = dw.DWRITE_TRIMMING{ .granularity = .CHARACTER, .delimiter = 0, .delimiterCount = 0 };
            var sign: *dw.IDWriteInlineObject = undefined;
            if (!self.factory.CreateEllipsisTrimmingSign(fmt, &sign).failed) {
                _ = raw_layout.IDWriteTextFormat.SetTrimming(&trimming, sign);
                ellipsis_sign = sign;
            }
        }

        var metrics: dw.DWRITE_TEXT_METRICS = undefined;
        _ = raw_layout.GetMetrics(&metrics);
        var bw = metrics.width;
        // ellipsis 且超宽：实际显示宽度不超过 max_width（measure 消费）。
        if (options.ellipsis and max_width > 0 and bw > max_width) bw = max_width;

        // 所有权转交返回：清除 defer 的释放标记。
        const out = LayoutEntry{
            .tl = .{
                .bounds = .{ .width = bw, .height = metrics.height },
                .width_with_ws = metrics.widthIncludingTrailingWhitespace,
                .payload = raw_layout,
            },
            .dw_layout = raw_layout,
            .ellipsis_sign = ellipsis_sign,
        };
        dw_layout = null;
        ellipsis_sign = null;
        return out;
    }

    // —— TextFormat 缓存（按 字族+字号+字重）——

    fn formatFor(self: *TextSystemImpl, font: *const theme.Font) ?*dw.IDWriteTextFormat {
        const key = formatKey(self.allocator, font) catch return null;
        if (self.format_cache.get(key)) |f| {
            self.allocator.free(key);
            return f;
        }
        const family_utf16 = std.unicode.utf8ToUtf16LeAlloc(self.allocator, font.family) catch {
            self.allocator.free(key);
            return null;
        };
        defer self.allocator.free(family_utf16);
        const family_z = self.allocator.dupeZ(u16, family_utf16) catch {
            self.allocator.free(key);
            return null;
        };
        defer self.allocator.free(family_z);

        var fmt: *dw.IDWriteTextFormat = undefined;
        const hr = self.factory.CreateTextFormat(
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
            self.allocator.free(key);
            return null;
        }
        self.format_cache.put(self.allocator, key, fmt) catch {
            _ = fmt.IUnknown.Release();
            self.allocator.free(key);
            return null;
        };
        return fmt;
    }

    // —— 统计（§8.5 debug 开关）——

    fn logStatsMaybe(self: *TextSystemImpl) void {
        const total = self.layouts.hits + self.layouts.misses;
        if (total > 0 and total % 50_000 == 0) {
            const rate: f64 = @as(f64, @floatFromInt(self.layouts.hits)) / @as(f64, @floatFromInt(total)) * 100.0;
            log.debug("text cache: {d}/{d} hits ({d:.1}%), {d} entries, {d:.1} MB / {d:.1} MB", .{
                self.layouts.hits,                                            total,                                                    rate, self.layouts.count,
                @as(f64, @floatFromInt(self.layouts.used_bytes)) / 1048576.0, @as(f64, @floatFromInt(self.layouts.budget)) / 1048576.0,
            });
        }
    }

    pub fn deinit(self: *TextSystemImpl) void {
        // 释放全部 TextLayout（ObjectCache 统一 handle）。
        self.layouts.deinit();
        // 释放 TextFormat。
        var fit = self.format_cache.iterator();
        while (fit.next()) |e| {
            _ = e.value_ptr.*.IUnknown.Release();
            self.allocator.free(e.key_ptr.*);
        }
        self.format_cache.deinit(self.allocator);
        // 命中率汇总。
        if (self.layouts.hits + self.layouts.misses > 0) {
            const rate: f64 = @as(f64, @floatFromInt(self.layouts.hits)) / @as(f64, @floatFromInt(self.layouts.hits + self.layouts.misses)) * 100.0;
            log.debug("text cache deinit: {d} hits / {d} misses ({d:.1}%)", .{ self.layouts.hits, self.layouts.misses, rate });
        }
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

/// 缓存键描述：data 可能指向调用方栈缓冲或堆；heap=true 需释放。
const CacheKey = struct {
    data: []const u8,
    heap: bool,
};

/// TextLayout 缓存键：文本 + 字族 + 字号位 + 字重 + 宽度位 + wrap/ellipsis。
/// 单行且不省略时 max_width 不影响 bounds，键不依赖它（拖拽 resize 时保持命中）。
/// 优先写入调用方栈缓冲（帧路径零分配，L4），超长才走堆。
/// 独立函数便于单测（不依赖 DWrite）。
fn cacheKey(buf: *[KEY_STACK_CAP]u8, allocator: std.mem.Allocator, text: []const u8, font: *const theme.Font, max_width: f32, options: painter.TextLayoutOptions) !CacheKey {
    var tmp: [96]u8 = undefined;
    const suffix = try std.fmt.bufPrint(&tmp, "{d}|{d}|{x}|{d}|{d}", .{
        @intFromEnum(font.weight),
        @as(u32, @bitCast(font.size)),
        @as(u32, @bitCast(if (options.wrap or options.ellipsis) max_width else 0)),
        @intFromBool(options.wrap),
        @intFromBool(options.ellipsis),
    });
    const total = text.len + 1 + font.family.len + 1 + suffix.len;
    if (total <= KEY_STACK_CAP) {
        var w: usize = 0;
        @memcpy(buf[0..text.len], text);
        w += text.len;
        buf[w] = '|';
        w += 1;
        @memcpy(buf[w .. w + font.family.len], font.family);
        w += font.family.len;
        buf[w] = '|';
        w += 1;
        @memcpy(buf[w .. w + suffix.len], suffix);
        w += suffix.len;
        return .{ .data = buf[0..w], .heap = false };
    }
    // 超长回退：堆构建（调用方/缓存负责释放）。
    var list = std.ArrayListUnmanaged(u8).empty;
    defer list.deinit(allocator);
    try list.appendSlice(allocator, text);
    try list.append(allocator, '|');
    try list.appendSlice(allocator, font.family);
    try list.append(allocator, '|');
    try list.appendSlice(allocator, suffix);
    return .{ .data = try list.toOwnedSlice(allocator), .heap = true };
}

/// TextFormat 缓存键：字族 + 字号位 + 字重（不含 wrap/ellipsis——layout 级覆盖）。
fn formatKey(allocator: std.mem.Allocator, font: *const theme.Font) ![]const u8 {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, font.family);
    try buf.appendSlice(allocator, "|");
    const fs: u32 = @bitCast(font.size);
    var tmp: [64]u8 = undefined;
    const suffix = try std.fmt.bufPrint(&tmp, "{d}|{d}", .{ @intFromEnum(font.weight), fs });
    try buf.appendSlice(allocator, suffix);
    return buf.toOwnedSlice(allocator);
}

/// 装配为 core 的 TextSystem 接口（window.run 调用）。
pub fn asTextSystem(impl: *TextSystemImpl) painter.TextSystem {
    return .{
        .vtable = &.{ .layout = &systemLayout },
        .impl = impl,
    };
}

fn systemLayout(impl: *anyopaque, text: []const u8, font: *const theme.Font, max_width: f32, options: painter.TextLayoutOptions) ?*painter.TextLayout {
    const self: *TextSystemImpl = @ptrCast(@alignCast(impl));
    return self.layout(text, font, max_width, options);
}

test "text weight mapping" {
    try std.testing.expect(fontWeight(.regular) == .NORMAL);
    try std.testing.expect(fontWeight(.bold) == .BOLD);
    try std.testing.expect(fontWeight(.semibold) == .DEMI_BOLD);
}

test "text layout cache key: single-line ignores width; wrap/ellipsis sensitive" {
    const f = theme.Font{ .family = "Consolas", .size = 13.0, .weight = .regular };
    // 每个键独立栈缓冲（共享缓冲会互相覆盖）。
    var b1: [KEY_STACK_CAP]u8 = undefined;
    var b2: [KEY_STACK_CAP]u8 = undefined;
    var b3: [KEY_STACK_CAP]u8 = undefined;
    var b4: [KEY_STACK_CAP]u8 = undefined;
    var b5: [KEY_STACK_CAP]u8 = undefined;
    var b6: [KEY_STACK_CAP]u8 = undefined;
    // 单行（无 wrap/ellipsis）：max_width 不影响 bounds → 键与宽度无关（resize 命中）。
    const k1 = try cacheKey(&b1, std.testing.allocator, "abc", &f, 100, .{});
    const k2 = try cacheKey(&b2, std.testing.allocator, "abc", &f, 200, .{});
    try std.testing.expect(std.mem.eql(u8, k1.data, k2.data));
    // 短文本走栈缓冲（帧路径零分配）。
    try std.testing.expect(!k1.heap);

    // wrap：宽度敏感。
    const k3 = try cacheKey(&b3, std.testing.allocator, "abc", &f, 100, .{ .wrap = true });
    const k4 = try cacheKey(&b4, std.testing.allocator, "abc", &f, 200, .{ .wrap = true });
    try std.testing.expect(!std.mem.eql(u8, k3.data, k4.data));
    try std.testing.expect(!std.mem.eql(u8, k1.data, k3.data)); // wrap 不同 → 键不同

    // ellipsis：宽度敏感且与单行不同。
    const k5 = try cacheKey(&b5, std.testing.allocator, "abc", &f, 100, .{ .ellipsis = true });
    try std.testing.expect(!std.mem.eql(u8, k1.data, k5.data));

    // 文本不同 → 键不同。
    const k6 = try cacheKey(&b6, std.testing.allocator, "abd", &f, 100, .{});
    try std.testing.expect(!std.mem.eql(u8, k1.data, k6.data));
}

test "text format cache key ignores wrap/ellipsis" {
    const f = theme.Font{ .family = "Microsoft YaHei UI", .size = 13.0, .weight = .regular };
    const k1 = try formatKey(std.testing.allocator, &f);
    defer std.testing.allocator.free(k1);
    try std.testing.expect(std.mem.eql(u8, k1, "Microsoft YaHei UI|400|1095761920")); // size 13.0 bitCast
}
