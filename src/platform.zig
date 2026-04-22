//! platform.zig — cross-platform dynamic library loader.
//!
//! Provides a uniform `DynamicLib` handle over:
//!   - dlopen/dlsym/dlclose   (Linux, macOS, Android, iOS)
//!   - LoadLibrary/…          (Windows)
//!
//! On iOS, dlopen works for signed dylibs that pass amfid checks;
//! the signing step is handled elsewhere (see docs, §9). This
//! module does not care whether the input is signed or not — it
//! just asks the OS to load it.

const std = @import("std");
const builtin = @import("builtin");

pub const LoadError = error{
    OpenFailed,
    SymbolNotFound,
    OutOfMemory,
};

pub const DynamicLib = struct {
    /// Opaque OS handle. void* on POSIX, HMODULE on Windows.
    handle: *anyopaque,

    /// Load a dynamic library from an absolute or relative path.
    /// The returned lib must be freed with `close()`.
    pub fn open(allocator: std.mem.Allocator, path: []const u8) LoadError!DynamicLib {
        if (builtin.os.tag == .windows) {
            // Convert to UTF-16 for LoadLibraryW.
            const wide = std.unicode.utf8ToUtf16LeAllocZ(allocator, path) catch return LoadError.OutOfMemory;
            defer allocator.free(wide);

            const h = std.os.windows.kernel32.LoadLibraryW(wide);
            if (h == null) {
                std.log.err("LoadLibraryW failed for '{s}' (error={d})", .{
                    path,
                    @intFromEnum(std.os.windows.kernel32.GetLastError()),
                });
                return LoadError.OpenFailed;
            }
            return .{ .handle = @ptrCast(h.?) };
        } else {
            // POSIX: dlopen expects a null-terminated string.
            const path_z = allocator.dupeZ(u8, path) catch return LoadError.OutOfMemory;
            defer allocator.free(path_z);

            // RTLD_NOW | RTLD_LOCAL:
            //   NOW   — resolve all symbols up-front so errors fail fast.
            //   LOCAL — symbols from this lib don't leak into later dlopens.
            const flags = std.c.RTLD.NOW | std.c.RTLD.LOCAL;
            const h = std.c.dlopen(path_z.ptr, flags);
            if (h == null) {
                const reason = std.c.dlerror();
                std.log.err("dlopen failed for '{s}': {s}", .{
                    path,
                    if (reason) |r| std.mem.span(r) else "unknown",
                });
                return LoadError.OpenFailed;
            }
            return .{ .handle = h.? };
        }
    }

    /// Look up a symbol in the library. Returns a function or data
    /// pointer, cast by the caller to the appropriate type.
    pub fn lookup(
        self: DynamicLib,
        allocator: std.mem.Allocator,
        name: []const u8,
    ) LoadError!*anyopaque {
        if (builtin.os.tag == .windows) {
            const name_z = allocator.dupeZ(u8, name) catch return LoadError.OutOfMemory;
            defer allocator.free(name_z);

            const proc = std.os.windows.kernel32.GetProcAddress(
                @ptrCast(self.handle),
                name_z.ptr,
            );
            if (proc == null) return LoadError.SymbolNotFound;
            return @ptrCast(proc.?);
        } else {
            const name_z = allocator.dupeZ(u8, name) catch return LoadError.OutOfMemory;
            defer allocator.free(name_z);

            // Clear any pre-existing dlerror state so we can distinguish
            // "symbol resolved to NULL" from "symbol not found".
            _ = std.c.dlerror();
            const sym = std.c.dlsym(self.handle, name_z.ptr);
            if (sym == null) {
                const reason = std.c.dlerror();
                std.log.err("dlsym('{s}') failed: {s}", .{
                    name,
                    if (reason) |r| std.mem.span(r) else "symbol not found",
                });
                return LoadError.SymbolNotFound;
            }
            return sym.?;
        }
    }

    pub fn close(self: DynamicLib) void {
        if (builtin.os.tag == .windows) {
            _ = std.os.windows.kernel32.FreeLibrary(@ptrCast(self.handle));
        } else {
            _ = std.c.dlclose(self.handle);
        }
    }
};

test "DynamicLib surface compiles" {
    // Compile-time-only test — actual dlopen requires a real file.
    _ = DynamicLib;
    _ = LoadError;
}
