//! platform/ime.zig —— IMM32 输入法（规则 §5.10）。
//!
//! 模块不变量：
//! - 组合窗/候选框定位用 caret 的屏幕物理坐标，Edit paint 后经 updateCaret 回报；
//! - WM_IME_COMPOSITION：lParam 含 GCS_RESULTSTR → text_input（提交）；
//!   含 GCS_COMPSTR → ime_compose（组合串）；
//! - 事件文本分配于调用方传入的 allocator，生命周期 = 当前事件（§5.10），
//!   调用方在派发后释放；
//! - IMM32 质量不达标时的 Plan B（TSF shim）见 §9 风险登记册。

const std = @import("std");
const w32 = @import("win32.zig");
const ime_ns = w32.ime;
const event = @import("../core/event.zig");

/// IME 上下文：组合窗/候选框跟随 caret。
pub const Ime = struct {
    hwnd: w32.HWND,
    /// caret 的屏幕物理坐标（Edit paint 后回报，§5.10）。
    caret_px_x: i32 = 0,
    caret_px_y: i32 = 0,

    fn context(self: *Ime) ?w32.globalization.HIMC {
        return w32.imm32.ImmGetContext(self.hwnd);
    }

    /// Edit paint 后回报 caret 屏幕物理坐标，并刷新组合窗/候选框位置。
    pub fn updateCaret(self: *Ime, px_x: i32, px_y: i32) void {
        self.caret_px_x = px_x;
        self.caret_px_y = px_y;
        self.positionWindows();
    }

    /// 组合窗（CFS_FORCE_POSITION）与候选框（CFS_EXCLUDE）跟随 caret（§5.10）。
    /// 候选框用 EXCLUDE：系统把候选框放到不覆盖 rcArea（组合串区域）的位置（下方）。
    fn positionWindows(self: *Ime) void {
        const hime = self.context() orelse return;
        defer _ = w32.imm32.ImmReleaseContext(self.hwnd, hime);

        var cf = ime_ns.COMPOSITIONFORM{
            .dwStyle = ime_ns.CFS_FORCE_POSITION,
            .ptCurrentPos = .{ .x = self.caret_px_x, .y = self.caret_px_y },
            .rcArea = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
        };
        _ = w32.imm32.ImmSetCompositionWindow(hime, &cf);

        // 排除区域 = caret 处的组合串矩形（约 200×24 px），候选框出现在其下方。
        var cand = ime_ns.CANDIDATEFORM{
            .dwIndex = 0,
            .dwStyle = ime_ns.CFS_EXCLUDE,
            .ptCurrentPos = .{ .x = self.caret_px_x, .y = self.caret_px_y },
            .rcArea = .{
                .left = self.caret_px_x,
                .top = self.caret_px_y,
                .right = self.caret_px_x + 200,
                .bottom = self.caret_px_y + 24,
            },
        };
        _ = w32.imm32.ImmSetCandidateWindow(hime, &cand);
    }

    /// WM_IME_SETCONTEXT / WM_IME_STARTCOMPOSITION：刷新组合窗/候选框位置。
    pub fn onStartComposition(self: *Ime) void {
        self.positionWindows();
    }

    /// 聚焦时启用输入法（Direct UI 多控件共享 HWND，需显式启用，§5.10 实践）。
    pub fn activate(self: *Ime) void {
        _ = w32.imm32.ImmAssociateContextEx(self.hwnd, null, ime_ns.IACE_DEFAULT);
    }

    /// 失焦时强制完成组合并停用输入法（防止系统 IME UI/组合窗驻留，§5.10 实践）。
    pub fn deactivate(self: *Ime) void {
        const hime = self.context() orelse return;
        defer _ = w32.imm32.ImmReleaseContext(self.hwnd, hime);
        // 强制完成组合（结果串会派发 WM_IME_COMPOSITION → Edit 提交）。
        _ = w32.imm32.ImmNotifyIME(hime, ime_ns.NI_COMPOSITIONSTR, ime_ns.CPS_COMPLETE, 0);
        // 停用：解除 IME 上下文关联。
        _ = w32.imm32.ImmAssociateContextEx(self.hwnd, null, 0);
    }

    /// WM_IME_COMPOSITION：结果串 → text_input；组合串 → ime_compose。
    /// 文本分配于 `allocator`（§5.10：生命周期 = 当前事件），调用方派发后释放。
    pub fn compositionEvent(self: *Ime, allocator: std.mem.Allocator, l_param: w32.LPARAM) ?event.Event {
        const hime = self.context() orelse return null;
        defer _ = w32.imm32.ImmReleaseContext(self.hwnd, hime);

        const l: u32 = @truncate(@as(u64, @bitCast(l_param)));
        if ((l & @as(u32, @bitCast(ime_ns.GCS_RESULTSTR))) != 0) {
            // 组合提交（§5.8）：作为 text_input 派发；composing 期间 buf 冻结，
            // Edit.insertText 将其合并为一步 undo（§6）。
            return if (readString(hime, ime_ns.GCS_RESULTSTR, allocator)) |s|
                .{ .text_input = .{ .text = s } }
            else
                null;
        }
        if ((l & @as(u32, @bitCast(ime_ns.GCS_COMPSTR))) != 0) {
            if (readString(hime, ime_ns.GCS_COMPSTR, allocator)) |s| {
                return .{ .ime_compose = .{ .text = s } };
            }
        }
        return null;
    }
};

/// 读组合/结果串（UTF-16 → UTF-8，分配于 allocator）。
fn readString(hime: ?w32.globalization.HIMC, index: ime_ns.IME_COMPOSITION_STRING, allocator: std.mem.Allocator) ?[]const u8 {
    const byte_len = w32.imm32.ImmGetCompositionStringW(hime, index, null, 0);
    if (byte_len <= 0 or byte_len == 0xFFFFFFFF) return null;
    const buf = allocator.alloc(u16, @intCast(@divTrunc(byte_len, 2))) catch return null;
    defer allocator.free(buf);
    const got = w32.imm32.ImmGetCompositionStringW(hime, index, @ptrCast(buf.ptr), @intCast(byte_len));
    if (got <= 0 or got == 0xFFFFFFFF) return null;
    var text16 = buf[0..@intCast(@divTrunc(got, 2))];
    // 去掉结尾 NUL（部分 IME 返回带 NUL）。
    if (text16.len > 0 and text16[text16.len - 1] == 0) text16 = text16[0 .. text16.len - 1];
    return std.unicode.utf16LeToUtf8Alloc(allocator, text16) catch null;
}
