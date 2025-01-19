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

    //const uri = "wss://ws.vi-server.org/mirror/";
    const uri = "wss://www.supersport.hr/api/sbk?preSub=dl_hr";
    var config = try io.ws.Config.fromUri(allocator, uri);
    defer config.deinit(allocator);

    var factory = Factory.init(allocator, config);
    defer factory.deinit();

    var connector = io.ws.Connector(Factory).init(allocator, &io_loop, &factory, config.addr);
    connector.connect();

    _ = try io_loop.run();
}

const Factory = struct {
    const Self = @This();

    allocator: mem.Allocator,
    config: io.ws.Config,
    handler: ?*Handler = null,

    fn init(
        allocator: mem.Allocator,
        config: io.ws.Config,
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

    pub fn create(self: *Self) !struct { *Handler, *Handler.Ws } {
        const handler = try self.allocator.create(Handler);
        errdefer self.allocator.destroy(handler);
        handler.* = .{ .ws = undefined };
        self.handler = handler;
        return .{ handler, &handler.ws };
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
    const Ws = io.ws.Conn(Self);

    ws: Ws,

    fn deinit(self: *Self) void {
        self.ws.deinit();
    }

    pub fn onConnect(self: *Self) void {
        log.debug("{*} connected", .{self});
        self.ws.send(.{ .data = "iso medo u ducan nije reko dobar dan" }) catch |err| {
            log.err("send {}", .{err});
            self.ws.close();
        };
    }

    pub fn onRecv(self: *Self, msg: io.ws.Msg) void {
        log.debug("{*} message: {s}", .{ self, msg.data });
        // self.ws.close();
    }

    pub fn onError(self: *Self, err: anyerror) void {
        log.err("{*} {}", .{ self, err });
    }

    pub fn onClose(self: *Self) void {
        log.debug("{*} closed", .{self});
        posix.raise(posix.SIG.USR1) catch {};
    }
};

fn dhumpStackTrace() void {
    var address_buffer: [32]usize = undefined;
    var stack_trace: std.builtin.StackTrace = .{
        .instruction_addresses = &address_buffer,
        .index = 0,
    };
    std.debug.captureStackTrace(null, &stack_trace);
    std.debug.dumpStackTrace(stack_trace);
}
