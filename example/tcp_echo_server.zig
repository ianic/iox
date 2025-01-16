const std = @import("std");
const io = @import("iox");
const mem = std.mem;
const net = std.net;
const posix = std.posix;

const log = std.log.scoped(.tcp);

// Start server:
//   $ zig build && zig-out/bin/tcp_echo
// Send file and receive echo output:
//   $ nc -w 1 localhost 9000 < some-file-name
// Send some text:
//   $ echo '1\n2\n3' | nc -w 1 localhost 9000
//
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var io_loop: io.Loop = undefined;
    try io_loop.init(allocator, .{});
    defer io_loop.deinit();

    var factory: Factory = .{ .allocator = allocator };
    defer factory.deinit();

    var listener = Listener.init(allocator, &io_loop, &factory);
    defer listener.deinit();
    const addr = net.Address.initIp4([4]u8{ 0, 0, 0, 0 }, 9000);
    try listener.bind(addr);

    _ = try io_loop.run();
}

const Listener = io.tcp.Listener(Factory, Conn);

const Factory = struct {
    const Self = @This();

    allocator: mem.Allocator,

    fn deinit(_: *Self) void {}

    pub fn onAccept(
        self: *Self,
        conn: *Conn,
        tcp_conn: *Listener.Conn,
        socket: posix.socket_t,
        addr: net.Address,
    ) void {
        conn.* = .{
            .allocator = self.allocator,
            .tcp_conn = tcp_conn,
        };
        log.debug("{*} connected socket: {}, addr: {}", .{ conn, socket, addr });
    }

    pub fn onError(_: *Self, err: anyerror) void {
        log.err("listener on error {}", .{err});
    }

    pub fn onClose(_: *Self) void {
        log.debug("listener closed ", .{});
    }
};

const Conn = struct {
    const Self = @This();

    allocator: mem.Allocator,
    tcp_conn: *Listener.Conn,

    pub fn deinit(_: *Self) void {}

    pub fn onRecv(self: *Self, bytes: []const u8) usize {
        // log.debug("{*} recv {} bytes", .{ self, bytes.len });
        self.send(bytes) catch |err| {
            log.err("send {}", .{err});
            self.tcp_conn.close();
        };
        return bytes.len;
    }

    fn send(self: *Self, bytes: []const u8) !void {
        const buf = try self.allocator.dupe(u8, bytes);
        try self.tcp_conn.sendZc(buf);
    }

    pub fn onSend(self: *Self, buf: []const u8) void {
        self.allocator.free(buf);
    }

    pub fn onClose(self: *Self) void {
        log.debug("{*} closed", .{self});
    }

    pub fn onError(self: *Self, err: anyerror) void {
        log.err("{*} on error {}", .{ self, err });
    }
};
