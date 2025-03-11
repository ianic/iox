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

    // ws config
    var config = try io.ws.config.Client.fromUri(allocator, uri);
    defer config.deinit(allocator);

    // tls config
    var root_ca = try io.tls.config.CertBundle.fromSystem(allocator);
    defer root_ca.deinit(allocator);
    config.tls = .{ .host = config.host, .root_ca = root_ca };

    var io_loop: io.Loop = undefined;
    try io_loop.init(allocator, .{});
    defer io_loop.deinit();

    var handler: Handler = undefined;
    try handler.ws.init(allocator, &io_loop, &handler, config);
    defer handler.deinit();
    handler.ws.connect(config.addr);

    _ = try io_loop.run();
}

const Handler = struct {
    const Self = @This();

    ws: io.ws.Conn(Self, .client),

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
