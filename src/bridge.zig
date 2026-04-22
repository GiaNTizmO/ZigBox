//! bridge.zig — host functions callable from dlopen'd user code.
//!
//! Every function here is `export` with C ABI, so user code can
//! import them with `extern fn host_xxx(...) ...;` and the dynamic
//! linker will resolve them against the host executable at dlopen
//! time. For this to work the host is linked with `rdynamic` (see
//! build.zig) — otherwise these symbols are stripped from the
//! dynamic symbol table even though they're marked `export`.
//!
//! Keep the surface area small and C-only (no Zig errors, no slices
//! across the boundary). Everything is nul-terminated or length-
//! prefixed. This is the same boundary that user code compiled on
//! any supported platform will cross, so it must stay stable.

const std = @import("std");

var log_mutex: std.Thread.Mutex = .{};
var log_buffer: std.ArrayListUnmanaged(u8) = .empty;

/// host_log(message) — print a line to the host's stderr.
/// `message` must be a nul-terminated UTF-8 string.
export fn host_log(message: [*:0]const u8) callconv(.C) void {
    const slice = std.mem.sliceTo(message, 0);
    log_mutex.lock();
    defer log_mutex.unlock();

    log_buffer.appendSlice(std.heap.page_allocator, "[user] ") catch return;
    log_buffer.appendSlice(std.heap.page_allocator, slice) catch return;
    log_buffer.append(std.heap.page_allocator, '\n') catch return;
}

pub fn clearBufferedLogs() void {
    log_mutex.lock();
    defer log_mutex.unlock();
    log_buffer.clearRetainingCapacity();
}

pub fn flushBufferedLogs() void {
    log_mutex.lock();
    defer log_mutex.unlock();

    if (log_buffer.items.len == 0) return;

    const stdout = std.io.getStdOut().writer();
    stdout.writeAll(log_buffer.items) catch {};
    log_buffer.clearRetainingCapacity();
}

/// host_greet(name, out_buf, out_cap) — writes a greeting into
/// out_buf (up to out_cap bytes, including trailing NUL). Returns
/// the number of bytes written (not counting NUL) or -1 on overflow.
///
/// Exists mainly to prove that data can flow user → host → user
/// through the C ABI without allocation on the user side.
export fn host_greet(
    name: [*:0]const u8,
    out_buf: [*]u8,
    out_cap: usize,
) callconv(.C) isize {
    const name_slice = std.mem.sliceTo(name, 0);
    const prefix = "hello, ";
    const needed = prefix.len + name_slice.len + 1; // +1 for NUL
    if (needed > out_cap) return -1;

    @memcpy(out_buf[0..prefix.len], prefix);
    @memcpy(out_buf[prefix.len..][0..name_slice.len], name_slice);
    out_buf[prefix.len + name_slice.len] = 0;
    return @intCast(prefix.len + name_slice.len);
}

test "host_greet happy path" {
    var buf: [64]u8 = undefined;
    const n = host_greet("zigbox", &buf, buf.len);
    try std.testing.expect(n > 0);
    const written = buf[0..@as(usize, @intCast(n))];
    try std.testing.expectEqualStrings("hello, zigbox", written);
    try std.testing.expectEqual(@as(u8, 0), buf[@as(usize, @intCast(n))]);
}

test "host_greet overflow" {
    var buf: [4]u8 = undefined;
    const n = host_greet("zigbox", &buf, buf.len);
    try std.testing.expectEqual(@as(isize, -1), n);
}
