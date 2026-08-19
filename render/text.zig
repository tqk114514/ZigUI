//! render/text.zig —— TextSystem 的 DWrite 实现（规则 §5.7）。
//!
//! 模块不变量：
//! - layout(text, font, max_width, options) → TextLayout，稳态命中缓存（L4）；
//! - 两级缓存：TextFormat 按（字族+字号+字重）缓存（theme 字体槽极少，无界）；
//!   TextLayout 按（文本+字体+宽度+wrap/ellipsis）LRU，内存预算按物理内存自适应（§5.6）；
//! - wrap/ellipsis 在 TextLayout 级设置，不污染缓存的 TextFormat（避免键冲突）；
//! - 缓存命中率经 debug 开关周期性输出（§8.5）；
//! - 中文/拉丁 fallback 由 DWrite 系统字体集合自动处理（M2 DoD）。
//!
//! 设计注记（M7 稳定化）：本文件与 render/cache.zig（BrushCache）均为专用对象缓存。
//! 后续图标/位图/Geometry 缓存将复用同一套治理（预算 + LRU + 逐出钩子），届时
//! 提取通用对象缓存容器（泛型 Key→Entry），TextLayout/Brush/Bitmap 均以其为实例。
//! 现在先做专用，避免过早抽象（§4 避免过度工程）。

const std = @import("std");
const win32 = @import("../platform/win32.zig");
const dw = win32.direct_write;
const painter = @import("../core/painter.zig");
const theme = @import("../theme.zig");

const log = std.log.scoped(.text);

/// TextLayout 缓存预算（§5.6 有界缓存）。默认按系统物理内存比例自适应
/// （业界 Chromium/WebKit 风格），而非固定值：大内存机器缓存自动变大。
/// 注：上/下限是"防失控护栏"，不是性能目标——文本可见工作集仅数 MB，
/// 128MB 已覆盖任何复杂 UI。精确比例与上限留待 M7 统一对象缓存容器时
/// 一并评估调优（届时文本/位图/图标共用一套预算治理，此处不单独优化）。
const DEFAULT_BUDGET_MIN: usize = 8 * 1024 * 1024; // 8MB 下限（小内存兜底）
const DEFAULT_BUDGET_MAX: usize = 128 * 1024 * 1024; // 128MB 上限（防失控）
/// 预算比例 = 物理内存 × 0.5%（1/200）。
const BUDGET_FRACTION: usize = 200;
/// 每条目固定开销（TextLayout 对象 + 键 + 节点 + 链表）。
const ENTRY_BASE_BYTES: usize = 4096;
/// 每 UTF-8 字节的估算开销（UTF-16 转换 + shaping 结构，粗估）。
const TEXT_BYTES_PER_CHAR: usize = 64;

/// 粗估条目内存（缓存治理用，无需精确）。
fn entrySize(text_len: usize) usize {
    return ENTRY_BASE_BYTES + text_len * TEXT_BYTES_PER_CHAR;
}

/// 默认预算：clamp(物理内存 / 200, 8MB, 128MB)。读取失败回退下限。
fn defaultBudgetBytes() usize {
    var ms: win32.system_information.MEMORYSTATUSEX = undefined;
    ms.dwLength = @sizeOf(win32.system_information.MEMORYSTATUSEX);
    if (win32.kernel32.GlobalMemoryStatusEx(&ms) == 0) return DEFAULT_BUDGET_MIN;
    const budget = ms.ullTotalPhys / BUDGET_FRACTION;
    return std.math.clamp(budget, DEFAULT_BUDGET_MIN, DEFAULT_BUDGET_MAX);
}

/// DWrite TextSystem 实现。持有工厂与两级缓存。
pub const TextSystemImpl = struct {
    allocator: std.mem.Allocator,
    factory: *dw.IDWriteFactory,
    /// TextFormat 按（字族+字号+字重）缓存。数量少（theme 两槽），无界。
    format_cache: std.StringHashMapUnmanaged(*dw.IDWriteTextFormat) = .empty,
    /// TextLayout LRU：StringHashMap（键 → 节点）+ 双向链表（头 = 最近使用）。
    layout_map: std.StringHashMapUnmanaged(*LayoutNode) = .empty,
    layout_head: ?*LayoutNode = null,
    layout_tail: ?*LayoutNode = null,
    layout_count: usize = 0,
    /// 当前占用字节（估算）。超出 budget 时 LRU 驱逐最旧。
    used_bytes: usize = 0,
    /// 内存预算（字节）：init 时由物理内存比例算定，内部定值、不可配置。
    budget: usize = undefined,
    /// 命中率统计（§8.5 debug 输出）。
    hits: u64 = 0,
    misses: u64 = 0,

    /// 装配入口：预算按系统物理内存比例算定（§5.6），内部定值。
    pub fn init(allocator: std.mem.Allocator, factory: *dw.IDWriteFactory) TextSystemImpl {
        return .{
            .allocator = allocator,
            .factory = factory,
            .budget = defaultBudgetBytes(),
        };
    }

    /// 缓存条目：TextLayout（core 契约）+ DWrite 对象指针。
    pub const LayoutEntry = struct {
        tl: painter.TextLayout,
        dw_layout: *dw.IDWriteTextLayout,
        /// ellipsis 的修剪符号（若有）。随条目释放，避免悬垂/泄漏。
        ellipsis_sign: ?*dw.IDWriteInlineObject = null,
    };

    const LayoutNode = struct {
        key: []const u8, // map 键（本模块拥有，驱逐/销毁时释放）
        entry: *LayoutEntry,
        prev: ?*LayoutNode,
        next: ?*LayoutNode,
        /// 估算字节（驱逐时从 used_bytes 扣减）。
        size: usize,
    };

    pub fn layout(self: *TextSystemImpl, text: []const u8, font: *const theme.Font, max_width: f32, options: painter.TextLayoutOptions) ?*painter.TextLayout {
        const key = cacheKey(self.allocator, text, font, max_width, options) catch return null;
        // 命中：移链表头（LRU 保序），释放临时键。
        if (self.layout_map.get(key)) |node| {
            self.hits += 1;
            self.allocator.free(key);
            self.moveToHead(node);
            return &node.entry.tl;
        }
        self.misses += 1;
        const tl = self.createAndCache(key, text, font, max_width, options) catch {
            self.allocator.free(key);
            return null;
        };
        self.logStatsMaybe();
        return tl;
    }

    /// 创建并缓存（失败返回 error，key 由调用方负责释放）。
    fn createAndCache(self: *TextSystemImpl, key: []const u8, text: []const u8, font: *const theme.Font, max_width: f32, options: painter.TextLayoutOptions) !*painter.TextLayout {
        const fmt = self.formatFor(font) orelse return error.FormatFailed;

        const utf16 = try std.unicode.utf8ToUtf16LeAlloc(self.allocator, text);
        defer self.allocator.free(utf16);
        const utf16_z = try self.allocator.dupeZ(u16, utf16);
        defer self.allocator.free(utf16_z);

        // —— 统一失败清理（成功时 linked=true 跳过）——
        var dw_layout: ?*dw.IDWriteTextLayout = null;
        var ellipsis_sign: ?*dw.IDWriteInlineObject = null;
        var entry: ?*LayoutEntry = null;
        var node: ?*LayoutNode = null;
        var linked = false;
        defer if (!linked) {
            if (node) |n| self.allocator.destroy(n);
            if (entry) |e| self.allocator.destroy(e);
            if (ellipsis_sign) |s| _ = s.IUnknown.Release();
            if (dw_layout) |l| _ = l.IUnknown.Release();
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

        entry = try self.allocator.create(LayoutEntry);
        entry.?.* = .{
            .tl = .{
                .bounds = .{ .width = bw, .height = metrics.height },
                .width_with_ws = metrics.widthIncludingTrailingWhitespace,
                .payload = raw_layout,
            },
            .dw_layout = raw_layout,
            .ellipsis_sign = ellipsis_sign,
        };

        node = try self.allocator.create(LayoutNode);
        node.?.* = .{ .key = key, .entry = entry.?, .prev = null, .next = null, .size = entrySize(text.len) };
        try self.layout_map.put(self.allocator, key, node.?); // 失败：node 未入链表
        self.linkHead(node.?); // 成功后才链接
        linked = true;

        self.layout_count += 1;
        self.used_bytes += node.?.size;
        // 超预算：LRU 驱逐最旧直到 fit（内存有界，§5.6）。
        while (self.used_bytes > self.budget and self.layout_tail != null) self.evict();
        return &entry.?.tl;
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

    // —— LRU 链表操作 ——

    fn linkHead(self: *TextSystemImpl, node: *LayoutNode) void {
        node.prev = null;
        node.next = self.layout_head;
        if (self.layout_head) |h| h.prev = node;
        self.layout_head = node;
        if (self.layout_tail == null) self.layout_tail = node;
    }

    fn moveToHead(self: *TextSystemImpl, node: *LayoutNode) void {
        if (self.layout_head == node) return;
        // 摘除
        if (node.prev) |p| p.next = node.next else self.layout_head = node.next;
        if (node.next) |n| n.prev = node.prev else self.layout_tail = node.prev;
        self.linkHead(node);
    }

    fn evict(self: *TextSystemImpl) void {
        const t = self.layout_tail orelse return;
        const size = t.size; // destroy 前先取（避免 UAF）
        // 摘除尾
        if (t.prev) |p| p.next = null else self.layout_head = null;
        self.layout_tail = t.prev;
        _ = self.layout_map.remove(t.key);
        // 释放
        _ = t.entry.dw_layout.IUnknown.Release();
        if (t.entry.ellipsis_sign) |s| _ = s.IUnknown.Release();
        self.allocator.destroy(t.entry);
        self.allocator.free(t.key);
        self.allocator.destroy(t);
        self.layout_count -= 1;
        self.used_bytes -= size;
    }

    // —— 统计（§8.5 debug 开关）——

    fn logStatsMaybe(self: *TextSystemImpl) void {
        const total = self.hits + self.misses;
        if (total > 0 and total % 50_000 == 0) {
            const rate: f64 = @as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(total)) * 100.0;
            log.debug("text cache: {d}/{d} hits ({d:.1}%), {d} entries, {d:.1} MB / {d:.1} MB", .{
                self.hits,                                            total,                                            rate, self.layout_count,
                @as(f64, @floatFromInt(self.used_bytes)) / 1048576.0, @as(f64, @floatFromInt(self.budget)) / 1048576.0,
            });
        }
    }

    pub fn deinit(self: *TextSystemImpl) void {
        // 释放全部 TextLayout（entry + key + node）。
        var it = self.layout_map.iterator();
        while (it.next()) |e| {
            const n = e.value_ptr.*;
            _ = n.entry.dw_layout.IUnknown.Release();
            if (n.entry.ellipsis_sign) |s| _ = s.IUnknown.Release();
            self.allocator.destroy(n.entry);
            self.allocator.free(e.key_ptr.*);
            self.allocator.destroy(n);
        }
        self.layout_map.deinit(self.allocator);
        // 释放 TextFormat。
        var fit = self.format_cache.iterator();
        while (fit.next()) |e| {
            _ = e.value_ptr.*.IUnknown.Release();
            self.allocator.free(e.key_ptr.*);
        }
        self.format_cache.deinit(self.allocator);
        // 命中率汇总。
        if (self.hits + self.misses > 0) {
            const rate: f64 = @as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(self.hits + self.misses)) * 100.0;
            log.debug("text cache deinit: {d} hits / {d} misses ({d:.1}%)", .{ self.hits, self.misses, rate });
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

/// TextLayout 缓存键：文本 + 字族 + 字号位 + 字重 + 宽度位 + wrap/ellipsis。
/// 单行且不省略时 max_width 不影响 bounds，键不依赖它（拖拽 resize 时保持命中，M4）。
/// 独立函数便于单测（不依赖 DWrite）。
fn cacheKey(allocator: std.mem.Allocator, text: []const u8, font: *const theme.Font, max_width: f32, options: painter.TextLayoutOptions) ![]const u8 {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, text);
    try buf.appendSlice(allocator, "|");
    try buf.appendSlice(allocator, font.family);
    try buf.appendSlice(allocator, "|");
    const fs: u32 = @bitCast(font.size);
    const mw: u32 = @bitCast(if (options.wrap or options.ellipsis) max_width else 0);
    var tmp: [96]u8 = undefined;
    const suffix = try std.fmt.bufPrint(&tmp, "{d}|{d}|{x}|{d}|{d}", .{
        @intFromEnum(font.weight),
        fs,
        mw,
        @intFromBool(options.wrap),
        @intFromBool(options.ellipsis),
    });
    try buf.appendSlice(allocator, suffix);
    return buf.toOwnedSlice(allocator);
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

// 供 Device 装配：把 TextSystemImpl 暴露为 core 的 TextSystem 接口。
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
    // 单行（无 wrap/ellipsis）：max_width 不影响 bounds → 键与宽度无关（resize 命中）。
    const k1 = try cacheKey(std.testing.allocator, "abc", &f, 100, .{});
    defer std.testing.allocator.free(k1);
    const k2 = try cacheKey(std.testing.allocator, "abc", &f, 200, .{});
    defer std.testing.allocator.free(k2);
    try std.testing.expect(std.mem.eql(u8, k1, k2));

    // wrap：宽度敏感。
    const k3 = try cacheKey(std.testing.allocator, "abc", &f, 100, .{ .wrap = true });
    defer std.testing.allocator.free(k3);
    const k4 = try cacheKey(std.testing.allocator, "abc", &f, 200, .{ .wrap = true });
    defer std.testing.allocator.free(k4);
    try std.testing.expect(!std.mem.eql(u8, k3, k4));
    try std.testing.expect(!std.mem.eql(u8, k1, k3)); // wrap 不同 → 键不同

    // ellipsis：宽度敏感且与单行不同。
    const k5 = try cacheKey(std.testing.allocator, "abc", &f, 100, .{ .ellipsis = true });
    defer std.testing.allocator.free(k5);
    try std.testing.expect(!std.mem.eql(u8, k1, k5));

    // 文本不同 → 键不同。
    const k6 = try cacheKey(std.testing.allocator, "abd", &f, 100, .{});
    defer std.testing.allocator.free(k6);
    try std.testing.expect(!std.mem.eql(u8, k1, k6));
}

test "text format cache key ignores wrap/ellipsis" {
    const f = theme.Font{ .family = "Microsoft YaHei UI", .size = 13.0, .weight = .regular };
    const k1 = try formatKey(std.testing.allocator, &f);
    defer std.testing.allocator.free(k1);
    try std.testing.expect(std.mem.eql(u8, k1, "Microsoft YaHei UI|400|1095761920")); // size 13.0 bitCast
}
