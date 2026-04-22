//! use_bridge.zig — exercises both bridge functions round-trip.
//!
//! Run with:
//!     zig build run -- examples/use_bridge.zig

const std = @import("std");

extern fn host_log(msg: [*:0]const u8) void;
extern fn host_greet(name: [*:0]const u8, out_buf: [*]u8, out_cap: usize) isize;

export fn entry() callconv(.C) void {
    host_log("calling host_greet…");

    var buf: [64]u8 = undefined;
    const n = host_greet("Gamania", &buf, buf.len);
    if (n < 0) {
        host_log("host_greet: buffer too small");
        return;
    }
    // buf is now NUL-terminated at index n, so pass it through as
    // a C string. We use a second buffer to append a prefix so the
    // output is unambiguous in the host log.
    var prefixed: [128]u8 = undefined;
    const written = std.fmt.bufPrintZ(&prefixed, "greeting: {s}", .{buf[0..@intCast(n)]}) catch {
        host_log("format failed");
        return;
    };
    host_log(written.ptr);
}
