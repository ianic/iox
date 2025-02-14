const io = @import("io.zig");

pub const Loop = io.Loop;
pub const Op = io.Op;
pub const Error = io.Error;
pub const Options = io.Options;

pub const HandshakeKind = enum {
    client,
    server,
};

pub const tcp = struct {
    const _tcp = @import("tcp.zig");

    pub const Conn = _tcp.Conn;
    pub const Listener = _tcp.Listener;
    pub const Connector = _tcp.Connector;
    pub const Client = _tcp.Client;
};

pub const udp = struct {
    pub const Sender = @import("udp.zig").Sender;
};

pub const tls = struct {
    const _lib = @import("tls");
    const _tls = @import("tls.zig");

    pub const config = _lib.config;
    pub const HandshakeKind = _tls.HandshakeKind;

    pub const Conn = _tls.Conn;
    pub const Connector = _tls.Connector;
    pub const Listener = _tls.Listener;
};

pub const ws = struct {
    const _ws = @import("ws.zig");
    const _lib = @import("ws");

    pub const Msg = _lib.Msg;
    pub const config = _ws.config;

    pub const Conn = _ws.Conn;
    pub const Connector = _ws.Connector;
    pub const Listener = _ws.Listener;
    pub const Client = _ws.Client;
};

pub const timer = @import("timer.zig");

test {
    _ = @import("io.zig");
    _ = @import("tcp.zig");
    _ = @import("udp.zig");
    _ = @import("fifo.zig");
    _ = @import("errno.zig");
    _ = @import("timer.zig");
    _ = @import("ws.zig");
}

// fn dumpStackTrace() void {
//     var address_buffer: [32]usize = undefined;
//     var stack_trace: std.builtin.StackTrace = .{
//         .instruction_addresses = &address_buffer,
//         .index = 0,
//     };
//     std.debug.captureStackTrace(null, &stack_trace);
//     std.debug.dumpStackTrace(stack_trace);
// }
