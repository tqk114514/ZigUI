const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 唯一外部依赖：zig-win32（规则 L10）。仅提供声明，系统库在下方显式链接。
    const win32 = b.dependency("win32", .{}).module("win32");

    // 库：ui.zig 是唯一公共 API 出口（规则 §3）。
    // win32 只在内部经 platform/win32.zig re-export，examples 无法直接触碰。
    const ui_module = b.createModule(.{
        .root_source_file = b.path("ui.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "win32", .module = win32 },
        },
    });
    const lib = b.addLibrary(.{
        .name = "zigui",
        .root_module = ui_module,
    });
    linkNeededLibs(ui_module);
    b.installArtifact(lib);

    // 测验根：ui.zig（M0 为空，M1 起 core/widgets 就地 test 在此汇聚）。
    const lib_tests_module = b.createModule(.{
        .root_source_file = b.path("ui.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "win32", .module = win32 },
        },
    });
    linkNeededLibs(lib_tests_module);
    const lib_tests = b.addTest(.{ .root_module = lib_tests_module });
    const run_lib_tests = b.addRunArtifact(lib_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_tests.step);

    // 例子：每例一个概念，只经 ui.zig 访问（规则 §3 import 矩阵）。
    for (M0_EXAMPLES) |name| {
        const exe_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigui", .module = ui_module },
            },
        });
        linkNeededLibs(exe_module);
        const exe = b.addExecutable(.{ .name = name, .root_module = exe_module });
        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        if (b.args) |args| run_cmd.addArgs(args);
        const run_step = b.step(b.fmt("run-{s}", .{name}), "Run the example");
        run_step.dependOn(&run_cmd.step);
    }
}

/// M5 提供的示例清单。
const M0_EXAMPLES = [_][]const u8{
    "theme_preview",
    "counter",
    "focus",
    "threads",
    "text",
    "bench",
    "edit",
};

/// zig-win32 只提供声明；系统库的链接在 Zig 0.16 中位于 Module 层（规则 §5.9
/// 启动序列/消息表所涉 DLL），供引用平台的模块统一加入。
fn linkNeededLibs(m: *std.Build.Module) void {
    inline for (.{ "user32", "gdi32", "dwmapi", "ole32", "shell32", "imm32" }) |lib| {
        m.linkSystemLibrary(lib, .{});
    }
}
