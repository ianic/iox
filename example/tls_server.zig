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

    // use certs from tls.zig project
    const dir = try std.fs.cwd().openDir("../tls.zig/example/cert", .{});
    // Load server certificate key pair
    var auth = try io.tls.CertKeyPair.load(allocator, dir, "localhost_ec/cert.pem", "localhost_ec/key.pem");
    defer auth.deinit(allocator);
    const opt: io.tls.ServerOptions = .{ .auth = auth };

    var io_loop: io.Loop = undefined;
    try io_loop.init(allocator, .{});
    defer io_loop.deinit();

    const addr = net.Address.initIp4([4]u8{ 0, 0, 0, 0 }, 9443);
    var listener: Listener = undefined;
    try listener.init(allocator, &io_loop, try listenSocket(addr), opt);
    defer listener.deinit();

    _ = try io_loop.run();
}

const Listener = struct {
    const Self = @This();

    allocator: mem.Allocator,
    socket: posix.socket_t,
    io_loop: *io.Loop,
    tcp_listener: io.tcp.Listener(*Self, Conn),
    opt: io.tls.ServerOptions,

    pub fn init(
        self: *Self,
        allocator: mem.Allocator,
        io_loop: *io.Loop,
        socket: posix.socket_t,
        opt: io.tls.ServerOptions,
    ) !void {
        self.* = .{
            .allocator = allocator,
            .socket = socket,
            .io_loop = io_loop,
            .tcp_listener = undefined,
            .opt = opt,
        };
        self.tcp_listener.init(allocator, io_loop, socket, self);
    }

    pub fn deinit(self: *Self) void {
        self.tcp_listener.deinit();
    }

    pub fn onAccept(self: *Self, conn: *Conn, socket: posix.socket_t, addr: net.Address) !void {
        try conn.init(self, socket, addr, self.opt);
    }

    pub fn onClose(_: *Self) void {}

    pub fn destroy(self: *Self, conn: *Conn) void {
        self.tcp_listener.destroy(conn);
    }
};

const Conn = struct {
    allocator: mem.Allocator,
    listener: *Listener,
    tls: io.tls.Server(*Conn),
    socket: posix.socket_t,

    fn init(
        self: *Conn,
        listener: *Listener,
        socket: posix.socket_t,
        addr: net.Address,
        opt: io.tls.ServerOptions,
    ) !void {
        const allocator = listener.allocator;
        self.* = .{
            .allocator = allocator,
            .listener = listener,
            .socket = socket,
            .tls = undefined,
        };
        self.tls.init(allocator, listener.io_loop, self);
        try self.tls.connected(socket, addr, opt);
        log.debug("{} connected {}", .{ socket, addr });
    }

    pub fn onConnect(_: *Conn) !void {
        // handshake is done
    }

    pub fn deinit(self: *Conn) void {
        self.tls.deinit();
    }

    pub fn onRecv(self: *Conn, bytes: []const u8) !void {
        try self.tls.send(bytes);
    }

    pub fn onClose(self: *Conn) void {
        log.debug("{} closed", .{self.socket});
        self.deinit();
        self.listener.destroy(self);
    }
};

pub fn listenSocket(addr: net.Address) !posix.socket_t {
    return (try addr.listen(.{ .reuse_address = true })).stream.handle;
}
