//! platform/clipboard.zig —— 剪贴板（规则 §5.11）。
//!
//! 模块不变量：
//! - OpenClipboard 失败重试 10 次 × 10ms（剪贴板争用是常态）；超时返回 error，不 panic；
//! - 只承诺 CF_UNICODETEXT；
//! - 写入先 Empty 再 Set，防句柄泄漏；
//! - 读取做 UTF-16→UTF-8 转换并按 API 契约拷贝给调用方。

const std = @import("std");
const w32 = @import("win32.zig");
const node = @import("../core/node.zig");
const log = std.log.scoped(.clipboard);

const RETRY_COUNT = 10;
const RETRY_DELAY_MS = 10;

/// 打开剪贴板（带重试）。成功后调用方必须 CloseClipboard。
fn open() !void {
    var i: usize = 0;
    while (i < RETRY_COUNT) : (i += 1) {
        if (w32.user32.OpenClipboard(null) != 0) return;
        w32.kernel32.Sleep(RETRY_DELAY_MS);
    }
    log.err("OpenClipboard busy after {d} retries", .{RETRY_COUNT});
    return error.ClipboardBusy;
}

/// 读取剪贴板文本（UTF-8，调用方 free）。无文本返回 error.NoClipboardText。
pub fn read(allocator: std.mem.Allocator) ![]const u8 {
    try open();
    defer _ = w32.user32.CloseClipboard();

    const h_handle = w32.user32.GetClipboardData(@intFromEnum(w32.system_ole.CF_UNICODETEXT)) orelse return error.NoClipboardText;
    const hmem: isize = @bitCast(@intFromPtr(h_handle));
    const size = w32.kernel32.GlobalSize(hmem);
    if (size < 2) return error.NoClipboardText;

    const ptr = w32.kernel32.GlobalLock(hmem) orelse return error.LockFailed;
    defer _ = w32.kernel32.GlobalUnlock(hmem);

    const utf16: [*]const u16 = @ptrCast(@alignCast(ptr));
    const chars = size / @sizeOf(u16);
    const all = utf16[0..chars];
    const text16 = if (std.mem.indexOfScalar(u16, all, 0)) |nul| all[0..nul] else all;
    return std.unicode.utf16LeToUtf8Alloc(allocator, text16);
}

/// 写入剪贴板文本（UTF-8）。失败返回 error（不 panic）。
pub fn write(allocator: std.mem.Allocator, text: []const u8) !void {
    try open();
    defer _ = w32.user32.CloseClipboard();

    const utf16 = try std.unicode.utf8ToUtf16LeAlloc(allocator, text);
    defer allocator.free(utf16);
    const byte_len = (utf16.len + 1) * @sizeOf(u16); // 结尾 NUL

    // 移动内存块；SetClipboardData 成功后句柄归系统（owned=false），失败须 GlobalFree。
    const h = w32.kernel32.GlobalAlloc(.{ .MEM_MOVEABLE = 1 }, byte_len);
    if (h == 0) return error.AllocFailed;
    var owned = true;
    defer {
        if (owned) _ = w32.kernel32.GlobalFree(h);
    }

    const ptr = w32.kernel32.GlobalLock(h) orelse return error.LockFailed;
    defer _ = w32.kernel32.GlobalUnlock(h);
    const dst: [*]u8 = @ptrCast(@alignCast(ptr));
    @memcpy(dst[0 .. utf16.len * @sizeOf(u16)], std.mem.sliceAsBytes(utf16));
    @memset(dst[utf16.len * @sizeOf(u16) .. byte_len], 0);

    // 写入先 Empty 再 Set，防句柄泄漏（§5.11）。
    _ = w32.user32.EmptyClipboard();
    const h_handle: w32.foundation.HANDLE = @ptrFromInt(@as(usize, @bitCast(h)));
    if (w32.user32.SetClipboardData(@intFromEnum(w32.system_ole.CF_UNICODETEXT), h_handle) == null) {
        return error.SetClipboardFailed;
    }
    owned = false; // 句柄已由系统接管。
}

// —— core.Clipboard 接口适配（§5.11）：window.run 装配到 tree.clipboard ——

var clipboard_sentinel: u8 = 0;

/// 装配为 core 的 Clipboard 接口（widgets 层的 Edit 经 tree.clipboard 调用）。
pub fn asClipboard() node.Clipboard {
    return .{
        .vtable = &.{ .read = implRead, .write = implWrite },
        .impl = &clipboard_sentinel, // 实现不依赖实例状态。
    };
}

fn implRead(impl: *anyopaque, allocator: std.mem.Allocator) ?[]const u8 {
    _ = impl;
    return read(allocator) catch null;
}

fn implWrite(impl: *anyopaque, text: []const u8) void {
    _ = impl;
    _ = write(std.heap.page_allocator, text) catch {};
}
