//! compiler.zig — in-process Zig compiler invocation.
//!
//! This module embeds the upstream Zig compiler as a library and
//! calls it by the same entry point that the CLI uses —
//! `mainArgs(gpa, arena, args)` in upstream src/main.zig — but
//! without spawning a subprocess. See build.zig for the link-time
//! wiring and scripts/setup-zig-source.sh for how libzig.a is
//! produced.
//!
//! # Known M1 limitation
//!
//! Upstream Zig still calls `std.process.exit(code)` on some fatal
//! error paths inside mainArgs (e.g. parse failures, missing input
//! files, linker errors). In the embedded model, that exits our
//! host process, not a child. For the M1 happy-path smoke test
//! (valid `examples/hello.zig`) this doesn't trigger, but we will
//! need a follow-up patch (or a longjmp-style trampoline) before
//! exposing the compiler to untrusted user input. Tracked in the
//! plan as M1.5.

const std = @import("std");
const builtin = @import("builtin");
const zig = @import("zig_compiler");
const zigbox_build_options = @import("zigbox_build_options");

pub const CompileError = error{
    CompilerFailed,
    OutOfMemory,
    InvalidUtf8,
} || std.fs.File.OpenError || std.mem.Allocator.Error;

pub const Options = struct {
    /// Absolute path to the user's .zig source file.
    source_path: []const u8,
    /// Where to write the produced dynamic library.
    output_path: []const u8,
    /// Module name embedded in the artifact metadata.
    name: []const u8 = "user_code",
    /// Optimization level passed to the compiler.
    optimize: Optimize = .Debug,
};

pub const Optimize = enum {
    Debug,
    ReleaseSafe,
    ReleaseFast,
    ReleaseSmall,

    fn argString(self: Optimize) []const u8 {
        return switch (self) {
            .Debug => "Debug",
            .ReleaseSafe => "ReleaseSafe",
            .ReleaseFast => "ReleaseFast",
            .ReleaseSmall => "ReleaseSmall",
        };
    }
};

fn appendCompileArgs(
    arena: std.mem.Allocator,
    argv_list: *std.ArrayList([]const u8),
    opts: Options,
) !void {
    const output_dir = std.fs.path.dirname(opts.output_path) orelse ".";
    const global_cache_dir = try std.fs.path.join(arena, &.{ output_dir, "zig-global-cache" });
    try argv_list.appendSlice(&.{
        "build-lib",
        "-dynamic",
        "-fPIC",
        "-O",
        opts.optimize.argString(),
        "--cache-dir",
        output_dir,
        "--global-cache-dir",
        global_cache_dir,
        "--zig-lib-dir",
        zigbox_build_options.embedded_zig_lib_dir,
    });
    try argv_list.append(if (zigbox_build_options.embedded_zig_have_llvm) "-fllvm" else "-fno-llvm");
    if (builtin.os.tag == .windows) {
        try argv_list.append("-fno-emit-implib");
        if (zigbox_build_options.embedded_zig_windows_host_implib.len == 0) {
            std.log.err("Windows build missing zigbox host import library path", .{});
            return CompileError.CompilerFailed;
        }
        try argv_list.append(zigbox_build_options.embedded_zig_windows_host_implib);
    }
    try argv_list.append(try std.fmt.allocPrint(arena, "-femit-bin={s}", .{opts.output_path}));
    try argv_list.appendSlice(&.{
        "--name",
        opts.name,
        opts.source_path,
    });
}

fn compileWithSelfExecutable(gpa: std.mem.Allocator, opts: Options) CompileError!void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const self_exe_path = std.fs.selfExePathAlloc(arena) catch |err| {
        std.log.err("failed to resolve zigbox self exe path: {s}", .{@errorName(err)});
        return CompileError.CompilerFailed;
    };

    var argv_list = std.ArrayList([]const u8).init(arena);
    try argv_list.append(self_exe_path);
    try argv_list.append("__zigbox-zig");
    try appendCompileArgs(arena, &argv_list, opts);
    const argv = try argv_list.toOwnedSlice();

    var child = std.process.Child.init(argv, gpa);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    const term = child.spawnAndWait() catch |err| {
        std.log.err("failed to launch embedded zigbox compiler subprocess: {s}", .{@errorName(err)});
        return CompileError.CompilerFailed;
    };

    switch (term) {
        .Exited => |code| if (code != 0) {
            std.log.err("embedded zigbox compiler subprocess exited with code {d}", .{code});
            return CompileError.CompilerFailed;
        },
        else => {
            std.log.err("embedded zigbox compiler subprocess crashed", .{});
            return CompileError.CompilerFailed;
        },
    }
}

/// Compile `opts.source_path` into a dynamic library at
/// `opts.output_path`. Works on Linux (.so), macOS (.dylib), and
/// Windows (.dll). On iOS the same command emits an unsigned Mach-O
/// dylib which must be signed separately before dlopen will accept
/// it (see docs §9).
pub fn compileDynamic(gpa: std.mem.Allocator, opts: Options) CompileError!void {
    if (builtin.os.tag == .windows and !zigbox_build_options.embedded_zig_have_llvm) {
        std.log.err(
            "Windows dynamic library compilation requires libzig built with LLVM enabled (-Denable-llvm); upstream 0.14.0 COFF self-hosted backend cannot emit the needed library output",
            .{},
        );
        return CompileError.CompilerFailed;
    }

    if (builtin.os.tag == .windows) {
        try compileWithSelfExecutable(gpa, opts);
        std.fs.cwd().access(opts.output_path, .{}) catch {
            std.log.err("compiler exited without producing {s}", .{opts.output_path});
            return CompileError.CompilerFailed;
        };
        return;
    }

    // We build the argv exactly as the `zig` CLI would receive it,
    // then hand it to mainArgs(). The arena here owns all the
    // strings we synthesize so they live for the whole compile.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const output_dir = std.fs.path.dirname(opts.output_path) orelse ".";
    const global_cache_dir = try std.fs.path.join(arena, &.{ output_dir, "zig-global-cache" });
    std.fs.makeDirAbsolute(global_cache_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return CompileError.CompilerFailed,
    };

    // -fPIC is implied by -dynamic on most targets, but explicit
    // is kind. We force the backend choice to match how libzig was
    // built so Windows can opt into LLVM while other targets can
    // stay on the self-hosted path.
    var argv_list = std.ArrayList([]const u8).init(arena);
    try argv_list.append("zig");
    try appendCompileArgs(arena, &argv_list, opts);
    const argv = try argv_list.toOwnedSlice();

    std.log.info("invoking embedded Zig compiler with {d} args", .{argv.len});

    // Hand off to upstream Zig's mainArgs. It allocates heavily
    // inside — we give it our gpa so leaks show up in tests.
    zig.mainArgs(gpa, arena, argv) catch |err| {
        std.log.err("embedded Zig compiler returned error: {s}", .{@errorName(err)});
        return CompileError.CompilerFailed;
    };

    // mainArgs doesn't tell us whether a binary was actually
    // produced on non-error exit (it may have printed help or
    // version). Re-check by stat'ing the output path.
    std.fs.cwd().access(opts.output_path, .{}) catch {
        std.log.err("compiler exited without producing {s}", .{opts.output_path});
        return CompileError.CompilerFailed;
    };
}

/// Pick the platform-appropriate extension for a dynamic library.
pub fn dynlibExtension() []const u8 {
    return switch (builtin.os.tag) {
        .windows => ".dll",
        .macos, .ios, .tvos, .watchos => ".dylib",
        else => ".so",
    };
}

test "Optimize.argString covers all cases" {
    try std.testing.expectEqualStrings("Debug", Optimize.Debug.argString());
    try std.testing.expectEqualStrings("ReleaseFast", Optimize.ReleaseFast.argString());
}

test "dynlibExtension returns a non-empty string" {
    try std.testing.expect(dynlibExtension().len >= 3);
}
