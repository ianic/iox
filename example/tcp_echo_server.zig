const std = @import("std");
const io = @import("iox");
const assert = std.debug.assert;
const mem = std.mem;
const net = std.net;
const posix = std.posix;
const ConnectionPool = io.ConnectionPool(Conn);

const log = std.log.scoped(.server);

// Start server:
//   $ zig build && zig-out/bin/tcp_echo_server
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

    const addr = net.Address.initIp4([4]u8{ 0, 0, 0, 0 }, 9000);
    var server: Server = undefined;
    try server.bind(allocator, &io_loop, addr);
    defer server.deinit();

    _ = try io_loop.run();
}

const Server = struct {
    const Self = @This();

    allocator: mem.Allocator,
    pool: ConnectionPool,
    tcp: io.tcp.Server(Server),

    fn bind(self: *Self, allocator: mem.Allocator, io_loop: *io.Loop, addr: net.Address) !void {
        self.* = .{
            .allocator = allocator,
            .pool = ConnectionPool(Conn).init(allocator),
            .tcp = undefined,
        };
        self.tcp = .init(io_loop, self);
        try self.tcp.bind(addr);
    }

    fn deinit(self: *Self) void {
        self.pool.deinit();
    }

    pub fn onAccept(self: *Self, io_loop: *io.Loop, socket: posix.socket_t, _: net.Address) io.Error!void {
        const conn = try self.pool.create();
        conn.* = .{
            .allocator = self.allocator,
            .pool = &self.pool,
            .tcp = undefined,
        };
        conn.tcp.init(self.allocator, io_loop, conn, .{});
        conn.tcp.accept(socket);
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
    pool: *ConnectionPool,
    tcp: io.tcp.BufferedConn(Self),

    pub fn deinit(self: *Self) void {
        self.tcp.deinit();
    }

    pub fn onConnect(self: *Self) void {
        log.debug("{*} connected socket: {} ", .{ self, self.tcp.conn.socket });
    }

    pub fn onRecv(self: *Self, bytes: []const u8) usize {
        //log.debug("{*} recv {} bytes", .{ self, bytes.len });
        self.send(bytes) catch |err| {
            log.err("send {}", .{err});
            self.tcp.close();
        };
        return bytes.len;
    }

    fn send(self: *Self, bytes: []const u8) !void {
        const buf = try self.allocator.dupe(u8, bytes);
        try self.tcp.sendZc(buf);
    }

    pub fn onSend(self: *Self, buf: []const u8) void {
        self.allocator.free(buf);
    }

    pub fn onClose(self: *Self) void {
        log.debug("{*} closed", .{self});
        self.deinit();
        self.pool.destroy(self);
    }

    pub fn onError(self: *Self, err: anyerror) void {
        log.err("{*} on error {}", .{ self, err });
    }
};
