//! core/widget.zig —— Widget tagged union 与各内建控件的**数据** struct（规则 §5.4）。
//!
//! 模块不变量：
//! - 本文件只有数据，无行为；paint/measure/事件处理在 widgets/*.zig（数据/行为分离）；
//! - 字符串一律为 `[]const u8` 切片，指向 Tree 的 arena（§4.3），本文件不拥有内存；
//! - 对 Widget union 的 switch 必须穷尽、禁 else（L8），由 widgets/dispatch.zig 保证；
//! - custom 变体是用户扩展唯一入口：ctx + vtable。

const std = @import("std");
const geo = @import("geometry.zig");
const layout = @import("layout.zig");
const theme = @import("../theme.zig");

/// 各内建控件的数据 struct —— 均为纯数据，字段语义见 §5 各节。
/// 纯布局容器，不绘制；无额外数据。
pub const Box = struct {};

/// 文本控件数据（含 wrap/ellipsis 选项与可选排版槽）。
pub const Text = struct {
    text: []const u8,
    /// 超出可用宽度时换行（多行）。默认单行不换行。
    wrap: bool = false,
    /// 超宽时尾部省略号（单行）。与 wrap 互斥。
    ellipsis: bool = false,
    /// 可选字体槽位（§5.2 排版层级 font_title/font_caption）。null = font_ui。
    font: ?theme.Font = null,
    /// 可选文本色（L9 token）。null = theme.text。
    color: ?theme.Color = null,
};

/// 按钮控件数据。
pub const Button = struct {
    label: []const u8,
};

/// 编辑框控件数据。
///
/// 状态机（§5.8）：
///   normal ↔ has_selection ↔ composing(IME)
/// - buf 始终合法 UTF-8；caret/anchor 只落在码点边界（core/utf8 步进）；
/// - composing 期间 buf 与 caret 冻结，组合串显示在 caret 处（带下划线）；
/// - 组合提交合并为一步 undo（M6：buf 快照式 undo/redo 栈，arena 切片引用）。
pub const Edit = struct {
    /// 缓冲区（arena，始终合法 UTF-8）。
    buf: []const u8 = "",
    /// 光标（字节偏移，码点边界）。
    caret: u32 = 0,
    /// 选区锚点（字节偏移，码点边界）。== caret 表示无选区（normal）。
    anchor: u32 = 0,
    /// IME 组合串（arena；composing 时非空）。
    compose_text: []const u8 = "",
    /// 是否 IME composing 中（buf/caret 冻结，§5.8）。
    composing: bool = false,
    /// 是否鼠标拖选中（pointer_down 置位，pointer_up 清除，§5.8）。
    dragging: bool = false,
    /// undo 栈（M6）：buf 快照 = arena 切片引用（旧 buf 在 arena 天然存活，O(1)/条）。
    /// 栈底 = 初始态，栈顶 = 最近一次编辑前的 buf。超上限丢弃最旧（§4.3 arena 语义）。
    undo: std.ArrayListUnmanaged([]const u8) = .empty,
    /// redo 栈（M6）：被撤销的 buf 快照；新编辑清空。
    redo: std.ArrayListUnmanaged([]const u8) = .empty,
    /// 内容区内边距（DIP）。widgets/edit.zig 与 platform/window.zig（IME caret 定位）共用。
    pub const pad_h: f32 = 8;
    pub const pad_v: f32 = 4;

    /// 是否有选区（anchor != caret）。
    pub fn hasSelection(self: Edit) bool {
        return self.anchor != self.caret;
    }
};

/// 滚动容器数据（M6）。
///
/// 状态机：
///   静止 → 滚动（滚轮 / Edit 拖选越界）→ 静止
/// - offset_y 为内容坐标偏移（DIP）；子节点 rect 在 arrange 时减去 offset_y（§6）；
/// - 滚动 = 改 offset_y + invalidateLayout 强制 arrange 重排（仅改显示不改尺寸，
///   传播终止 §5.5 的例外）；paint 由 clipIntersects 剔除视口外内容（§5.4）；
/// - content_h 在 arrange 时刷新（内容总高，钳制 offset 用）；
/// - v1 只做纵向（内容布局为 column）；TODO(v2)：水平滚动；
/// - 可视滚动条拇指（§6 P0-3）：thumb_drag / thumb_grab_off / thumb_hover 只由事件路径写（L6）；
///   几何经 thumbRect 供 paint 与 core 事件路由共用——拇指是**视口固定覆盖层**，不随内容滚。
pub const Scroll = struct {
    /// 内容坐标纵向偏移（DIP），恒 ≥ 0。
    offset_y: f32 = 0,
    /// 内容总高（DIP，含 padding），arrange 时刷新。
    content_h: f32 = 0,
    /// 拇指拖拽中（pointer_down 起、pointer_up 止，§6 P0-3）。
    thumb_drag: bool = false,
    /// 按下时指针在拇指内的纵向偏移（DIP）：拖动保持抓取点不跳变。
    thumb_grab_off: f32 = 0,
    /// 拇指悬停态（pointer_move 沿祖先更新；拇指非节点命中，Tree.hover 单值指针覆盖不到）。
    thumb_hover: bool = false,

    /// 拇指宽度（DIP；pub 供 paint 取圆角半径）。
    pub const thumb_w: f32 = 8;
    /// 拇指与视口右缘的小距离（DIP）：滚动条贴右缘但留一丝呼吸（区别于内容侧的 padding 节奏）。
    const thumb_margin: f32 = 2;
    /// 拇指最小高（DIP）：内容极多时保持可抓取。
    const thumb_min_h: f32 = 24;

    /// 内容避让道宽度（DIP，pub 供 core arrange/measure 收缩内容区）。
    /// 三段几何（P0-3 视觉节奏）：`左缘 ←A→ 内容 ←A→ 拇指 ←小距离→ 右缘`——内容与拇指的
    /// 间距 = A（= 右 padding，内容区本已内缩 padding 承担）；道宽只补"拇指宽 + 右缘小距离"
    ///（勿再叠加 padding：内容到拇指会变成 2×A）。
    pub fn laneWidth() f32 {
        return thumb_w + thumb_margin;
    }

    /// 拇指矩形（根空间 DIP；view = 视口即 n.rect.inset(padding)，pad_right = 自身右 padding）：
    /// 内容未超出视口返回 null。高 = 视口高² ÷ 内容高（下限 thumb_min_h、上限视口高）；
    /// y 随 offset 比例平移（行程 = 视口高 − 拇指高）；x 贴**节点外盒右缘**（n.rect 右缘 =
    /// view 右缘 + pad_right，即窗口右缘）留 thumb_margin 小距离——view 已内缩 padding，
    /// 直接贴 view 右缘会错位成"距窗口一个 padding + 缝隙"。
    pub fn thumbRect(self: Scroll, view: geo.Rect, pad_right: f32) ?geo.Rect {
        if (self.content_h <= view.h + 0.001) return null;
        const max_off = self.content_h - view.h;
        const frac = std.math.clamp(self.offset_y / max_off, 0, 1);
        const h = @min(@max(view.h * view.h / self.content_h, thumb_min_h), view.h);
        const travel = @max(0, view.h - h);
        return .{
            .x = view.x + view.w + pad_right - thumb_margin - thumb_w,
            .y = view.y + travel * frac,
            .w = thumb_w,
            .h = h,
        };
    }
};

/// 复选框数据（M6）。
///
/// 状态机：
///   unchecked ↔ checked；disabled 吸收一切输入。
/// - 切换由 pointer_up（框内按下+释放，click 语义）或聚焦时 Space 驱动（§5.8）；
/// - pointer_up 返回 false 让 click 冒泡给用户 handler（反应式展示，§6）；
/// - 勾选视觉 = accent 填充（无勾号原语；TODO(M7)：线/路径原语后补勾号）。
pub const Checkbox = struct {
    /// 是否勾选。
    checked: bool = false,
    /// 标签文本（arena）。
    label: []const u8 = "",
};

/// 滑块数据（M6）。
///
/// 状态机：
///   idle ↔ dragging（指针按下/拖动调值）。
/// - value 恒在 [min, max]；pointer_down/pointer_move 换算 x → value；
/// - pointer_up 返回 false 让 click 冒泡给用户 handler；
/// - v1 仅指针交互（TODO(M7)：键盘方向键调值）。
pub const Slider = struct {
    /// 当前值（DIP 无关，业务单位）。
    value: f32 = 0,
    /// 值域下界。
    min: f32 = 0,
    /// 值域上界。
    max: f32 = 100,
    /// 是否正在拖拽（pointer_down 置位，pointer_up 清除）。
    dragging: bool = false,
};

/// Tooltip 控件数据（P0-1 弹层体系最小切片）。
///
/// 状态机（P0-1，驱动源 = 指针 hover / Ticker 定时）：
///   hidden → pending（hover 停留锚节点，Ticker setTimeout 0.5s）→ showing → hidden
/// - 生命周期由 Controller（widgets/tooltip.zig）驱动；本 struct 只承载数据；
/// - 节点挂 Tree.overlay 顶层浮层槽：hand_rect 定位（不占布局）、pointer_pass 命中穿透；
/// - dismiss 触发：hover 离开锚 / 任一指针按下 / 窗口失焦 / resize（位置失效）。
pub const Tooltip = struct {
    /// 提示文本（arena）。
    text: []const u8,
    /// 内容区水平内边距（DIP，与 Edit 同节奏）。
    pub const pad_h: f32 = 8;
    /// 内容区垂直内边距（DIP）。
    pub const pad_v: f32 = 4;
};

/// custom 变体的 vtable：用户扩展入口（§5.4）。
pub const CustomVTable = struct {
    /// 在给定约束下返回固有尺寸。
    measure: *const fn (ctx: *anyopaque, c: layout.Constraints) geo.Size,
    /// 绘制自定义内容。可选（null = 不绘制）。
    paint: ?*const fn (ctx: *anyopaque, pc: *anyopaque) void = null,
    /// 自定义事件处理。可选（null = 不处理）。返回 true 停止冒泡。
    on_event: ?*const fn (ctx: *anyopaque, player_ctx: *anyopaque, e: *const @import("event.zig").Event) bool = null,
};

/// custom 变体数据：ctx 指针 + vtable（§5.4）。
pub const Custom = struct {
    /// 用户扩展实例指针（生命周期归用户，§5.12）。
    ctx: *anyopaque,
    /// 行为 vtable。
    vtable: *const CustomVTable,
};

/// Widget 为 tagged union（§5.4）。新增控件时编译器会指出所有漏改的穷尽 switch。
pub const Widget = union(enum) {
    none,
    box: Box,
    text: Text,
    button: Button,
    edit: Edit,
    scroll: Scroll,
    checkbox: Checkbox,
    slider: Slider,
    tooltip: Tooltip,
    custom: Custom,
};

/// 便捷：某节点是否可视为"空占位"（不参与绘制/命中）。
pub fn isNone(w: Widget) bool {
    return switch (w) {
        .none => true,
        else => false,
    };
}

test "widget union exhaustive switch compiles" {
    // 穷尽 switch（L8）：确保补全判空逻辑不会漏变体。
    const w: Widget = .box;
    const result = switch (w) {
        .none => 0,
        .box => 1,
        .text => 2,
        .button => 3,
        .edit => 4,
        .scroll => 5,
        .checkbox => 6,
        .slider => 7,
        .tooltip => 8,
        .custom => 9,
    };
    try std.testing.expect(result == 1);
    try std.testing.expect(!isNone(.box));
    try std.testing.expect(isNone(.none));
}
