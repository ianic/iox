const std = @import("std");
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
    pub const BufferedConn = _tcp.BufferedConn;
    pub const Server = _tcp.Server;
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

pub fn ConnectionPool(comptime T: type) type {
    return struct {
        const Self = @This();

        pool: std.heap.MemoryPool(T),
        conns: std.AutoHashMap(*T, void),

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .pool = std.heap.MemoryPool(T).init(allocator),
                .conns = std.AutoHashMap(*T, void).init(allocator),
            };
        }

        pub fn create(self: *Self) !*T {
            try self.conns.ensureUnusedCapacity(1);
            const conn = try self.pool.create();
            self.conns.putAssumeCapacityNoClobber(conn, {});
            return conn;
        }

        pub fn destroy(self: *Self, conn: *T) void {
            std.debug.assert(self.conns.remove(conn));
            self.pool.destroy(conn);
        }

        pub fn deinit(self: *Self) void {
            var iter = self.conns.keyIterator();
            while (iter.next()) |k| {
                const conn = k.*;
                conn.deinit();
            }

            self.conns.deinit();
            self.pool.deinit();
        }
    };
}
