const std = @import("std");
const io = @import("iox");
const mem = std.mem;
const net = std.net;
const posix = std.posix;
const assert = std.debug.assert;

const log = std.log.scoped(.ws_client);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args_iter = try std.process.argsWithAllocator(allocator);
    defer args_iter.deinit();
    _ = args_iter.next();
    const uri = args_iter.next() orelse unreachable;

    var io_loop: io.Loop = undefined;
    try io_loop.init(allocator, .{});
    defer io_loop.deinit();

    // ws config
    var config = try io.ws.config.Client.fromUri(allocator, uri);
    defer config.deinit(allocator);
    // tls config
    var root_ca = try io.tls.config.CertBundle.fromSystem(allocator);
    const dir = try std.fs.cwd().openDir("../tls.zig/example/cert", .{});
    try root_ca.bundle.addCertsFromFilePath(allocator, dir, "minica.pem");
    defer root_ca.deinit(allocator);
    config.tls = .{ .host = config.host, .root_ca = root_ca };

    var handler: Handler = .{ .allocator = allocator, .ws = undefined };
    try handler.ws.init(allocator, &io_loop, &handler, config);
    defer handler.deinit();
    handler.ws.connect(config.addr);

    _ = try io_loop.run();
}

const Handler = struct {
    const Self = @This();

    allocator: mem.Allocator,
    ws: io.ws.Conn(Self, .client),
    send_len: usize = 1,

    fn deinit(self: *Self) void {
        self.ws.deinit();
    }

    pub fn onConnect(self: *Self) void {
        // log.debug("{*} onConnect", .{self});
        self.send();
    }

    pub fn onRecv(self: *Self, msg: io.ws.Msg) void {
        assert(msg.data.len == self.send_len);
        for (0..msg.data.len) |i| assert(msg.data[i] == @as(u8, @intCast(i % 256)));
        log.debug("recv {} bytes", .{msg.data.len});

        self.send();
    }

    fn send(self: *Self) void {
        self.send_() catch |err| {
            log.err("send failed {}", .{err});
            self.ws.close();
        };
    }

    fn send_(self: *Self) !void {
        if (self.send_len >= 1024)
            return self.ws.close();

        self.send_len *= 2;
        const buf = try self.allocator.alloc(u8, self.send_len);
        defer self.allocator.free(buf);
        for (0..buf.len) |i| buf[i] = @intCast(i % 256);
        try self.ws.send(.{ .data = buf, .encoding = .binary });
    }

    pub fn onError(_: *Self, err: anyerror) void {
        log.err("{}", .{err});
    }

    pub fn onClose(_: *Self) void {
        // log.debug("{*} closed", .{self});
        posix.raise(posix.SIG.USR1) catch {};
    }
};
