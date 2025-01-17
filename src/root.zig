const io = @import("io.zig");

pub const Loop = io.Loop;
pub const Op = io.Op;
pub const Error = io.Error;
pub const Options = io.Options;

pub const tcp = struct {
    const _tcp = @import("tcp.zig");
    pub const Conn = _tcp.Conn;
    pub const Listener = _tcp.Listener;
    pub const Client = _tcp.Client;
};

pub const udp = struct {
    pub const Sender = @import("udp.zig").Sender;
};

pub const tls = struct {
    const _lib = @import("tls");
    const _tls = @import("tls.zig");

    pub const config = _lib.config;
    pub const Client = _tls.Client;
    pub const Conn = _tls.Conn;
};

pub const timer = @import("timer.zig");

test {
    _ = @import("io.zig");
    _ = @import("tcp.zig");
    _ = @import("udp.zig");
    _ = @import("fifo.zig");
    _ = @import("errno.zig");
    _ = @import("timer.zig");
}
