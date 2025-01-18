const std = @import("std");
const io = @import("iox");
const mem = std.mem;
const net = std.net;
const posix = std.posix;
const assert = std.debug.assert;
const InstanceMap = @import("tcp_echo_server.zig").InstanceMap;

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

    // Use certs from tls.zig project
    const dir = try std.fs.cwd().openDir("../tls.zig/example/cert", .{});
    // Load server certificate key pair
    var auth = try io.tls.config.CertKeyPair.load(allocator, dir, "localhost_ec/cert.pem", "localhost_ec/key.pem");
    defer auth.deinit(allocator);
    const config: io.tls.config.Server = .{ .auth = &auth };

    var io_loop: io.Loop = undefined;
    try io_loop.init(allocator, .{});
    defer io_loop.deinit();

    var factory: Factory = .{
        .allocator = allocator,
        .io_loop = &io_loop,
        .config = config,
        .handlers = InstanceMap(Handler).init(allocator),
    };
    defer factory.deinit();

    var listener = Listener.init(&io_loop, &factory);
    const addr = net.Address.initIp4([4]u8{ 0, 0, 0, 0 }, 9443);
    try listener.bind(addr);

    _ = try io_loop.run();
}

const Listener = io.tcp.Listener(Factory);

const Factory = struct {
    const Self = @This();

    allocator: mem.Allocator,
    io_loop: *io.Loop,
    config: io.tls.config.Server,
    handlers: InstanceMap(Handler),

    fn deinit(self: *Self) void {
        self.handlers.deinit();
    }

    pub fn accept(self: *Self, socket: posix.socket_t, addr: net.Address) !void {
        const handler = try self.handlers.create();
        errdefer self.handlers.destroy(handler);

        handler.* = .{
            .parent = self,
            .tls = undefined,
        };
        try handler.tls.init(self.allocator, self.io_loop, handler, socket, self.config);
        log.debug("{*} connected socket: {} addr: {}", .{ handler, socket, addr });
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
    const Tcp = io.tls.Conn(Self);

    parent: *Factory,
    tls: Tcp,

    pub fn deinit(self: *Self) void {
        self.tls.deinit();
    }

    /// Called by tls connection when it successfully finishes handshake.
    pub fn onConnect(_: *Self) void {
        // tls handshake is done
    }

    pub fn onRecv(self: *Self, bytes: []const u8) usize {
        self.tls.send(bytes) catch |err| {
            log.err("{*} send {}", .{ self, err });
            self.tls.close();
        };
        return bytes.len;
    }

    /// Called by tls connection when it is closed.
    pub fn onClose(self: *Self) void {
        log.debug("{*} closed", .{self});
        self.deinit();
        self.parent.handlers.destroy(self);
    }

    pub fn onError(self: *Self, err: anyerror) void {
        log.err("{*} on error {}", .{ self, err });
    }
};
