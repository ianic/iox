const std = @import("std");
const io = @import("iox");
const mem = std.mem;
const net = std.net;
const posix = std.posix;
const assert = std.debug.assert;
const InstanceMap = @import("tcp_echo_server.zig").InstanceMap;

const log = std.log.scoped(.server);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var io_loop: io.Loop = undefined;
    try io_loop.init(allocator, .{});
    defer io_loop.deinit();

    var config = try io.ws.Config.fromUri(allocator, "ws://localhost:9002");
    defer config.deinit(allocator);
    var factory = Factory.init(allocator, config);
    defer factory.deinit();

    var listener = io.ws.Listener(Factory).init(allocator, &io_loop, &factory);
    const addr = net.Address.initIp4([4]u8{ 0, 0, 0, 0 }, 9002);
    try listener.bind(addr);

    _ = try io_loop.run();
}

const Factory = struct {
    const Self = @This();

    allocator: mem.Allocator,
    config: io.ws.Config,
    handlers: InstanceMap(Handler),

    fn init(allocator: mem.Allocator, config: io.ws.Config) Self {
        return .{
            .allocator = allocator,
            .config = config,
            .handlers = InstanceMap(Handler).init(allocator),
        };
    }

    fn deinit(self: *Self) void {
        self.handlers.deinit();
    }

    pub fn create(self: *Self) !struct { *Handler, *Handler.Ws } {
        const handler = try self.handlers.create();
        errdefer self.handlers.destroy(handler);
        handler.* = .{
            .parent = self,
            .ws = undefined,
        };
        return .{ handler, &handler.ws };
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
    const Ws = io.ws.Conn(Self, .server);

    parent: *Factory,
    ws: Ws,

    pub fn deinit(self: *Self) void {
        self.ws.deinit();
    }

    pub fn onConnect(self: *Self) void {
        log.debug("{*} connected", .{self});
    }

    pub fn onRecv(self: *Self, msg: io.ws.Msg) void {
        log.debug("{*} onRecv {} bytes", .{ self, msg.data.len });
        self.ws.send(msg) catch |err| {
            log.err("{*} send {}", .{ self, err });
            self.ws.close();
        };
    }

    pub fn onClose(self: *Self) void {
        log.debug("{*} closed", .{self});
        self.deinit();
        self.parent.handlers.destroy(self);
    }

    pub fn onError(self: *Self, err: anyerror) void {
        log.err("{*} on error {}", .{ self, err });
    }
};
