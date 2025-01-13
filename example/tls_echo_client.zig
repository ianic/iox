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

    const dir = try std.fs.cwd().openDir("../tls.zig/example/cert", .{});
    var root_ca = try io.tls.config.CertBundle.fromFile(allocator, dir, "minica.pem");
    defer root_ca.deinit(allocator);

    const addr = net.Address.initIp4([4]u8{ 0, 0, 0, 0 }, 9443);

    var diagnostic: io.tls.config.Client.Diagnostic = .{};
    const opt: io.tls.config.Client = .{
        .host = "localhost",
        .root_ca = root_ca,
        .diagnostic = &diagnostic,
        // example of how to get handshake failure, use some really old cipher
        // .cipher_suites = &[_]io.tls.options.CipherSuite{.RSA_WITH_AES_128_CBC_SHA},
    };

    var conn: Conn = undefined;
    try conn.init(allocator, &io_loop, addr, opt);
    defer conn.deinit();

    _ = try io_loop.run();

    if (conn.tls_cli.getError()) |err| {
        log.err("tls {}", .{err});
        return;
    }
}

const Conn = struct {
    const Self = @This();

    allocator: mem.Allocator,
    tls_cli: io.tls.Client(*Self),
    send_len: usize = 1,

    pub fn init(
        self: *Self,
        allocator: mem.Allocator,
        io_loop: *io.Loop,
        addr: net.Address,
        opt: io.tls.config.Client,
    ) !void {
        self.* = .{
            .allocator = allocator,
            .tls_cli = undefined,
        };
        try self.tls_cli.init(allocator, io_loop, self, addr, opt);
    }

    pub fn deinit(self: *Self) void {
        self.tls_cli.deinit();
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
            self.tls_cli.close();
            return;
        }

        self.send_len *= 2;
        const buf = try self.allocator.alloc(u8, self.send_len);
        defer self.allocator.free(buf);
        for (0..buf.len) |i| buf[i] = @intCast(i % 256);

        log.debug("sending {} bytes", .{buf.len});
        try self.tls_cli.send(buf);
    }

    pub fn onClose(self: *Self) void {
        log.debug("{*} closed", .{self});
        posix.raise(posix.SIG.USR1) catch {};
    }
};
