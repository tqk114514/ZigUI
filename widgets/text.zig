//! widgets/text.zig —— Text 控件行为（measure/paint 自由函数）。
//!
//! 模块不变量：
//! - 纯行为，数据在 core/widget.zig 的 Text；
//! - measure 经 Tree.text_system（§5.7）取文本 bounds；无 text_system 时按零尺寸；
//! - paint 只在内容区画文本，颜色取 theme token（L9）；
//! - 帧路径零分配：本文件不分配（TextLayout 由 text_system 缓存持有）。

const geo = @import("../core/geometry.zig");
const layout = @import("../core/layout.zig");
const node = @import("../core/node.zig");
const painter = @import("../core/painter.zig");
const widget = @import("../core/widget.zig");
const theme = @import("../theme.zig");

/// 求文本固有尺寸：loosen 约束 → text_system.layout 取 bounds。
pub fn measure(tree: *node.Tree, d: widget.Text, c: layout.Constraints) geo.Size {
    if (tree.text_system) |ts| {
        const opts = painter.TextLayoutOptions{ .wrap = d.wrap, .ellipsis = d.ellipsis };
        if (ts.layout(d.text, &tree.theme_ref.font_ui, c.max.width, opts)) |tl| {
            return .{ .width = tl.bounds.width, .height = tl.bounds.height };
        }
    }
    return .{};
}

/// 在 rect 内容区内绘制文本（顶对齐、左对齐）。
pub fn paint(tree: *node.Tree, pc: painter.PaintCtx, rect: geo.Rect, d: widget.Text) void {
    if (d.text.len == 0) return;
    if (tree.text_system) |ts| {
        // 用 rect 宽度换行约束；wrap/ellipsis 由控件数据决定（M4）。
        const opts = painter.TextLayoutOptions{ .wrap = d.wrap, .ellipsis = d.ellipsis };
        if (ts.layout(d.text, &tree.theme_ref.font_ui, rect.w, opts)) |tl| {
            pc.drawText(rect, tl, tree.theme_ref.text);
        }
    }
}

const std = @import("std");

/// 测试用假 TextSystem：固定尺寸。
const MockTs = struct {
    layout: painter.TextLayout,
    fn layoutImpl(impl: *anyopaque, _: []const u8, _: *const theme.Font, _: f32, _: painter.TextLayoutOptions) ?*painter.TextLayout {
        const self: *MockTs = @ptrCast(@alignCast(impl));
        return &self.layout;
    }
};

test "text measure with mocked text system" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try node.Tree.init(arena.allocator(), &theme.light);
    defer t.deinit();

    // 注入假 TextSystem：固定 100×20。
    var mock = MockTs{ .layout = .{ .bounds = .{ .width = 100, .height = 20 } } };
    t.text_system = .{ .vtable = &.{ .layout = &MockTs.layoutImpl }, .impl = &mock };

    const s = measure(&t, .{ .text = "hello" }, .{ .max = .{ .width = 1000, .height = 1000 } });
    try std.testing.expect(geo.approxEq(100, s.width));
    try std.testing.expect(geo.approxEq(20, s.height));
}
