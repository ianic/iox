const std = @import("std");
const io = @import("iox");
const mem = std.mem;
const net = std.net;
const posix = std.posix;
const assert = std.debug.assert;

const log = std.log.scoped(.server);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var io_loop: io.Loop = undefined;
    try io_loop.init(allocator, .{});
    defer io_loop.deinit();

    const config = io.ws.config.Server{ .scheme = .ws, .uri = "ws://localhost:9002" };
    const addr = net.Address.initIp4([4]u8{ 0, 0, 0, 0 }, 9002);

    var server: Server = undefined;
    try server.bind(allocator, &io_loop, addr, config);
    defer server.deinit();

    // Use certs from tls.zig project
    const dir = try std.fs.cwd().openDir("../tls.zig/example/cert", .{});
    // Load server certificate key pair
    var auth = try io.tls.config.CertKeyPair.load(allocator, dir, "localhost_ec/cert.pem", "localhost_ec/key.pem");
    defer auth.deinit(allocator);
    var wss_config = try io.ws.config.Server.fromUri("wss://localhost:9003");
    wss_config.tls = .{ .auth = &auth };
    const wss_addr = net.Address.initIp4([4]u8{ 127, 0, 0, 1 }, 9003);

    var wss_server: Server = undefined;
    try wss_server.bind(allocator, &io_loop, wss_addr, wss_config);
    defer wss_server.deinit();

    _ = try io_loop.run();
}

const ConnectionPool = io.ConnectionPool(Handler);
const TcpServer = io.tcp.Server(Server);

const Server = struct {
    const Self = @This();

    allocator: mem.Allocator,
    pool: ConnectionPool,
    tcp: TcpServer,
    config: io.ws.config.Server,

    fn bind(
        self: *Self,
        allocator: mem.Allocator,
        io_loop: *io.Loop,
        addr: net.Address,
        config: io.ws.config.Server,
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
        const handler = try self.pool.create();
        handler.* = .{
            .pool = &self.pool,
            .ws = undefined,
        };
        try handler.ws.init(self.allocator, io_loop, handler, self.config);
        handler.ws.accept(socket);
    }

    pub fn onError(_: *Self, err: anyerror) void {
        log.err("listener on error {}", .{err});
    }

    pub fn onClose(_: *Self) void {
        log.debug("listener closed ", .{});
    }
};

const Handler = struct {
    const Self = @This();

    pool: *ConnectionPool,
    ws: io.ws.Conn(Self, .server),

    pub fn deinit(self: *Self) void {
        self.ws.deinit();
    }

    pub fn onConnect(_: *Self) !void {
        // log.debug("{*} connected", .{self});
    }

    pub fn onRecv(self: *Self, msg: io.ws.Msg) !void {
        // log.debug("{*} onRecv {} bytes", .{ self, msg.data.len });
        try self.ws.send(msg);
    }

    pub fn onClose(self: *Self) void {
        // log.debug("{*} closed", .{self});
        self.deinit();
        self.pool.destroy(self);
    }

    pub fn onError(self: *Self, err: anyerror) void {
        log.err("{*} on error {}", .{ self, err });
    }
};
