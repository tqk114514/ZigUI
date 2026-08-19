//! examples/empty —— M0 骨架示例：打开并关闭一个空窗口，验证平台通路。
//! 每例一个概念（规则 §3）：本示例只演示"窗口可开可关"。

const std = @import("std");
const ui = @import("zigui");

pub fn main() anyerror!void {
    // 标题只在栈上短暂构造，run 结束即释放，不违反 §4.3 arena 规则。
    const title = std.unicode.utf8ToUtf16LeStringLiteral("zigui M0");
    _ = try ui.platform.window.run(.{ .title = title });
}
