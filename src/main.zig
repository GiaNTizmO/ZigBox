//! main.zig — the zigbox host CLI.
//!
//! Usage:
//!     zigbox <source.zig> [entry_symbol]
//!
//! entry_symbol defaults to "entry". The user file must export
//! a zero-argument C-ABI function with that name:
//!
//!     export fn entry() callconv(.C) void { ... }

const std = @import("std");
const zig = @import("zig_compiler");
const runtime = @import("runtime.zig");

const embedded_zig_runner_command = "__zigbox-zig";

fn isEmbeddedZigToolCommand(cmd: []const u8) bool {
    return std.mem.eql(u8, cmd, "ar") or
        std.mem.eql(u8, cmd, "cc") or
        std.mem.eql(u8, cmd, "c++") or
        std.mem.eql(u8, cmd, "clang") or
        std.mem.eql(u8, cmd, "-cc1") or
        std.mem.eql(u8, cmd, "-cc1as") or
        std.mem.eql(u8, cmd, "dlltool") or
        std.mem.eql(u8, cmd, "ld.lld") or
        std.mem.eql(u8, cmd, "lib") or
        std.mem.eql(u8, cmd, "lld-link") or
        std.mem.eql(u8, cmd, "objcopy") or
        std.mem.eql(u8, cmd, "ranlib") or
        std.mem.eql(u8, cmd, "rc") or
        std.mem.eql(u8, cmd, "wasm-ld");
}

fn runEmbeddedZig(gpa: std.mem.Allocator, args: []const []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    return zig.mainArgs(gpa, arena_state.allocator(), args);
}

fn runEmbeddedZigSubcommand(gpa: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 3) {
        std.process.exit(2);
    }

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const forwarded = try arena.alloc([]const u8, args.len - 1);
    forwarded[0] = args[0];
    @memcpy(forwarded[1..], args[2..]);
    return zig.mainArgs(gpa, arena, forwarded);
}

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    if (args.len >= 2 and std.mem.eql(u8, args[1], embedded_zig_runner_command)) {
        return runEmbeddedZigSubcommand(gpa, args);
    }

    if (args.len >= 2 and isEmbeddedZigToolCommand(args[1])) {
        return runEmbeddedZig(gpa, args);
    }

    if (args.len < 2) {
        std.debug.print(
            "usage: {s} <source.zig> [entry_symbol]\n",
            .{if (args.len >= 1) args[0] else "zigbox"},
        );
        std.process.exit(2);
    }

    const source_path = args[1];
    const entry_symbol = if (args.len >= 3) args[2] else "entry";
    const cache_dir = std.process.getEnvVarOwned(gpa, "ZIGBOX_CACHE_DIR") catch null;
    defer if (cache_dir) |path| gpa.free(path);

    std.log.info("zigbox: compiling '{s}', entry='{s}'", .{ source_path, entry_symbol });

    var rt = try runtime.Runtime.init(gpa, .{
        .cache_dir = cache_dir,
    });
    defer rt.deinit();

    rt.compileAndRun(source_path, entry_symbol) catch |err| {
        std.log.err("run failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };

    std.log.info("zigbox: entry '{s}' returned cleanly", .{entry_symbol});
}

// Tests for this module are hosted in src/tests.zig, which is the
// root of `zig build test`. Keeping a separate root lets tests run
// without libzig.a being built.
