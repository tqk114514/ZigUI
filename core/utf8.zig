//! core/utf8.zig —— 码点边界步进工具（规则 §5.8 Edit 规格）。
//!
//! 模块不变量：
//! - Edit 的 caret / anchor 只允许落在码点边界（用本模块步进，禁止裸 +1）；
//! - 纯函数、零分配、可脱离 Windows 单测；
//! - 输入视为合法 UTF-8（Edit 保证 buf 始终合法，§5.8）。

const std = @import("std");

/// 从字节偏移 i 前进一个码点（i 须在码点边界）。返回新偏移（clamp 到 len）。
pub fn nextCodepoint(text: []const u8, i: usize) usize {
    if (i >= text.len) return text.len;
    const len = std.unicode.utf8ByteSequenceLength(text[i]) catch return i + 1;
    return @min(text.len, i + len);
}

/// 从字节偏移 i 后退一个码点（i 须在码点边界）。返回新偏移。
pub fn prevCodepoint(text: []const u8, i: usize) usize {
    if (i == 0) return 0;
    var j = i - 1;
    // 跳过 continuation bytes（0x10xxxxxx），定位序列首字节。
    while (j > 0 and (text[j] & 0xC0) == 0x80) j -= 1;
    return j;
}

/// 字节偏移 i 是否落在码点边界（buf 合法 UTF-8 时，非 continuation 即边界）。
pub fn isBoundary(text: []const u8, i: usize) bool {
    if (i >= text.len) return true;
    return (text[i] & 0xC0) != 0x80;
}

/// 把偏移 i 夹到最近的码点边界（防御：caret 不应落入序列中间）。
pub fn clampToBoundary(text: []const u8, i: usize) usize {
    const n = @min(i, text.len);
    var j = n;
    // 若 j 指向 continuation（落在序列中间），回退到该码点首字节。
    while (j > 0 and j < text.len and (text[j] & 0xC0) == 0x80) j -= 1;
    return j;
}

/// 码点数。
pub fn count(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch 0;
}

test "next/prev step over ascii and multi-byte" {
    // "a中b"：a=E2? no, 中=E4 B8 AD。
    const text = "a中b";
    try std.testing.expectEqual(@as(usize, 1), nextCodepoint(text, 0)); // a → 1
    try std.testing.expectEqual(@as(usize, 4), nextCodepoint(text, 1)); // 中(3B) → 4
    try std.testing.expectEqual(@as(usize, 5), nextCodepoint(text, 4)); // b → 5
    try std.testing.expectEqual(@as(usize, 5), nextCodepoint(text, 5)); // 尾 → 尾

    try std.testing.expectEqual(@as(usize, 0), prevCodepoint(text, 1)); // 1 → 0
    try std.testing.expectEqual(@as(usize, 1), prevCodepoint(text, 4)); // 4 → 1
    try std.testing.expectEqual(@as(usize, 4), prevCodepoint(text, 5)); // 5 → 4
    try std.testing.expectEqual(@as(usize, 0), prevCodepoint(text, 0)); // 头 → 头
}

test "boundary and clamp" {
    const text = "a中b";
    try std.testing.expect(isBoundary(text, 0));
    try std.testing.expect(isBoundary(text, 1));
    try std.testing.expect(!isBoundary(text, 2)); // 中 的 continuation
    try std.testing.expect(!isBoundary(text, 3));
    try std.testing.expect(isBoundary(text, 4));
    try std.testing.expect(isBoundary(text, 5));

    try std.testing.expectEqual(@as(usize, 1), clampToBoundary(text, 2)); // 中序列中间 → 中开头(1)
    try std.testing.expectEqual(@as(usize, 1), clampToBoundary(text, 3));
    try std.testing.expectEqual(@as(usize, 4), clampToBoundary(text, 4)); // b 首字节 → 原样
    try std.testing.expectEqual(@as(usize, 5), clampToBoundary(text, 99)); // 越界 → len
}

test "codepoint count" {
    try std.testing.expectEqual(@as(usize, 3), count("a中b"));
    try std.testing.expectEqual(@as(usize, 0), count(""));
}
