const std = @import("std");
const io = @import("iox");
const mem = std.mem;
const net = std.net;
const posix = std.posix;
const assert = std.debug.assert;
const builtin = @import("builtin");
const log = std.log.scoped(.client);

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

pub fn main() !void {
    // allocator
    const allocator, const is_debug = gpa: {
        break :gpa switch (builtin.mode) {
            .Debug => .{ debug_allocator.allocator(), true },
            else => .{ std.heap.c_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    // tls config
    var root_ca = try io.tls.config.cert.fromFilePath(
        allocator,
        try std.fs.cwd().openDir("../tls.zig/example/cert", .{}),
        "minica.pem",
    );
    defer root_ca.deinit(allocator);
    const config: io.tls.config.Client = .{
        .host = "localhost",
        .root_ca = root_ca,
    };
    const addr = net.Address.initIp4([4]u8{ 0, 0, 0, 0 }, 9443);

    var io_loop: io.Loop = undefined;
    try io_loop.init(allocator, .{});
    defer io_loop.deinit();

    // Start handlers
    var handlers: [1024]Handler = undefined;
    for (&handlers) |*handler| {
        handler.* = .{ .addr = addr };
        try handler.tls.init(allocator, &io_loop, handler, .{
            .onConnect = Handler.onConnect,
            .onRecv = Handler.onRecv,
            .onError = Handler.onError,
            .onClose = Handler.onClose,
        }, config);
        handler.tls.connect(addr);
    }

    _ = try io_loop.run();

    for (&handlers) |*handler| {
        handler.deinit();
    }
}

// Runs tls connect in the loop
const Handler = struct {
    const Self = @This();

    addr: net.Address,

    tls: io.tls.Client() = undefined,

    pub fn deinit(self: *Self) void {
        self.tls.deinit();
    }

    pub fn onConnect(ptr: *anyopaque) !void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.tls.close();
    }

    pub fn onRecv(_: *anyopaque, _: []const u8) !usize {
        unreachable;
    }

    pub fn onSend(_: *anyopaque, _: []const u8) void {
        unreachable;
    }

    pub fn onClose(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.tls.connect(self.addr);
    }

    pub fn onError(ptr: *anyopaque, err: anyerror) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        log.err("{*} {}", .{ self, err });
        unreachable;
    }
};
