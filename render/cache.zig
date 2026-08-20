//! render/cache.zig —— 对象缓存（规则 §5.6 强制）。
//!
//! 模块不变量：
//! - 有界对象一律走 ObjectCache：外部 key + LRU 顺序 + 内存预算 + 驱逐钩子（§5.6）；
//! - 绘制循环里现建 D2D 对象是禁止的（§5.6）；
//! - Key 由调用方构造（TextLayout 栈缓冲帧路径零分配 L4 / Brush 颜色 u32）；
//!   ObjectCache 只负责存储、LRU、预算驱逐，不掺 key 语义；
//! - Value 由调用方经 Ctx.dupKey/destroyValue 管理生命周期（COM Release 等）；
//! - 设备丢失重建 render target 时必须 reset（旧 brush 绑定旧 target）；
//! - 预算默认按物理内存比例自适应（§5.6；TextLayout/Brush 共享）。

const std = @import("std");
const win32 = @import("../platform/win32.zig");
const d2d = win32.direct2d;
const theme = @import("../theme.zig");

/// 预算比例 = 物理内存 × 0.5%（1/200）。
const BUDGET_FRACTION: usize = 200;
/// 预算下限（小内存兜底）。
const BUDGET_MIN: usize = 8 * 1024 * 1024;
/// 预算上限（防失控护栏）。
const BUDGET_MAX: usize = 128 * 1024 * 1024;

/// 默认内存预算：clamp(物理内存 / 200, 8MB, 128MB)。读取失败回退下限。
pub fn defaultBudgetBytes() usize {
    var ms: win32.system_information.MEMORYSTATUSEX = undefined;
    ms.dwLength = @sizeOf(win32.system_information.MEMORYSTATUSEX);
    if (win32.kernel32.GlobalMemoryStatusEx(&ms) == 0) return BUDGET_MIN;
    const budget = ms.ullTotalPhys / BUDGET_FRACTION;
    return std.math.clamp(budget, BUDGET_MIN, BUDGET_MAX);
}

/// 通用有界对象缓存：StringHashMap(owned key → Node) + 双向链表 LRU。
///
/// 泛型参数：
/// - Value：缓存条目的实体类型（如 TextLayout 的 LayoutEntry、Brush 的刷子指针）；
/// - Ctx：管理 key/Value 生命周期的静态命名空间，必须提供：
///   - `dupKey(allocator, key: []const u8) ![]const u8` —— 构建持久 owned key（miss 时调用）；
///   - `freeKey(allocator, owned: []const u8) void` —— 释放 owned key；
///   - `destroyValue(allocator, owned_key: []const u8, value: *Value) void` —— 释放
///     Value 内部资源（COM Release 等）并 freeKey（驱逐/清理时调用）。
///
/// Key 由调用方构造并传入查询（get 不拥有；超长走堆的临时 key 由调用方负责释放）。
/// size 由调用方按资源特性估算，add 时一并计入；超出 budget 时 LRU 驱逐最旧。
pub fn ObjectCache(comptime Value: type, comptime Ctx: type) type {
    return struct {
        const Self = @This();

        const Node = struct {
            key: []const u8, // owned，由 Ctx.dupKey 建、Ctx.freeKey 释
            value: Value,
            size: usize,
            prev: ?*Node,
            next: ?*Node,
        };

        allocator: std.mem.Allocator,
        map: std.StringHashMapUnmanaged(*Node) = .empty,
        head: ?*Node = null,
        tail: ?*Node = null,
        count: usize = 0,
        used_bytes: usize = 0,
        budget: usize,
        hits: u64 = 0,
        misses: u64 = 0,

        /// 构造缓存。budget 通常取 defaultBudgetBytes()（§5.6），也可按资源覆盖。
        pub fn init(allocator: std.mem.Allocator, budget: usize) Self {
            return .{ .allocator = allocator, .budget = budget };
        }

        /// 查询：命中移链表头（LRU 保序）。不拥有 key，命中后的堆 key 由调用方释放。
        pub fn get(self: *Self, key: []const u8) ?*Value {
            if (self.map.get(key)) |n| {
                self.hits += 1;
                self.moveToHead(n);
                return &n.value;
            }
            return null;
        }

        /// 插入（假定 miss，调用方已 get 确认）。内部 dupKey 持久化 key 并接管 Value；
        /// 失败返回 error，Value 与临时 key 均未接管。返回缓存内 Value 指针。
        pub fn add(self: *Self, key: []const u8, value: Value, size: usize) !*Value {
            const owned = Ctx.dupKey(self.allocator, key) catch return error.DupKeyFailed;
            const n = self.allocator.create(Node) catch {
                Ctx.freeKey(self.allocator, owned);
                return error.OutOfMemory;
            };
            n.* = .{ .key = owned, .value = value, .size = size, .prev = null, .next = null };
            self.map.put(self.allocator, owned, n) catch {
                Ctx.freeKey(self.allocator, owned);
                self.allocator.destroy(n);
                return error.MapInsertFailed;
            };
            self.linkHead(n);
            self.count += 1;
            self.used_bytes += size;
            self.misses += 1;
            // 超预算：LRU 驱逐最旧直到 fit（内存有界，§5.6）。
            while (self.used_bytes > self.budget and self.tail != null) self.evict();
            return &n.value;
        }

        /// 释放全部条目并清空（设备丢失 reset / deinit 共用）；保留 map 容量。
        pub fn clearAll(self: *Self) void {
            var it = self.map.iterator();
            while (it.next()) |e| {
                const n = e.value_ptr.*;
                Ctx.destroyValue(self.allocator, n.key, &n.value);
                self.allocator.destroy(n);
            }
            self.map.clearRetainingCapacity();
            self.head = null;
            self.tail = null;
            self.count = 0;
            self.used_bytes = 0;
        }

        /// 释放全部条目并销毁 map（整桶销毁）。
        pub fn deinit(self: *Self) void {
            self.clearAll();
            self.map.deinit(self.allocator);
        }

        fn linkHead(self: *Self, node: *Node) void {
            node.prev = null;
            node.next = self.head;
            if (self.head) |h| h.prev = node;
            self.head = node;
            if (self.tail == null) self.tail = node;
        }

        fn moveToHead(self: *Self, node: *Node) void {
            if (self.head == node) return;
            if (node.prev) |p| p.next = node.next else self.head = node.next;
            if (node.next) |n| n.prev = node.prev else self.tail = node.prev;
            self.linkHead(node);
        }

        fn evict(self: *Self) void {
            const t = self.tail orelse return;
            const size = t.size; // destroy 前先取（避免 UAF）
            if (t.prev) |p| p.next = null else self.head = null;
            self.tail = t.prev;
            _ = self.map.remove(t.key);
            Ctx.destroyValue(self.allocator, t.key, &t.value);
            self.allocator.destroy(t);
            self.count -= 1;
            self.used_bytes -= size;
        }
    };
}

const BrushCtx = struct {
    pub fn dupKey(a: std.mem.Allocator, key: []const u8) ![]const u8 {
        return a.dupe(u8, key);
    }
    pub fn freeKey(a: std.mem.Allocator, owned: []const u8) void {
        a.free(owned);
    }
    pub fn destroyValue(a: std.mem.Allocator, owned_key: []const u8, value: **d2d.ID2D1SolidColorBrush) void {
        _ = value.*.IUnknown.Release();
        a.free(owned_key);
    }
};

/// 颜色 → 实心画刷 缓存（基于 ObjectCache；颜色有限，预算默认足够故不驱逐）。
pub const BrushCache = struct {
    allocator: std.mem.Allocator,
    factory: *d2d.ID2D1Factory,
    /// 当前绑定的 render target（brush 由其创建，绑定时记录）。
    rt: ?*d2d.ID2D1RenderTarget = null,
    /// 底层通用对象缓存（key=颜色 4 字节，value=刷子指针）。
    entries: ObjectCache(*d2d.ID2D1SolidColorBrush, BrushCtx),

    /// 构造缓存。
    pub fn init(allocator: std.mem.Allocator, factory: *d2d.ID2D1Factory) BrushCache {
        return .{
            .allocator = allocator,
            .factory = factory,
            .entries = ObjectCache(*d2d.ID2D1SolidColorBrush, BrushCtx).init(allocator, defaultBudgetBytes()),
        };
    }

    /// 释放全部 brush 并销毁缓存。
    pub fn deinit(self: *BrushCache) void {
        self.entries.deinit();
    }

    /// 设备丢失后调用：释放全部 brush。
    pub fn reset(self: *BrushCache) void {
        self.entries.clearAll();
        self.rt = null;
    }

    /// 取（或惰性创建）指定颜色的画刷。绘制路径专用。
    pub fn brushFor(self: *BrushCache, rt: *d2d.ID2D1RenderTarget, color: theme.Color) ?*d2d.ID2D1SolidColorBrush {
        // 目标换了 → 全部失效（设备丢失/重建路径已 reset；此处防御）。
        if (self.rt != null and self.rt.? != rt) self.reset();
        self.rt = rt;

        const key = packColor(color);
        var bytes: [4]u8 = @bitCast(key);
        if (self.entries.get(&bytes)) |b| return b.*;

        const d2d_color = d2d.common.D2D_COLOR_F{ .r = color.r, .g = color.g, .b = color.b, .a = color.a };
        var brush: *d2d.ID2D1SolidColorBrush = undefined;
        const hr = rt.CreateSolidColorBrush(&d2d_color, null, &brush);
        if (hr.failed) return null;
        const vb = self.entries.add(&bytes, brush, @sizeOf(d2d.ID2D1SolidColorBrush)) catch {
            _ = brush.IUnknown.Release();
            return null;
        };
        return vb.*;
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

// —— ObjectCache 通用性测试（不依赖 DWrite，纯容器语义）——

const TestCtx = struct {
    fn dupKey(a: std.mem.Allocator, key: []const u8) ![]const u8 {
        return a.dupe(u8, key);
    }
    fn freeKey(a: std.mem.Allocator, owned: []const u8) void {
        a.free(owned);
    }
    fn destroyValue(a: std.mem.Allocator, owned_key: []const u8, value: *u32) void {
        _ = value;
        a.free(owned_key);
    }
};

test "object cache: LRU + budget eviction" {
    var cache = ObjectCache(u32, TestCtx).init(std.testing.allocator, 100); // 每条 40B，预算容 2 条
    defer cache.deinit();

    // 3 条 → 超出预算 → 驱逐最旧（a）。
    _ = try cache.add("a", @as(u32, 1), 40);
    _ = try cache.add("b", @as(u32, 2), 40);
    _ = try cache.add("c", @as(u32, 3), 40);
    try std.testing.expectEqual(@as(usize, 2), cache.count);
    try std.testing.expect(cache.get("a") == null); // 被驱逐
    try std.testing.expect(cache.get("c") != null);
    try std.testing.expect(cache.get("b") != null);

    // 命中后 b 移到头：再插入 d（40B）驱逐的是 c（LRU 最旧）。
    _ = try cache.add("d", @as(u32, 4), 40);
    try std.testing.expect(cache.get("c") == null); // LRU 最旧被驱逐
    try std.testing.expect(cache.get("b") != null);
    try std.testing.expect(cache.get("d") != null);
}

test "object cache: external key not owned, stats" {
    var cache = ObjectCache(u32, TestCtx).init(std.testing.allocator, 1000);
    defer cache.deinit();

    // 栈 key 首次 add（dupKey 拷贝）；get 命中用另一个等值 key 也可。
    _ = try cache.add("hello", @as(u32, 7), 10);
    try std.testing.expectEqual(@as(u64, 1), cache.misses);
    try std.testing.expect(cache.get("hello") != null);
    try std.testing.expectEqual(@as(u64, 1), cache.hits);
    try std.testing.expectEqual(@as(usize, 10), cache.used_bytes);
}
