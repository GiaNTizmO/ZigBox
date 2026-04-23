extern fn host_log(msg: [*:0]const u8) void;

export fn entry() callconv(.C) void {
    host_log("hello from user code");
}
