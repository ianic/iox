const std = @import("std");
const builtin = @import("builtin");
const io = @import("iox");
const mem = std.mem;
const net = std.net;
const posix = std.posix;
const assert = std.debug.assert;
const log = std.log.scoped(.client);

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

var prng = std.Random.DefaultPrng.init(0);
const rnd = prng.random();
// in powers of 2
const msg_len_from: u5 = 4; // 16
const msg_len_to: u5 = 16; // 64k
var buffer: []u8 = &.{};

pub fn main() !void {
    const allocator, const is_debug = gpa: {
        break :gpa switch (builtin.mode) {
            .Debug => .{ debug_allocator.allocator(), true },
            .ReleaseSmall => .{ std.heap.smp_allocator, false },
            .ReleaseFast, .ReleaseSafe => .{ std.heap.c_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    var io_loop: io.Loop = undefined;
    try io_loop.init(allocator, .{});
    defer io_loop.deinit();

    buffer = try allocator.alloc(u8, @as(u32, 1) << msg_len_to);
    rnd.bytes(buffer);
    defer allocator.free(buffer);

    const addr = net.Address.initIp4([4]u8{ 127, 0, 0, 1 }, 9000);

    var handlers: [128]Handler = undefined;
    for (&handlers) |*handler| {
        try handler.init(allocator, &io_loop);
        handler.tcp.connect(addr);
    }

    _ = try io_loop.run();

    for (&handlers) |*handler| {
        handler.deinit();
    }
}

const Handler = struct {
    const Self = @This();
    const Tcp = io.tcp.BufferedConn(Self);

    allocator: mem.Allocator,
    tcp: Tcp,
    max_send_len: usize = msg_len_from,
    in_flight: std.ArrayList([]const u8),

    fn init(self: *Self, allocator: mem.Allocator, io_loop: *io.Loop) !void {
        self.* = .{
            .allocator = allocator,
            .tcp = undefined,
            .in_flight = try std.ArrayList([]const u8).initCapacity(allocator, 128),
        };
        self.tcp.init(allocator, io_loop, self, .{});
    }

    fn deinit(self: *Self) void {
        self.in_flight.deinit();
        self.tcp.deinit();
    }

    pub fn onError(_: *Self, err: anyerror) void {
        log.err("on error {}", .{err});
    }

    pub fn onConnect(self: *Self) !void {
        log.debug("{*} onConnect", .{self});
        try self.send();
    }

    pub fn onRecv(self: *Self, bytes: []const u8) !usize {
        var consumed: usize = 0;
        while (self.in_flight.items.len > 0) {
            const expected_bytes = self.in_flight.items[0].len;
            const recv_buf = bytes[consumed..];
            if (expected_bytes > recv_buf.len) break;

            const buf = self.in_flight.orderedRemove(0);
            assert(std.mem.eql(u8, recv_buf[0..expected_bytes], buf));
            consumed += expected_bytes;
        }
        try self.send();
        return consumed;
    }

    fn send(self: *Self) !void {
        if (self.in_flight.items.len != 0) return;

        for (0..self.in_flight.capacity) |_| {
            const send_len = randomMsgLen(msg_len_from, msg_len_to);
            const buf = buffer[0..send_len];
            try self.tcp.send(buf);
            self.in_flight.appendAssumeCapacity(buf);
        }
    }

    pub fn onSend(_: *Self, _: []const u8) void {}

    pub fn onClose(self: *Self) void {
        log.debug("{*} closed", .{self});
    }
};

// In the range of powers of two.
fn randomMsgLen(minp: u5, maxp: u5) usize {
    return rnd.intRangeAtMost(
        usize,
        @as(u32, 1) << minp,
        // First choose slot
        @as(u32, 1) << rnd.intRangeAtMostBiased(u5, minp, maxp),
    );
}
