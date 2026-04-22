//! runtime.zig — orchestrator gluing compiler + loader + bridge.
//!
//! The public surface is intentionally small: init / compile /
//! callEntry / deinit. This is the API that future UI layers
//! (desktop GUI, Android Activity, iOS app) will talk to.
//!
//! The compiler in `compiler.zig` and the loader in `platform.zig`
//! are the swappable parts. For iOS a future signer module will
//! sit between compile() and callEntry().

const std = @import("std");
const builtin = @import("builtin");

const compiler = @import("compiler.zig");
const platform = @import("platform.zig");
const bridge = @import("bridge.zig");

// bridge.zig must be referenced somewhere so its `export` symbols
// are actually emitted into the host's dynamic symbol table. A bare
// `_ = @import(...)` at container scope is enough.
comptime {
    _ = @import("bridge.zig");
}

pub const Error = error{
    NoEntryPoint,
} || compiler.CompileError || platform.LoadError;

pub const Options = struct {
    /// Where to place intermediate artifacts. Default: OS tmp dir.
    cache_dir: ?[]const u8 = null,
    optimize: compiler.Optimize = .Debug,
};

pub const Runtime = struct {
    gpa: std.mem.Allocator,
    cache_dir_path: []const u8,
    owns_cache_dir: bool,
    keep_cache_dir: bool,

    pub fn init(gpa: std.mem.Allocator, opts: Options) !Runtime {
        const cache_dir = opts.cache_dir orelse blk: {
            // Pick a subdir inside the system tmp dir to avoid
            // colliding with other zigbox invocations.
            // Portable tmp dir resolution: TMPDIR on POSIX, TEMP on
            // Windows, falling back to /tmp. A random suffix isolates
            // concurrent zigbox runs from each other.
            const tmp_base = std.process.getEnvVarOwned(gpa, "TMPDIR") catch
                std.process.getEnvVarOwned(gpa, "TEMP") catch
                try gpa.dupe(u8, "/tmp");
            defer gpa.free(tmp_base);

            var rand_bytes: [8]u8 = undefined;
            std.crypto.random.bytes(&rand_bytes);
            const path = try std.fmt.allocPrint(
                gpa,
                "{s}/zigbox-{}",
                .{ tmp_base, std.fmt.fmtSliceHexLower(&rand_bytes) },
            );
            std.fs.makeDirAbsolute(path) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
            break :blk path;
        };

        return .{
            .gpa = gpa,
            .cache_dir_path = cache_dir,
            .owns_cache_dir = (opts.cache_dir == null),
            .keep_cache_dir = std.process.hasEnvVarConstant("ZIGBOX_KEEP_CACHE"),
        };
    }

    pub fn deinit(self: *Runtime) void {
        if (self.owns_cache_dir and !self.keep_cache_dir) {
            // Best-effort cleanup. Ignore errors.
            std.fs.deleteTreeAbsolute(self.cache_dir_path) catch {};
            self.gpa.free(self.cache_dir_path);
        } else if (self.owns_cache_dir) {
            std.log.warn("preserving cache dir: {s}", .{self.cache_dir_path});
        }
    }

    /// Compile `source_path` to a dynamic library inside the cache
    /// dir. Returns the absolute path of the produced artifact.
    /// The caller is responsible for freeing the returned slice.
    pub fn compile(self: *Runtime, source_path: []const u8) ![]u8 {
        const out_path = try std.fmt.allocPrint(
            self.gpa,
            "{s}/user_code{s}",
            .{ self.cache_dir_path, compiler.dynlibExtension() },
        );
        errdefer self.gpa.free(out_path);

        try compiler.compileDynamic(self.gpa, .{
            .source_path = source_path,
            .output_path = out_path,
            .name = "user_code",
            .optimize = .Debug,
        });
        return out_path;
    }

    /// Load a compiled artifact, look up `entry_symbol`, call it
    /// as `fn () callconv(.C) void`, then unload.
    pub fn runEntry(
        self: *Runtime,
        artifact_path: []const u8,
        entry_symbol: []const u8,
    ) Error!void {
        var lib = try platform.DynamicLib.open(self.gpa, artifact_path);
        defer lib.close();

        const sym = try lib.lookup(self.gpa, entry_symbol);
        const EntryFn = *const fn () callconv(.C) void;
        const entry: EntryFn = @ptrCast(@alignCast(sym));
        bridge.clearBufferedLogs();
        entry();
        bridge.flushBufferedLogs();
    }

    /// Convenience: compile + run in one shot.
    pub fn compileAndRun(
        self: *Runtime,
        source_path: []const u8,
        entry_symbol: []const u8,
    ) !void {
        const artifact = try self.compile(source_path);
        defer self.gpa.free(artifact);
        try self.runEntry(artifact, entry_symbol);
    }
};

test "Runtime.init/deinit round-trip (skipped if tmp dir unusable)" {
    var rt = Runtime.init(std.testing.allocator, .{}) catch |err| switch (err) {
        error.AccessDenied, error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer rt.deinit();
    try std.testing.expect(rt.cache_dir_path.len > 0);
}
