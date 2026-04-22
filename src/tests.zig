//! tests.zig — root of `zig build test`.
//!
//! Host-only. Deliberately does NOT pull in src/compiler.zig,
//! which would transitively require the embedded zig_compiler
//! module (only available once libzig.a has been built via the
//! setup script). Those are exercised by `zig build smoke`.

const std = @import("std");

test {
    _ = @import("platform.zig");
    _ = @import("bridge.zig");
    std.testing.refAllDecls(@import("platform.zig"));
    std.testing.refAllDecls(@import("bridge.zig"));
}
