//! platform/win32.zig —— Win32 声明汇总 re-export（规则 §3）。
//!
//! 模块不变量：
//! - 这是本仓库唯一允许触碰 win32 包的入口之一（另一个是 render/）；
//! - core/、widgets/、theme.zig 严禁 import 本文件或 win32 包（L1 + §3 矩阵）；
//! - 一律使用 zigwin32 包的声明，禁止手写与包内重复的 Win32 声明（§5.6）。

const zw = @import("win32");

// —— 基础标量与架构相关的 ABI 类型 ——
// 注：zigwin32 的 extern 函数签名使用其私有标量类型（BOOL=i32、WPARAM=usize、
// LRESULT=isize、LPARAM=isize），本仓库 re-export 必须与之对齐，否则调用类型不匹配。
pub const BOOL = i32;
pub const BOOLEAN = u8;
pub const LRESULT = isize;
pub const WPARAM = usize;
pub const LPARAM = isize;
pub const UINT = u32;
pub const INT = i32;
pub const DWORD = u32;
pub const LONG = i32;
pub const ATOM = u16;
pub const LPCWSTR = [*:0]const u16;
pub const LPWSTR = [*:0]u16;
pub const PCWSTR = [*:0]const u16;
pub const LPVOID = *anyopaque;

// —— 句柄与基础结构（取自包 foundation）——
pub const HWND = zw.foundation.HWND;
pub const HINSTANCE = zw.foundation.HINSTANCE;
pub const HMENU = zw.foundation.HMENU;
pub const HICON = zw.foundation.HICON;
pub const HCURSOR = zw.foundation.HCURSOR;
pub const HBRUSH = zw.foundation.HBRUSH;
pub const POINT = zw.foundation.POINT;
pub const RECT = zw.foundation.RECT;

// —— DLL 函数模块（zigwin32 按 DLL 组织）——
pub const user32 = zw.user32;
pub const kernel32 = zw.kernel32;
pub const dwmapi = zw.dwmapi;
pub const gdi32 = zw.gdi32;
pub const ole32 = zw.ole32;
pub const shell32 = zw.shell32;
pub const imm32 = zw.imm32;
pub const dwrite = zw.dwrite;
pub const d2d1 = zw.d2d1;

// —— zigwin32 便捷层（COLORREF 等通用类型）——
pub const zig = zw.zig;

// —— 命名空间（结构体/枚举/常量）——
pub const foundation = zw.foundation;
pub const windows_and_messaging = zw.ui.windows_and_messaging;
pub const hi_dpi = zw.ui.hi_dpi;
pub const system_information = zw.system.system_information;
pub const system_ole = zw.system.ole; // 剪贴板格式（CF_UNICODETEXT 等）
pub const globalization = zw.globalization; // HIMC/HKL 等输入法句柄

// —— 渲染命名空间（M2 起启用，先留出口）——
pub const direct2d = zw.graphics.direct2d;
pub const direct_write = zw.graphics.direct_write;

// —— DWM / GDI / 输入法 ——
pub const dwm = zw.graphics.dwm;
pub const gdi = zw.graphics.gdi;
pub const ime = zw.ui.input.ime;

/// 设置进程级 DPI 感知（per-monitor v2，免 manifest；规则 §5.9 启动序列第一步）。
pub fn setProcessDpiAwarenessContextPerMonitorV2() BOOL {
    return user32.SetProcessDpiAwarenessContext(
        hi_dpi.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2,
    );
}
