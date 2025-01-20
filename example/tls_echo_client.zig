const std = @import("std");
const io = @import("iox");
const mem = std.mem;
const net = std.net;
const posix = std.posix;
const assert = std.debug.assert;

const log = std.log.scoped(.client);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // tls config
    const dir = try std.fs.cwd().openDir("../tls.zig/example/cert", .{});
    var root_ca = try io.tls.config.CertBundle.fromFile(allocator, dir, "minica.pem");
    defer root_ca.deinit(allocator);
    var diagnostic: io.tls.config.Client.Diagnostic = .{};
    const config: io.tls.config.Client = .{
        .host = "localhost",
        .root_ca = root_ca,
        .diagnostic = &diagnostic,
        // example of how to get handshake failure, use some really old cipher
        // .cipher_suites = &[_]io.tls.options.CipherSuite{.RSA_WITH_AES_128_CBC_SHA},
    };

    var io_loop: io.Loop = undefined;
    try io_loop.init(allocator, .{});
    defer io_loop.deinit();

    var factory = Factory.init(allocator, config);
    defer factory.deinit();

    const addr = net.Address.initIp4([4]u8{ 0, 0, 0, 0 }, 9443);
    var connector = io.tls.Connector(Factory).init(allocator, &io_loop, &factory, addr);
    connector.connect();

    _ = try io_loop.run();
}

const Factory = struct {
    const Self = @This();

    allocator: mem.Allocator,
    config: io.tls.config.Client,
    handler: ?*Handler = null,

    fn init(
        allocator: mem.Allocator,
        config: io.tls.config.Client,
    ) Self {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    fn deinit(self: *Self) void {
        if (self.handler) |handler| {
            handler.deinit();
            self.allocator.destroy(handler);
        }
    }

    pub fn create(self: *Self) !struct { *Handler, *Handler.Tls } {
        const handler = try self.allocator.create(Handler);
        errdefer self.allocator.destroy(handler);
        handler.* = .{
            .allocator = self.allocator,
            .tls = undefined,
        };
        self.handler = handler;
        return .{ handler, &handler.tls };
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
    const Tls = io.tls.Conn(Self, .client);

    allocator: mem.Allocator,
    tls: Tls,
    send_len: usize = 1,

    pub fn deinit(self: *Self) void {
        self.tls.deinit();
    }

    pub fn onConnect(self: *Self) void {
        self.send() catch |err| {
            self.onError(err);
            self.tls.close();
        };
    }

    pub fn onRecv(self: *Self, bytes: []const u8) usize {
        if (bytes.len == self.send_len) {
            for (0..bytes.len) |i| assert(bytes[i] == @as(u8, @intCast(i % 256)));
            self.send() catch |err| {
                self.onError(err);
                self.tls.close();
            };
            log.debug("recv {} bytes", .{bytes.len});
            return bytes.len;
        }
        // log.debug("recv {} bytes waiting for more", .{bytes.len});
        return 0;
    }

    fn send(self: *Self) !void {
        if (self.send_len > 1024 * 1024 * 2) {
            self.tls.close();
            return;
        }

        self.send_len *= 2;
        const buf = try self.allocator.alloc(u8, self.send_len);
        defer self.allocator.free(buf);
        for (0..buf.len) |i| buf[i] = @intCast(i % 256);

        // log.debug("sending {} bytes", .{buf.len});
        try self.tls.send(buf);
    }

    pub fn onClose(self: *Self) void {
        log.debug("{*} closed", .{self});
        posix.raise(posix.SIG.USR1) catch {};
    }

    pub fn onError(self: *Self, err: anyerror) void {
        log.err("{*} {}", .{ self, err });
    }
};
