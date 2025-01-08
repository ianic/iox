const io = @import("io.zig");

pub const Loop = io.Loop;
pub const Op = io.Op;
pub const Error = io.Error;
pub const Options = io.Options;

pub const tcp = struct {
    const tcp_ = @import("tcp.zig");
    pub const Conn = tcp_.Conn;
    pub const Listener = tcp_.Listener;
};

pub const udp = struct {
    pub const Sender = @import("udp.zig").Sender;
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
