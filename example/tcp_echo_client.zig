const std = @import("std");
const io = @import("iox");
const mem = std.mem;
const net = std.net;
const posix = std.posix;
const assert = std.debug.assert;

const log = std.log.scoped(.tcp);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var io_loop: io.Loop = undefined;
    try io_loop.init(allocator, .{});
    defer io_loop.deinit();

    const addr = net.Address.initIp4([4]u8{ 0, 0, 0, 0 }, 9000);
    var conn: Conn = undefined;
    conn.init(allocator, &io_loop, addr);
    defer conn.deinit();

    _ = try io_loop.run();
}

const Conn = struct {
    const Self = @This();

    allocator: mem.Allocator,
    tcp_cli: io.tcp.Client(*Self),
    send_len: usize = 1,

    pub fn init(self: *Self, allocator: mem.Allocator, io_loop: *io.Loop, addr: net.Address) void {
        self.* = .{
            .allocator = allocator,
            .tcp_cli = io.tcp.Client(*Self).init(allocator, io_loop, self, addr),
        };
        self.tcp_cli.connect();
    }

    pub fn deinit(self: *Self) void {
        self.tcp_cli.deinit();
    }

    pub fn onConnect(self: *Self) !void {
        try self.send();
    }

    pub fn onRecv(self: *Self, bytes: []const u8) !usize {
        if (bytes.len == self.send_len) {
            for (0..bytes.len) |i| assert(bytes[i] == @as(u8, @intCast(i % 256)));
            try self.send();
            log.debug("recv {} bytes done", .{bytes.len});
            return bytes.len;
        }
        log.debug("recv {} bytes waiting for more", .{bytes.len});
        return 0;
    }

    fn send(self: *Self) !void {
        if (self.send_len > 1024 * 1024) {
            self.tcp_cli.close();
            return;
        }

        self.send_len *= 2;
        const buf = try self.allocator.alloc(u8, self.send_len);
        for (0..buf.len) |i| buf[i] = @intCast(i % 256);
        log.debug("sending {} bytes", .{buf.len});

        try self.tcp_cli.sendZc(buf);
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
