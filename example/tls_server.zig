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
    var auth = try io.tls.options.CertKeyPair.load(allocator, dir, "localhost_ec/cert.pem", "localhost_ec/key.pem");
    defer auth.deinit(allocator);
    const opt: io.tls.options.Server = .{ .auth = auth };

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
    parent: io.tcp.Listener(*Self, Conn),
    tls_opt: io.tls.options.Server,

    pub fn init(
        self: *Self,
        allocator: mem.Allocator,
        io_loop: *io.Loop,
        socket: posix.socket_t,
        tls_opt: io.tls.options.Server,
    ) !void {
        self.* = .{
            .allocator = allocator,
            .socket = socket,
            .io_loop = io_loop,
            .parent = io.tcp.Listener(*Self, Conn).init(allocator, io_loop, socket, self),
            .tls_opt = tls_opt,
        };
        self.parent.run();
    }

    pub fn deinit(self: *Self) void {
        self.parent.deinit();
    }

    /// Called by parent listener when it accepts new tcp connection.
    pub fn onAccept(self: *Self, conn: *Conn, socket: posix.socket_t, addr: net.Address) !void {
        // Init connection
        conn.* = .{ .listener = self, .tls_conn = undefined };
        // Init tls
        try conn.tls_conn.init(self.allocator, self.io_loop, conn, socket, self.tls_opt);
        log.debug("{*} connected socket: {} addr: {}", .{ conn, socket, addr });
    }

    /// Called when parent listener is closed.
    pub fn onClose(_: *Self) void {}

    pub fn destroy(self: *Self, conn: *Conn) void {
        self.parent.destroy(conn);
    }
};

const Conn = struct {
    const Self = @This();

    listener: *Listener,
    tls_conn: io.tls.Conn(*Self),

    pub fn deinit(self: *Self) void {
        self.tls_conn.deinit();
    }

    /// Called by tls connection when it successfully finishes handshake.
    pub fn onConnect(_: *Self) !void {
        // tls handshake is done
    }

    /// Called by tls connection with cleartext data when it receives chipertext
    /// and decrytps it.
    pub fn onRecv(self: *Self, bytes: []const u8) !void {
        try self.tls_conn.send(bytes);
    }

    /// Called by tls connection when it is closed.
    pub fn onClose(self: *Self) void {
        log.debug("{*} closed", .{self});
        self.deinit();
        self.listener.destroy(self);
    }
};

pub fn listenSocket(addr: net.Address) !posix.socket_t {
    return (try addr.listen(.{ .reuse_address = true })).stream.handle;
}
