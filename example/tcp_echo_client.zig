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

    var factory = Factory.init(allocator);
    defer factory.deinit();

    const addr = net.Address.initIp4([4]u8{ 127, 0, 0, 1 }, 9000);
    var connector = io.tcp.Connector(Factory).init(allocator, &io_loop, &factory, addr);
    connector.connect();

    _ = try io_loop.run();
}

const Factory = struct {
    const Self = @This();

    allocator: mem.Allocator,
    handler: ?*Handler = null,

    fn init(allocator: mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *Self) void {
        if (self.handler) |handler| {
            handler.deinit();
            self.allocator.destroy(handler);
        }
    }

    pub fn create(self: *Self) !struct { *Handler, *io.tcp.Conn(Handler) } {
        const handler = try self.allocator.create(Handler);
        handler.* = .{
            .allocator = self.allocator,
            .tcp = undefined,
        };
        self.handler = handler;
        return .{ handler, &handler.tcp };
    }

    pub fn onError(_: *Self, err: anyerror) void {
        log.err("connect error {}", .{err});
    }

    pub fn onClose(_: *Self) void {
        log.debug("connector closed ", .{});
        posix.raise(posix.SIG.USR1) catch {};
    }
};

const Handler = struct {
    const Self = @This();
    const Tcp = io.tcp.Conn(Self);

    allocator: mem.Allocator,
    tcp: Tcp,
    send_len: usize = 1,

    fn deinit(self: *Self) void {
        self.tcp.deinit();
    }

    pub fn onError(_: *Self, err: anyerror) void {
        log.err("on error {}", .{err});
    }

    pub fn onConnect(self: *Self) void {
        self.send();
    }

    pub fn onRecv(self: *Self, bytes: []const u8) usize {
        if (bytes.len == self.send_len) {
            for (0..bytes.len) |i| assert(bytes[i] == @as(u8, @intCast(i % 256)));
            self.send();
            log.debug("recv {} bytes", .{bytes.len});
            return bytes.len;
        }
        // log.debug("recv {} bytes waiting for more", .{bytes.len});
        return 0;
    }

    fn send(self: *Self) void {
        self.send_() catch |err| {
            log.err("send failed {}", .{err});
            self.tcp.close();
        };
    }

    fn send_(self: *Self) !void {
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
