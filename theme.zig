//! theme.zig —— 扁平 token 集（规则 §5.2），纯数据，无行为。
//!
//! 模块不变量：
//! - 控件视觉只能取自此处 token，禁止硬编码颜色/字体/圆角/间距（L9）；
//! - 全部为 comptime 常量，跨窗口共享；树内不拷贝（§5.12）；
//! 8pt 网格：间距基准 = {4, 8, 12, 16, 24}。

const std = @import("std");

/// 线性 RGBA，分量 [0,1]。与渲染层 D2D1_COLOR_F 内存布局一致，
/// 但本文件保持纯数据，不触碰任何渲染类型。
pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32 = 1.0,

    pub fn rgb(r: f32, g: f32, b: f32) Color {
        return .{ .r = r, .g = g, .b = b };
    }
    pub fn rgba(r: f32, g: f32, b: f32, a: f32) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }
};

/// 字重。
pub const Weight = enum(u16) {
    thin = 100,
    light = 300,
    regular = 400,
    medium = 500,
    semibold = 600,
    bold = 700,
};

/// 字体槽位。
pub const Font = struct {
    /// 字族名称，固定于 theme 内。UI 字体用"Microsoft YaHei UI"（中文+拉丁 fallback），
    /// 等宽字体用"Consolas"。family 指向 comptime 字面量，静态存活。
    family: []const u8,
    size: f32,
    weight: Weight = .regular,
};

/// 圆角与间距基准（8pt 网格）。
pub const Radius = struct {
    small: f32 = 4.0,
    medium: f32 = 8.0,
    large: f32 = 12.0,
};

pub const Spacing = struct {
    xxs: f32 = 4.0,
    xs: f32 = 8.0,
    sm: f32 = 12.0,
    md: f32 = 16.0,
    lg: f32 = 24.0,
};

/// 两套预设：light 与 dark。所有字段扁平化，控件直接按需取。
pub const Theme = struct {
    name: []const u8,

    // 背景系列
    bg_window: Color,
    bg_surface: Color,
    bg_hover: Color,
    bg_pressed: Color,
    border: Color,

    // 文本
    text: Color,
    text_weak: Color,
    selection_bg: Color,

    // 强调
    accent: Color,
    accent_text: Color,
    // 危险
    danger: Color,

    // 字体槽位
    font_ui: Font,
    font_mono: Font,

    // 几何
    radius: Radius,
    spacing: Spacing,
};

pub const light = Theme{
    .name = "light",
    .bg_window = Color.rgb(0.96, 0.96, 0.97),
    .bg_surface = Color.rgb(1.00, 1.00, 1.00),
    .bg_hover = Color.rgb(0.90, 0.90, 0.92),
    .bg_pressed = Color.rgb(0.84, 0.84, 0.87),
    .border = Color.rgb(0.80, 0.80, 0.83),
    .text = Color.rgb(0.11, 0.11, 0.12),
    .text_weak = Color.rgb(0.40, 0.40, 0.43),
    .selection_bg = Color.rgb(0.79, 0.88, 1.00),
    .accent = Color.rgb(0.24, 0.45, 0.85),
    .accent_text = Color.rgb(1.00, 1.00, 1.00),
    .danger = Color.rgb(0.80, 0.20, 0.20),
    .font_ui = .{ .family = "Microsoft YaHei UI", .size = 13.0 },
    .font_mono = .{ .family = "Consolas", .size = 13.0 },
    .radius = .{},
    .spacing = .{},
};

pub const dark = Theme{
    .name = "dark",
    .bg_window = Color.rgb(0.11, 0.11, 0.12),
    .bg_surface = Color.rgb(0.16, 0.16, 0.18),
    .bg_hover = Color.rgb(0.22, 0.22, 0.24),
    .bg_pressed = Color.rgb(0.28, 0.28, 0.31),
    .border = Color.rgb(0.30, 0.30, 0.33),
    .text = Color.rgb(0.93, 0.93, 0.94),
    .text_weak = Color.rgb(0.62, 0.62, 0.65),
    .selection_bg = Color.rgb(0.16, 0.30, 0.58),
    .accent = Color.rgb(0.30, 0.52, 0.92),
    .accent_text = Color.rgb(0.06, 0.06, 0.07),
    .danger = Color.rgb(0.85, 0.40, 0.40),
    .font_ui = .{ .family = "Microsoft YaHei UI", .size = 13.0 },
    .font_mono = .{ .family = "Consolas", .size = 13.0 },
    .radius = .{},
    .spacing = .{},
};

test "theme: tokens are finite and in range" {
    const themes = [_]Theme{ light, dark };
    for (themes) |t| {
        try std.testing.expect(t.bg_window.a == 1.0);
        try std.testing.expect(t.font_ui.size > 0);
        try std.testing.expect(t.font_mono.size > 0);
        try std.testing.expect(t.radius.small > 0);
        // 纹理色 alpha 均在 [0,1]。
        try std.testing.expect(t.accent.a >= 0.0 and t.accent.a <= 1.0);
    }
    try std.testing.expect(std.mem.eql(u8, light.name, "light"));
    try std.testing.expect(std.mem.eql(u8, dark.name, "dark"));
}
