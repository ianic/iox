const std = @import("std");
const io = @import("iox");
const mem = std.mem;
const net = std.net;
const posix = std.posix;
const assert = std.debug.assert;
const log = std.log.scoped(.server);

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

    // Use certs from tls.zig project
    const dir = try std.fs.cwd().openDir("../tls.zig/example/cert", .{});
    // Load server certificate key pair
    var auth = try io.tls.config.CertKeyPair.load(allocator, dir, "localhost_ec/cert.pem", "localhost_ec/key.pem");
    defer auth.deinit(allocator);
    const config: io.tls.config.Server = .{ .auth = &auth };

    var io_loop: io.Loop = undefined;
    try io_loop.init(allocator, .{});
    defer io_loop.deinit();

    const addr = net.Address.initIp4([4]u8{ 0, 0, 0, 0 }, 9443);
    var server: Server = undefined;
    try server.bind(allocator, &io_loop, addr, config);
    defer server.deinit();

    _ = try io_loop.run();
}

const ConnectionPool = io.ConnectionPool(Conn);
const TcpServer = io.tcp.Server(Server);
const TlsConn = io.tls.Conn(Conn, .server);
const TlsConfig = io.tls.config.Server;

const Server = struct {
    const Self = @This();

    allocator: mem.Allocator,
    pool: ConnectionPool,
    tcp: TcpServer,
    config: TlsConfig,

    fn bind(
        self: *Self,
        allocator: mem.Allocator,
        io_loop: *io.Loop,
        addr: net.Address,
        config: io.tls.config.Server,
    ) !void {
        self.* = .{
            .allocator = allocator,
            .pool = ConnectionPool.init(allocator),
            .config = config,
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
            .pool = &self.pool,
            .tls = undefined,
        };
        try conn.tls.init(self.allocator, io_loop, conn, self.config);
        conn.tls.accept(socket);
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

    pool: *ConnectionPool,
    tls: TlsConn,

    pub fn deinit(self: *Self) void {
        self.tls.deinit();
    }

    pub fn onConnect(self: *Self) !void {
        log.debug("{*} connected", .{self});
    }

    pub fn onRecv(self: *Self, bytes: []const u8) !usize {
        // In general case should copy bytes and release it in onSend.
        // Using fact that tls.send is making copy.
        try self.tls.send(bytes);
        return bytes.len;
    }

    pub fn onSend(_: *Self, _: []const u8) void {}

    /// Called by tls connection when it is closed.
    pub fn onClose(self: *Self) void {
        log.debug("{*} closed", .{self});
        self.deinit();
        self.pool.destroy(self);
    }

    pub fn onError(self: *Self, err: anyerror) void {
        log.err("{*} on error {}", .{ self, err });
    }
};
