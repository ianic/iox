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

    //const uri = "wss://ws.vi-server.org/mirror/";
    const uri = "wss://www.supersport.hr/api/sbk?preSub=dl_hr";

    // var args_iter = try std.process.argsWithAllocator(allocator);
    // defer args_iter.deinit();
    // _ = args_iter.next();
    // const uri = args_iter.next() orelse unreachable;

    var io_loop: io.Loop = undefined;
    try io_loop.init(allocator, .{});
    defer io_loop.deinit();

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
        log.debug("connected to: {s}", .{self.config.uri});
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
    const Ws = io.ws.Conn(Self, .client);

    ws: Ws,

    fn deinit(self: *Self) void {
        self.ws.deinit();
    }

    pub fn onConnect(self: *Self) void {
        log.debug("{*} connected", .{self});
        // self.ws.send(.{ .data = "iso medo u ducan nije reko dobar dan" }) catch |err| {
        //     log.err("send {}", .{err});
        //     self.ws.close();
        // };
    }

    pub fn onRecv(_: *Self, msg: io.ws.Msg) void {
        log.debug("received: {s}", .{msg.data});
        // self.ws.close();
    }

    pub fn onError(_: *Self, err: anyerror) void {
        log.err("{}", .{err});
    }

    pub fn onClose(_: *Self) void {
        // log.debug("{*} closed", .{self});
        posix.raise(posix.SIG.USR1) catch {};
    }
};
