//! zigui —— Windows 单平台、保留模式、全自绘的轻量现代 UI 工具包。
//! 本文件是唯一公共 API 出口（规则 §3），其他文件的 pub 一律视为 internal。
//!
//! 模块不变量（M0 阶段）：
//! - 仅 re-export 公共 API，不在此实现逻辑；
//! - core/ 不得 import 平台/渲染模块（L1），此处同样不触碰 win32。
//!
//! 现状：M0 骨架，尚未开放任何控件 API；窗口能力经 platform/ 提供。

const std = @import("std");

/// 库版本，与 build.zig.zon 保持一致。
pub const version: std.SemanticVersion = .{ .major = 0, .minor = 0, .patch = 0 };

/// 主题 token（light / dark），纯数据。（§5.2）
pub const theme = @import("theme.zig");

/// 核心模型（M1）：纯净逻辑，可脱离 Windows 单测。
pub const core = struct {
    pub const geometry = @import("core/geometry.zig");
    pub const layout = @import("core/layout.zig");
    pub const widget = @import("core/widget.zig");
    pub const node = @import("core/node.zig");
    pub const event = @import("core/event.zig");
    pub const painter = @import("core/painter.zig");
};

/// 控件行为层（M2 起）：dispatch 表 + 各控件行为。
pub const widgets = struct {
    pub const dispatch = @import("widgets/dispatch.zig");
    pub const text = @import("widgets/text.zig");
    pub const button = @import("widgets/button.zig");
    pub const builder = @import("widgets/builder.zig");
};

/// 渲染层（M2）：D2D/DWrite 实现。
pub const render = struct {
    pub const device = @import("render/device.zig");
    pub const cache = @import("render/cache.zig");
    pub const text = @import("render/text.zig");
    pub const painter = @import("render/painter.zig");
};

/// 平台层：窗口/消息泵。M0 仅开放最小窗口能力。
pub const platform = struct {
    pub const window = @import("platform/window.zig");
    pub const input = @import("platform/input.zig");
    pub const post = @import("platform/post.zig");
};

/// Ui 句柄：跨线程任务桥（§5.12）。`Ui.post` 是唯一可从任意线程调用的 API（L7 例外）。
/// 从 window.run 获取；post 保证 FIFO + happens-before + 消息泵线程执行。
pub const Ui = platform.post.PostBridge;

// 计划中的公共出口（M1 起逐步开放）：
//   pub const Tree   = core.node.Tree;
//   pub const Widget = core.widget.Widget;
//   ...

test "ui: version is readable" {
    try std.testing.expectEqual(@as(u8, 0), version.major);
}

// 确保所有 core 模块的 test 块被收集进测试二进制（惰性 import 需要显式引用）。
test "collect all core module tests" {
    _ = @import("theme.zig");
    _ = @import("core/geometry.zig");
    _ = @import("core/layout.zig");
    _ = @import("core/widget.zig");
    _ = @import("core/node.zig");
    _ = @import("core/event.zig");
    _ = @import("core/painter.zig");
    _ = @import("widgets/dispatch.zig");
    _ = @import("widgets/text.zig");
    _ = @import("widgets/button.zig");
    _ = @import("render/cache.zig");
    _ = @import("render/text.zig");
    _ = @import("platform/input.zig");
    _ = @import("platform/post.zig");
    _ = @import("platform/window.zig");
}
