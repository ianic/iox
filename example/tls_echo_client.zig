const std = @import("std");
const io = @import("iox");
const mem = std.mem;
const net = std.net;
const posix = std.posix;
const assert = std.debug.assert;
const builtin = @import("builtin");
const log = std.log.scoped(.client);

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

pub fn main() !void {
    const allocator, const is_debug = gpa: {
        break :gpa switch (builtin.mode) {
            .Debug => .{ debug_allocator.allocator(), true },
            else => .{ std.heap.c_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    // tls config
    const dir = try std.fs.cwd().openDir("../tls.zig/example/cert", .{});
    var root_ca = try io.tls.config.CertBundle.fromFile(allocator, dir, "minica.pem");
    defer root_ca.deinit(allocator);
    var diagnostic: io.tls.config.Client.Diagnostic = .{};
    const config: io.tls.config.Client = .{
        .host = "localhost",
        .root_ca = root_ca,
        .diagnostic = &diagnostic,
        // example of how to get handshake failure, use some really old cipher
        // .cipher_suites = &[_]io.tls.options.CipherSuite{.RSA_WITH_AES_128_CBC_SHA},
    };
    const addr = net.Address.initIp4([4]u8{ 0, 0, 0, 0 }, 9443);

    var io_loop: io.Loop = undefined;
    try io_loop.init(allocator, .{});
    defer io_loop.deinit();

    var prng = std.Random.DefaultPrng.init(std.testing.random_seed);
    const random = prng.random();

    buffer = try allocator.alloc(u8, msg_len_to);
    random.bytes(buffer);

    // Start handlers
    var handlers: [256]Handler = undefined;
    for (&handlers) |*handler| {
        handler.* = .{
            .allocator = allocator,
            .tls = undefined,
            .random = random,
            // Number of in flight messages of each handler
            .in_flight = try std.ArrayList([]const u8).initCapacity(allocator, 512),
        };
        try handler.tls.init(allocator, &io_loop, handler, config);

        handler.tls.connect(addr);
    }

    _ = try io_loop.run();

    for (&handlers) |*handler| {
        handler.deinit();
    }
}

var buffer: []u8 = &.{};
const msg_len_from = 16;
const msg_len_to = 64 * 1024;

const Handler = struct {
    const Self = @This();

    allocator: mem.Allocator,
    random: std.Random,
    tls: io.tls.Client(Self),
    current_max_msg_len: usize = msg_len_from,
    in_flight: std.ArrayList([]const u8),

    pub fn deinit(self: *Self) void {
        self.tls.deinit();
    }

    pub fn onConnect(self: *Self) !void {
        try self.send();
    }

    pub fn onRecv(self: *Self, bytes: []const u8) !usize {
        var n: usize = 0; // number of bytes consumed
        while (self.in_flight.items.len > 0) {
            // Expect echoed message equal to  the first one sent
            const msg = self.in_flight.items[0];
            if (msg.len > bytes[n..].len) break; // Wait for more data
            const echo_msg = bytes[n..][0..msg.len];
            assert(std.mem.eql(u8, echo_msg, msg));

            _ = self.in_flight.orderedRemove(0);
            n += msg.len;
        }
        try self.send();
        return n;
    }

    fn send(self: *Self) !void {
        // Skip if in_flight is still half full
        if (self.in_flight.items.len * 2 > self.in_flight.capacity) return;

        // Send random size messages
        for (self.in_flight.items.len..self.in_flight.capacity) |_| {
            const send_len = self.random.intRangeAtMost(usize, 2, self.current_max_msg_len);
            self.current_max_msg_len *= 2;
            if (self.current_max_msg_len >= msg_len_to)
                self.current_max_msg_len = msg_len_from;

            // All messages are part of shared buffer
            const msg = buffer[0..send_len];
            self.in_flight.appendAssumeCapacity(msg);
            try self.tls.send(msg);
        }
    }

    pub fn onSend(_: *Self, _: []const u8) void {
        // no free, using fixed buffer in send
        // self.allocator.free(buf);
    }

    pub fn onClose(self: *Self) void {
        log.debug("{*} closed", .{self});
        // posix.raise(posix.SIG.USR1) catch {};
    }

    pub fn onError(self: *Self, err: anyerror) void {
        log.err("{*} {}", .{ self, err });
    }
};
