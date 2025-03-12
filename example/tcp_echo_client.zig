const std = @import("std");
const io = @import("iox");
const mem = std.mem;
const net = std.net;
const posix = std.posix;
const assert = std.debug.assert;

const log = std.log.scoped(.client);
pub const std_options = std.Options{ .log_level = .debug };

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var io_loop: io.Loop = undefined;
    try io_loop.init(allocator, .{});
    defer io_loop.deinit();

    var handler: Handler = undefined;
    handler.init(allocator, &io_loop);
    defer handler.deinit();

    const addr = net.Address.initIp4([4]u8{ 127, 0, 0, 1 }, 9000);
    handler.tcp.connect(addr);

    _ = try io_loop.run();
}

const Handler = struct {
    const Self = @This();
    const Tcp = io.tcp.BufferedConn(Self);

    allocator: mem.Allocator,
    tcp: Tcp,
    send_len: usize = 1,

    fn init(self: *Self, allocator: mem.Allocator, io_loop: *io.Loop) void {
        self.* = .{
            .allocator = allocator,
            .tcp = undefined,
        };
        self.tcp.init(allocator, io_loop, self, .{});
    }

    fn deinit(self: *Self) void {
        self.tcp.deinit();
    }

    pub fn onError(_: *Self, err: anyerror) void {
        log.err("on error {}", .{err});
    }

    pub fn onConnect(self: *Self) !void {
        try self.send();
    }

    pub fn onRecv(self: *Self, bytes: []const u8) !usize {
        if (bytes.len == self.send_len) {
            for (0..bytes.len) |i| assert(bytes[i] == @as(u8, @intCast(i % 256)));
            try self.send();
            log.debug("recv {} bytes", .{bytes.len});
            return bytes.len;
        }
        // log.debug("recv {} bytes waiting for more", .{bytes.len});
        return 0;
    }

    fn send(self: *Self) !void {
        if (self.send_len > 1024 * 1024 * 8) {
            self.tcp.close();
            return;
        }

        self.send_len *= 2;
        const buf = try self.allocator.alloc(u8, self.send_len);
        errdefer self.allocator.free(buf);
        for (0..buf.len) |i| buf[i] = @intCast(i % 256);
        // log.debug("sending {} bytes", .{buf.len});

        try self.tcp.sendZc(buf);
        // example of sendVZc
        // try self.tcp_cli.sendVZc(&[_][]const u8{buf});

    }

    pub fn onSend(self: *Self, buf: []const u8) void {
        self.allocator.free(buf);
    }

    pub fn onClose(self: *Self) void {
        log.debug("{*} closed", .{self});
        posix.raise(posix.SIG.USR1) catch {};
    }
};
