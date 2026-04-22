const std = @import("std");

export fn entry() callconv(.C) void {
    std.debug.print("Hello, World!\n", .{});
}
