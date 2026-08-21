//! widgets/edit.zig —— Edit 控件行为（§5.8 状态机 + measure/paint/onEvent）。
//!
//! 状态机（文件头，§5.8）：
//!   normal ↔ has_selection ↔ composing(IME)
//! - buf 始终合法 UTF-8；caret/anchor 只落在码点边界（core/utf8 步进，禁裸 +1）；
//! - composing 期间 buf 与 caret 冻结；组合串显示在 caret 处（下划线）；
//! - 组合提交合并为一步 undo（M6：buf 快照式 undo/redo 栈，arena 切片引用）；
//! - 拖选越界（Edit 在 scroll 容器内）自动滚动（§6 DoD）；
//! - hover 视觉：背景取 bg_hover（类似 checkbox，§6）；
//! - 视觉只取 theme token（L9）。
//!
//! 帧路径（measure/paint）零分配：composing 显示 = buf + 组合串分开 layout 绘制，
//! 不拼接缓冲（L4）；事件路径（onEvent）更新 buf 走 tree.arena（§4.3 允许）。

const std = @import("std");
const geo = @import("../core/geometry.zig");
const utf8 = @import("../core/utf8.zig");
const layout = @import("../core/layout.zig");
const node = @import("../core/node.zig");
const painter = @import("../core/painter.zig");
const widget = @import("../core/widget.zig");
const event = @import("../core/event.zig");
const scroll_mod = @import("scroll.zig");
const theme = @import("../theme.zig");

const pad_h: f32 = widget.Edit.pad_h;
const pad_v: f32 = widget.Edit.pad_v;
const caret_w: f32 = 1.5;

/// undo 栈上限（§4.3：arena 单调增长评估见 §9；超过丢弃最旧）。
const UNDO_MAX: usize = 100;

/// 固有尺寸：单行，高度 = 行高 + 上下 padding；宽度倾向占满（stretch）。
pub fn measure(tree: *node.Tree, d: widget.Edit, c: layout.Constraints) geo.Size {
    var line_h: f32 = 0;
    var content_w: f32 = 0;
    if (tree.text_system) |ts| {
        if (ts.layout(d.buf, &tree.theme_ref.font_ui, 1_000_000.0, .{})) |tl| {
            content_w += tl.bounds.width;
            line_h = @max(line_h, tl.bounds.height);
        }
        if (d.composing and d.compose_text.len > 0) {
            if (ts.layout(d.compose_text, &tree.theme_ref.font_ui, 1_000_000.0, .{})) |tl| {
                content_w += tl.bounds.width;
                line_h = @max(line_h, tl.bounds.height);
            }
        }
    }
    if (line_h <= 0) line_h = 20;
    const w: f32 = if (c.max.width < 1_000_000.0) c.max.width else content_w + pad_h * 2;
    return c.constrain(.{ .width = w, .height = line_h + pad_v * 2 });
}

/// 绘制：背景/边框 → 选区背景 → 文本 → 组合串下划线 → 光标（§5.8）。
pub fn paint(tree: *node.Tree, pc: painter.PaintCtx, n: *node.Node, d: widget.Edit) void {
    const th = tree.theme_ref;
    const focus = tree.focus == n;
    const hover = tree.hover == n;

    // 背景：悬停取 bg_hover；聚焦边框用 accent（细边框指示焦点，无外扩光环）。
    pc.fillRoundedRect(n.rect, th.radius.small, if (hover) th.bg_hover else th.bg_surface);
    pc.strokeRect(n.rect, if (focus) th.accent else th.border, 1, th.radius.small);

    const ts = tree.text_system orelse return;
    const content = geo.Rect{
        .x = n.rect.x + pad_h,
        .y = n.rect.y + pad_v,
        .w = n.rect.w - pad_h * 2,
        .h = n.rect.h - pad_v * 2,
    };
    if (content.w <= 0 or content.h <= 0) return;

    // 选区背景（文本之下）。仅焦点时绘制——失焦后不高亮（选区数据保留，聚焦恢复）。
    if (focus and d.hasSelection()) {
        const a = @min(d.anchor, d.caret);
        const b = @max(d.anchor, d.caret);
        const ax = prefixWidth(ts, &th.font_ui, d.buf, a);
        const bx = prefixWidth(ts, &th.font_ui, d.buf, b);
        pc.fillRect(.{ .x = content.x + ax, .y = content.y, .w = bx - ax, .h = content.h }, th.selection_bg);
    }

    // 正文文本。
    if (ts.layout(d.buf, &th.font_ui, content.w, .{})) |tl| {
        pc.drawText(content, tl, th.text);
    }

    // IME 组合串：绘制在 caret（buf 尾部）处，标准样式 = 白字 + 底部白虚线（§5.10）。
    var compose_x: f32 = 0;
    var compose_w: f32 = 0;
    if (d.composing and d.compose_text.len > 0) {
        compose_x = prefixWidth(ts, &th.font_ui, d.buf, @intCast(d.buf.len));
        if (ts.layout(d.compose_text, &th.font_ui, content.w - compose_x, .{})) |tl| {
            compose_w = tl.bounds.width;
            pc.drawText(.{ .x = content.x + compose_x, .y = content.y, .w = compose_w, .h = content.h }, tl, th.text);
            const underline_y = content.y + content.h - 2;
            drawDottedUnderline(pc, content.x + compose_x, underline_y, compose_w, th.text);
        }
    }

    // 光标（§5.8）：统一受闪烁相位控制——空闲时持续闪烁（组合时在组合串末尾）；
    // 连续动作时 syncCaretTimer 把 blink 置 true 恒显示，停止后 WM_TIMER 恢复闪烁。
    if (focus and tree.caret_blink_on) {
        const cx = if (d.composing) compose_x + compose_w else prefixWidth(ts, &th.font_ui, d.buf, d.caret);
        pc.fillRect(.{ .x = content.x + cx, .y = content.y, .w = caret_w, .h = content.h }, th.text);
    }
}

/// 内建事件处理（dispatch_table.onEvent，§5.4/§5.8）。返回 true = 已消费。
pub fn onEvent(tree: *node.Tree, n: *node.Node, e: *const event.Event) bool {
    const d = &n.widget.edit;
    return switch (e.*) {
        .key_down => |k| handleKey(tree, n, d, k),
        .text_input => |ti| {
            insertText(tree, d, ti.text);
            n.invalidatePaint(); // 提交到 buf 后必须失效：在 scroll 下层时驱动其离屏条带重栅化（§5.6）。
            return true;
        },
        .ime_compose => |ic| {
            updateCompose(tree, d, ic.text);
            n.invalidatePaint();
            return true;
        },
        .pointer_down => |p| handlePointerDown(tree, n, d, p),
        .pointer_move => |p| handlePointerMove(tree, n, d, p),
        .pointer_up => handlePointerUp(n, d),
        else => false,
    };
}

// —— 鼠标（§5.8：点选 caret、拖选扩展、双击选词）——

fn handlePointerDown(tree: *node.Tree, n: *node.Node, d: *widget.Edit, p: event.Pointer) bool {
    if (tree.focus != n) tree.setFocus(n); // 点击聚焦（触发焦点环定时器等）。
    const x = p.pos.x - n.rect.x - pad_h; // 内容区相对 x。
    const caret = caretAtX(tree, d, x);
    if (p.double) {
        selectWordAt(d, caret);
    } else {
        d.caret = caret;
        d.anchor = caret;
    }
    d.dragging = true;
    n.invalidatePaint();
    return true;
}

fn handlePointerMove(tree: *node.Tree, n: *node.Node, d: *widget.Edit, p: event.Pointer) bool {
    if (!d.dragging) return false; // 非拖选不处理（事件继续冒泡）。
    // 拖选越界自动滚动（§6 DoD）：指针超出 scroll 视口时向对应方向滚动。
    if (scroll_mod.autoScrollOnDrag(n, p.pos.y)) {
        // 已滚动：本轮坐标基于旧 rect，caret 下一轮修正；仍需按当前 x 更新。
        n.invalidatePaint();
    }
    const x = p.pos.x - n.rect.x - pad_h;
    d.caret = caretAtX(tree, d, x);
    n.invalidatePaint();
    return true;
}

fn handlePointerUp(n: *node.Node, d: *widget.Edit) bool {
    _ = n;
    if (!d.dragging) return false;
    d.dragging = false;
    return false; // 结束拖选；不停止，让 click 语义继续（§5.8）。
}

/// 鼠标 x（内容区 DIP）→ buf 码点偏移（前缀宽度线性逼近，缓存命中，L4）。
fn caretAtX(tree: *node.Tree, d: *widget.Edit, x: f32) u32 {
    const ts = tree.text_system orelse return 0;
    if (x <= 0 or d.buf.len == 0) return 0;
    const font = &tree.theme_ref.font_ui;
    var byte: usize = 0;
    var best: usize = 0;
    while (byte < d.buf.len) {
        const next = utf8.nextCodepoint(d.buf, byte);
        const w = prefixWidth(ts, font, d.buf, @intCast(next));
        if (w > x) break; // 超出点击位置。
        best = next;
        byte = next;
    }
    return @intCast(best);
}

/// 双击选词：空白 → 连续空白段；词字符（英文/数字）→ 连续词段；
/// 其余单字符（中文/全角标点）→ 仅选中一个字符（§5.8）。
fn selectWordAt(d: *widget.Edit, pos: u32) void {
    const buf = d.buf;
    if (buf.len == 0) return;
    const ws = if (pos < buf.len) isWhitespace(buf, pos) else false;
    const word = if (pos < buf.len) isWordChar(buf, pos) else false;
    var a = pos;
    var b = pos;
    if (ws) {
        while (a > 0) {
            const prev = utf8.prevCodepoint(buf, a);
            if (!isWhitespace(buf, prev)) break;
            a = @intCast(prev);
        }
        while (b < buf.len) {
            if (!isWhitespace(buf, b)) break;
            b = @intCast(utf8.nextCodepoint(buf, b));
        }
    } else if (word) {
        while (a > 0) {
            const prev = utf8.prevCodepoint(buf, a);
            if (!isWordChar(buf, prev)) break;
            a = @intCast(prev);
        }
        while (b < buf.len) {
            if (!isWordChar(buf, b)) break;
            b = @intCast(utf8.nextCodepoint(buf, b));
        }
    } else if (b < buf.len) {
        // 单字符（中文等）：仅选中自身。
        b = @intCast(utf8.nextCodepoint(buf, b));
    }
    d.anchor = @intCast(a);
    d.caret = @intCast(b);
}

/// 解码 pos 处的一个完整码点（utf8Decode 只接受 1-4 字节的精确切片，不能传整个剩余串）。
fn decodeAt(buf: []const u8, pos: usize) ?u21 {
    if (pos >= buf.len) return null;
    const seq_len = std.unicode.utf8ByteSequenceLength(buf[pos]) catch return null;
    if (pos + seq_len > buf.len) return null;
    return std.unicode.utf8Decode(buf[pos .. pos + seq_len]) catch null;
}

/// 是否空白（ASCII 空白 + 全角空格 U+3000）。
fn isWhitespace(buf: []const u8, pos: usize) bool {
    const cp = decodeAt(buf, pos) orelse return false;
    if (cp < 128) return std.ascii.isWhitespace(@intCast(cp));
    return cp == 0x3000;
}

/// 是否可扩展词字符（字母/数字/下划线/全角字母数字；不含 CJK——中文按单字符）。
fn isWordChar(buf: []const u8, pos: usize) bool {
    const cp = decodeAt(buf, pos) orelse return false;
    if (cp < 128) return std.ascii.isAlphanumeric(@intCast(cp)) or cp == '_';
    return (cp >= 0xFF10 and cp <= 0xFF19) or // 全角数字
        (cp >= 0xFF21 and cp <= 0xFF3A) or // 全角大写
        (cp >= 0xFF41 and cp <= 0xFF5A); // 全角小写
}

// —— 键盘（§5.8：composing 期间全部交给 IME，吞掉）——

fn handleKey(tree: *node.Tree, n: *node.Node, d: *widget.Edit, k: event.Key) bool {
    if (d.composing) return true; // 组合中：方向键选候选等交给 IME，不移动 caret。
    if ((k.mods & event.Mod.control) != 0) return handleShortcut(tree, n, d, k);
    const shift = (k.mods & event.Mod.shift) != 0;
    switch (k.vk) {
        event.VK.LEFT => moveCaret(d, shift, -1),
        event.VK.RIGHT => moveCaret(d, shift, 1),
        // 单行编辑框：上/下方向键等同 Home/End（标准行为）。
        event.VK.HOME, event.VK.UP => moveCaretAbs(d, shift, 0),
        event.VK.END, event.VK.DOWN => moveCaretAbs(d, shift, d.buf.len),
        event.VK.BACKSPACE => backspace(tree, d),
        event.VK.DELETE => deleteForward(tree, d),
        else => return false, // 字符输入走 WM_CHAR → text_input（L5），其余冒泡。
    }
    n.invalidatePaint();
    return true;
}

/// Ctrl 快捷键：A 全选 / C/V/X 剪贴板 / Z 撤销 / Y 重做（§5.11，经 tree.clipboard 接口）。
fn handleShortcut(tree: *node.Tree, n: *node.Node, d: *widget.Edit, k: event.Key) bool {
    const shift = (k.mods & event.Mod.shift) != 0;
    switch (k.vk) {
        0x41 => selectAll(d), // A：全选
        0x43 => copySelection(tree, d), // C
        0x56 => pasteClipboard(tree, d), // V
        0x58 => cutSelection(tree, d), // X
        0x5A => { // Z：撤销；Shift+Z：重做。
            if (shift) {
                _ = redoEdit(tree, d);
            } else {
                _ = undoEdit(tree, d);
            }
        },
        0x59 => _ = redoEdit(tree, d), // Y：重做。
        else => return false, // 其他 Ctrl 组合冒泡。
    }
    n.invalidatePaint();
    return true;
}

/// 全选：anchor 到 0，caret 到末尾。
fn selectAll(d: *widget.Edit) void {
    d.anchor = 0;
    d.caret = @intCast(d.buf.len);
}

fn copySelection(tree: *node.Tree, d: *widget.Edit) void {
    if (!d.hasSelection()) return;
    const clip = tree.clipboard orelse return;
    const a = @min(d.anchor, d.caret);
    const b = @max(d.anchor, d.caret);
    clip.write(d.buf[a..b]);
}

fn cutSelection(tree: *node.Tree, d: *widget.Edit) void {
    copySelection(tree, d);
    if (!d.hasSelection()) return;
    pushUndo(tree, d);
    const caret = deleteSelection(tree, d);
    d.caret = caret;
    d.anchor = caret;
}

fn pasteClipboard(tree: *node.Tree, d: *widget.Edit) void {
    const clip = tree.clipboard orelse return;
    // 读入 arena（tree 生命周期内有效）；insertText 拷贝到 buf，无泄漏（§4.3）。
    const text = clip.read(tree.arena.allocator()) orelse return;
    insertText(tree, d, text);
}

fn moveCaret(d: *widget.Edit, shift: bool, dir: i32) void {
    const new_caret = if (dir < 0) utf8.prevCodepoint(d.buf, d.caret) else utf8.nextCodepoint(d.buf, d.caret);
    // 无 Shift：光标移动并清除选区（anchor 追平）。有 Shift：anchor 不动，扩展选区。
    if (!shift) d.anchor = @intCast(new_caret);
    d.caret = @intCast(new_caret);
}

fn moveCaretAbs(d: *widget.Edit, shift: bool, pos: usize) void {
    const new_caret = utf8.clampToBoundary(d.buf, pos);
    if (!shift) d.anchor = @intCast(new_caret);
    d.caret = @intCast(new_caret);
}

fn backspace(tree: *node.Tree, d: *widget.Edit) void {
    if (d.hasSelection()) {
        pushUndo(tree, d);
        const caret = deleteSelection(tree, d);
        d.caret = caret;
        d.anchor = caret;
        return;
    }
    if (d.caret == 0) return;
    pushUndo(tree, d);
    const prev = utf8.prevCodepoint(d.buf, d.caret);
    d.buf = concatSlice(tree, d.buf[0..prev], d.buf[d.caret..]) orelse return;
    d.caret = @intCast(prev);
    d.anchor = d.caret;
}

fn deleteForward(tree: *node.Tree, d: *widget.Edit) void {
    if (d.hasSelection()) {
        pushUndo(tree, d);
        const caret = deleteSelection(tree, d);
        d.caret = caret;
        d.anchor = caret;
        return;
    }
    if (d.caret >= d.buf.len) return;
    pushUndo(tree, d);
    const next = utf8.nextCodepoint(d.buf, d.caret);
    d.buf = concatSlice(tree, d.buf[0..d.caret], d.buf[next..]) orelse return;
    d.anchor = d.caret;
}

/// 删除选区（anchor..caret），返回删除后的位置（min）。buf 更新走 arena。
fn deleteSelection(tree: *node.Tree, d: *widget.Edit) u32 {
    const a = @min(d.anchor, d.caret);
    const b = @max(d.anchor, d.caret);
    if (a == b) return @intCast(a);
    d.buf = concatSlice(tree, d.buf[0..a], d.buf[b..]) orelse return @intCast(a);
    return @intCast(a);
}

// —— 文本输入 / IME ——

fn insertText(tree: *node.Tree, d: *widget.Edit, text: []const u8) void {
    if (text.len == 0) return;
    pushUndo(tree, d); // 组合提交也在此（composing 期间 buf 冻结 → 整组合 = 一步 undo）。
    const caret = deleteSelection(tree, d);
    const mid = d.buf[caret..];
    const new = concat3(tree, d.buf[0..caret], text, mid) orelse return;
    d.buf = new;
    d.caret = caret + @as(u32, @intCast(text.len));
    d.anchor = d.caret;
    d.composing = false;
    d.compose_text = "";
}

fn updateCompose(tree: *node.Tree, d: *widget.Edit, text: []const u8) void {
    if (text.len == 0) {
        // 组合结束（ENDCOMPOSITION / 空 GCS_COMPSTR）。
        d.composing = false;
        d.compose_text = "";
        return;
    }
    d.composing = true;
    d.compose_text = tree.allocStr(text) catch "";
}

// —— 辅助 ——

/// undo/redo 栈（M6，§5.8 组合提交合并为一步 undo）。
/// 编辑前记录 buf 快照 = arena 切片引用（旧 buf 在 arena 天然存活，O(1)/条）；
/// 清空 redo；超上限丢弃最旧（arena 语义：旧缓冲仍存活，仅不再可撤销）。
fn pushUndo(tree: *node.Tree, d: *widget.Edit) void {
    d.redo.clearRetainingCapacity();
    d.undo.append(tree.arena.allocator(), d.buf) catch return;
    if (d.undo.items.len > UNDO_MAX) {
        std.mem.copyForwards([]const u8, d.undo.items[0 .. d.undo.items.len - 1], d.undo.items[1..]);
        _ = d.undo.pop();
    }
}

/// Ctrl+Z：撤销一步。恢复 buf，caret 置末尾。无可撤销返回 false。
fn undoEdit(tree: *node.Tree, d: *widget.Edit) bool {
    if (d.undo.items.len == 0) return false;
    const prev = d.undo.pop().?;
    d.redo.append(tree.arena.allocator(), d.buf) catch return true;
    d.buf = prev;
    d.caret = @intCast(d.buf.len);
    d.anchor = d.caret;
    return true;
}

/// Ctrl+Y / Ctrl+Shift+Z：重做一步。无可重做返回 false。
fn redoEdit(tree: *node.Tree, d: *widget.Edit) bool {
    if (d.redo.items.len == 0) return false;
    const next = d.redo.pop().?;
    d.undo.append(tree.arena.allocator(), d.buf) catch return true;
    d.buf = next;
    d.caret = @intCast(d.buf.len);
    d.anchor = d.caret;
    return true;
}

/// buf[0..pos] 的布局宽度（caret / 选区定位用）。零分配，走缓存（L4）。
/// 用含尾随空白宽度：光标紧跟空格时位置正确（§5.8）。
fn prefixWidth(ts: painter.TextSystem, font: *const theme.Font, buf: []const u8, pos: u32) f32 {
    if (pos == 0 or pos > buf.len) return 0;
    if (ts.layout(buf[0..pos], font, 1_000_000.0, .{})) |tl| return tl.width_with_ws;
    return 0;
}

/// 底部虚线（标准 IME 组合串下划线样式，§5.10）。短横线模拟，零分配。
fn drawDottedUnderline(pc: painter.PaintCtx, x: f32, y: f32, w: f32, color: theme.Color) void {
    const dash: f32 = 3;
    const gap: f32 = 2;
    var cx: f32 = 0;
    while (cx < w) : (cx += dash + gap) {
        const seg = @min(dash, w - cx);
        if (seg <= 0) break;
        pc.strokeRect(.{ .x = x + cx, .y = y, .w = seg, .h = 1 }, color, 1, 0);
    }
}

fn concatSlice(tree: *node.Tree, a: []const u8, b: []const u8) ?[]const u8 {
    if (a.len == 0) return b;
    if (b.len == 0) return a;
    return std.mem.concat(tree.arena.allocator(), u8, &.{ a, b }) catch null;
}

fn concat3(tree: *node.Tree, a: []const u8, b: []const u8, c: []const u8) ?[]const u8 {
    if (a.len == 0 and b.len == 0 and c.len == 0) return "";
    return std.mem.concat(tree.arena.allocator(), u8, &.{ a, b, c }) catch null;
}

// —— 测试：状态机与码点边界 ——

test "edit: insert text advances caret" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try node.Tree.init(arena.allocator(), &theme.light);
    defer t.deinit();
    var e = widget.Edit{};
    insertText(&t, &e, "abc");
    try std.testing.expectEqualStrings("abc", e.buf);
    try std.testing.expectEqual(@as(u32, 3), e.caret);
    insertText(&t, &e, "中");
    try std.testing.expectEqualStrings("abc中", e.buf);
    try std.testing.expectEqual(@as(u32, 6), e.caret); // 3 + 3 字节
}

test "edit: ctrl+a selects all" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try node.Tree.init(arena.allocator(), &theme.light);
    defer t.deinit();
    var e = widget.Edit{};
    insertText(&t, &e, "hello 世界");
    e.caret = 3;
    selectAll(&e);
    try std.testing.expect(e.hasSelection());
    try std.testing.expectEqual(@as(u32, 0), e.anchor);
    try std.testing.expectEqual(@as(u32, @intCast(e.buf.len)), e.caret);
}

test "edit: double-click selects word / single CJK / whitespace run" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try node.Tree.init(arena.allocator(), &theme.light);
    defer t.deinit();
    var e = widget.Edit{};
    insertText(&t, &e, "hello 世界 x");
    // 双击英文词 "hello"（pos 1）：整词。
    selectWordAt(&e, 1);
    try std.testing.expectEqual(@as(u32, 0), e.anchor);
    try std.testing.expectEqual(@as(u32, 5), e.caret);
    // 双击中文 "世"（pos 6 = 其起始边界）：单个汉字。
    selectWordAt(&e, 6);
    try std.testing.expectEqual(@as(u32, 6), e.anchor);
    try std.testing.expectEqual(@as(u32, 9), e.caret);
    // 双击空格（pos 5）：单个空格。
    selectWordAt(&e, 5);
    try std.testing.expectEqual(@as(u32, 5), e.anchor);
    try std.testing.expectEqual(@as(u32, 6), e.caret);
    // 连续空白段（多个空格）：一次选中。
    var e2 = widget.Edit{};
    insertText(&t, &e2, "a   b");
    selectWordAt(&e2, 2); // 空格段中间
    try std.testing.expectEqual(@as(u32, 1), e2.anchor);
    try std.testing.expectEqual(@as(u32, 4), e2.caret);
}

test "edit: caret move without shift clears selection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try node.Tree.init(arena.allocator(), &theme.light);
    defer t.deinit();
    var e = widget.Edit{};
    insertText(&t, &e, "hello");
    // Shift+Left：产生选区。
    e.caret = 5;
    moveCaret(&e, true, -1);
    try std.testing.expect(e.hasSelection());
    try std.testing.expectEqual(@as(u32, 5), e.anchor); // anchor 不动。
    // 无 Shift Left：移动且清除选区。
    moveCaret(&e, false, -1);
    try std.testing.expect(!e.hasSelection());
    try std.testing.expectEqual(@as(u32, 3), e.caret);
    try std.testing.expectEqual(@as(u32, 3), e.anchor);
}

test "edit: caret never lands inside a codepoint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try node.Tree.init(arena.allocator(), &theme.light);
    defer t.deinit();
    var e = widget.Edit{};
    insertText(&t, &e, "a中b");
    e.caret = @intCast(e.buf.len);
    // 左移两次：b → 中 → a。
    moveCaret(&e, false, -1);
    try std.testing.expectEqual(@as(u32, 4), e.caret); // b(5) → 中后(4)
    try std.testing.expect(utf8.isBoundary(e.buf, e.caret));
    moveCaret(&e, false, -1);
    try std.testing.expectEqual(@as(u32, 1), e.caret); // 中后(4) → a后(1)
    // 右移。
    moveCaret(&e, false, 1);
    try std.testing.expectEqual(@as(u32, 4), e.caret);
}

test "edit: backspace and delete at boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try node.Tree.init(arena.allocator(), &theme.light);
    defer t.deinit();
    var e = widget.Edit{};
    insertText(&t, &e, "a中b");
    e.caret = @intCast(e.buf.len);
    backspace(&t, &e); // 删 b
    try std.testing.expectEqualStrings("a中", e.buf);
    try std.testing.expectEqual(@as(u32, 4), e.caret);
    backspace(&t, &e); // 删 中（多字节整体删）
    try std.testing.expectEqualStrings("a", e.buf);
    deleteForward(&t, &e); // 无后续
    try std.testing.expectEqualStrings("a", e.buf);
}

test "edit: selection replaced by insert" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try node.Tree.init(arena.allocator(), &theme.light);
    defer t.deinit();
    var e = widget.Edit{};
    insertText(&t, &e, "hello world");
    // 选中 index 4..9（"o wor"）：caret 到 9，anchor 到 4。
    e.caret = 9;
    e.anchor = 4;
    try std.testing.expect(e.hasSelection());
    insertText(&t, &e, "X");
    try std.testing.expectEqualStrings("hellXld", e.buf);
    try std.testing.expectEqual(@as(u32, 5), e.caret);
    try std.testing.expect(!e.hasSelection());
}

test "edit: composing freezes buf and caret" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try node.Tree.init(arena.allocator(), &theme.light);
    defer t.deinit();
    var e = widget.Edit{};
    insertText(&t, &e, "ab");
    updateCompose(&t, &e, "nihao");
    try std.testing.expect(e.composing);
    try std.testing.expectEqualStrings("nihao", e.compose_text);
    // 组合中按方向键被吞掉（handleKey 返回 true 且 caret 不动）。
    const k = event.Key{ .vk = event.VK.LEFT };
    const n = try t.createNode(t.root);
    n.widget = .{ .edit = e };
    const consumed = handleKey(&t, n, &n.widget.edit, k);
    try std.testing.expect(consumed);
    try std.testing.expectEqual(@as(u32, 2), e.caret);
    // 提交：text_input 插入并退出 composing。
    insertText(&t, &e, "好");
    try std.testing.expect(!e.composing);
    try std.testing.expectEqualStrings("ab好", e.buf);
}

test "edit: undo and redo restore buf snapshots" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try node.Tree.init(arena.allocator(), &theme.light);
    defer t.deinit();
    var e = widget.Edit{};
    insertText(&t, &e, "hello");
    insertText(&t, &e, " world");
    try std.testing.expectEqualStrings("hello world", e.buf);

    // 撤销两次回到初始。
    try std.testing.expect(undoEdit(&t, &e));
    try std.testing.expectEqualStrings("hello", e.buf);
    try std.testing.expect(undoEdit(&t, &e));
    try std.testing.expectEqualStrings("", e.buf);
    try std.testing.expect(!undoEdit(&t, &e)); // 无更多可撤销。

    // 重做两次回到最新。
    try std.testing.expect(redoEdit(&t, &e));
    try std.testing.expectEqualStrings("hello", e.buf);
    try std.testing.expect(redoEdit(&t, &e));
    try std.testing.expectEqualStrings("hello world", e.buf);
    try std.testing.expect(!redoEdit(&t, &e));

    // 撤销后新编辑清空 redo。
    _ = undoEdit(&t, &e);
    insertText(&t, &e, "!");
    try std.testing.expectEqualStrings("hello!", e.buf);
    try std.testing.expect(!redoEdit(&t, &e));
}

test "edit: composition commit is one undo step" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try node.Tree.init(arena.allocator(), &theme.light);
    defer t.deinit();
    var e = widget.Edit{};
    insertText(&t, &e, "ab"); // undo: [""]
    updateCompose(&t, &e, "nihao"); // composing 中 buf 冻结，无快照。
    insertText(&t, &e, "好"); // 提交合并为一步：undo ["", "ab"]。
    try std.testing.expectEqualStrings("ab好", e.buf);
    try std.testing.expectEqual(@as(usize, 2), e.undo.items.len);

    try std.testing.expect(undoEdit(&t, &e)); // 撤销整组合提交。
    try std.testing.expectEqualStrings("ab", e.buf);
    try std.testing.expect(undoEdit(&t, &e)); // 撤销打字。
    try std.testing.expectEqualStrings("", e.buf);
}

test "edit: backspace/delete/cut are undoable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try node.Tree.init(arena.allocator(), &theme.light);
    defer t.deinit();
    var e = widget.Edit{};
    insertText(&t, &e, "abc");
    e.caret = 3;
    backspace(&t, &e); // "ab"
    try std.testing.expectEqualStrings("ab", e.buf);
    try std.testing.expect(undoEdit(&t, &e));
    try std.testing.expectEqualStrings("abc", e.buf);

    // deleteForward 在末尾：无变化，不压栈。
    e.caret = 3;
    deleteForward(&t, &e);
    try std.testing.expectEqualStrings("abc", e.buf);

    // cut 有选区：删除并压栈（剪贴板未装配时只删不写）。
    e.anchor = 0;
    e.caret = 3;
    cutSelection(&t, &e);
    try std.testing.expectEqualStrings("", e.buf);
    try std.testing.expect(undoEdit(&t, &e));
    try std.testing.expectEqualStrings("abc", e.buf);
}

test "edit: hover uses bg_hover on background (MockPainter)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = try node.Tree.init(arena.allocator(), &theme.light);
    defer t.deinit();

    const n = try t.createNode(t.root);
    n.widget = .{ .edit = .{ .buf = "x" } };
    n.rect = .{ .x = 0, .y = 0, .w = 100, .h = 24 };

    var mp = try painter.MockPainter.init(std.testing.allocator, &theme.light);
    defer mp.destroy();

    // 无 hover：背景 bg_surface（fillRoundedRect）。
    paint(&t, mp.ctx, n, n.widget.edit);
    try std.testing.expect(mp.calls.items[0].fillRoundedRect.color.r == theme.light.bg_surface.r);

    // hover：背景 bg_hover。
    mp.reset();
    t.hover = n;
    paint(&t, mp.ctx, n, n.widget.edit);
    try std.testing.expect(mp.calls.items[0].fillRoundedRect.color.r == theme.light.bg_hover.r);
}
