const std = @import("std");
const builtin = @import("builtin");
const io = @import("iox");
const mem = std.mem;
const net = std.net;
const posix = std.posix;
const assert = std.debug.assert;

const log = std.log.scoped(.client);
//pub const std_options = std.Options{ .log_level = .debug };
var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

pub fn main() !void {
    const allocator, const is_debug = gpa: {
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseSmall => .{ std.heap.smp_allocator, false },
            .ReleaseFast => .{ std.heap.c_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    var io_loop: io.Loop = undefined;
    try io_loop.init(allocator, .{});
    defer io_loop.deinit();

    var prng = std.Random.DefaultPrng.init(std.testing.random_seed);
    const random = prng.random();

    buffer = try allocator.alloc(u8, msg_len_to);
    random.bytes(buffer);
    defer allocator.free(buffer);

    const addr = net.Address.initIp4([4]u8{ 127, 0, 0, 1 }, 9000);

    var handlers: [128]Handler = undefined;
    for (&handlers) |*handler| {
        try handler.init(allocator, &io_loop, random);
        handler.tcp.connect(addr);
    }

    // var handler: Handler = undefined;
    // try handler.init(allocator, &io_loop, random);
    // defer handler.deinit();
    // handler.tcp.connect(addr);

    _ = try io_loop.run();

    for (&handlers) |*handler| {
        handler.deinit();
    }
}

const msg_len_from = 16;
const msg_len_to = 64 * 1024;
var buffer: []u8 = &.{};

const Handler = struct {
    const Self = @This();
    const Tcp = io.tcp.BufferedConn(Self);

    allocator: mem.Allocator,
    tcp: Tcp,
    random: std.Random,
    max_send_len: usize = msg_len_from,
    in_flight: std.ArrayList([]const u8),

    fn init(self: *Self, allocator: mem.Allocator, io_loop: *io.Loop, random: std.Random) !void {
        self.* = .{
            .allocator = allocator,
            .tcp = undefined,
            .in_flight = try std.ArrayList([]const u8).initCapacity(allocator, 128),
            .random = random,
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
        //log.debug("onConnect", .{});
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
            const send_len = self.random.intRangeAtMost(usize, 1, self.max_send_len);
            self.max_send_len *= 2;
            if (self.max_send_len >= msg_len_to) self.max_send_len = msg_len_from;

            const buf = buffer[0..send_len];
            try self.tcp.send(buf);
            //log.debug("send {} bytes", .{buf.len});
            self.in_flight.appendAssumeCapacity(buf);
        }
    }

    pub fn onSend(_: *Self, _: []const u8) void {
        // self.allocator.free(buf);
    }

    pub fn onClose(self: *Self) void {
        log.debug("{*} closed", .{self});
        // posix.raise(posix.SIG.USR1) catch {};
    }
};
