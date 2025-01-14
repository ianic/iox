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

    const host = "ws.vi-server.org";
    const uri = "ws://ws.vi-server.org/mirror/";
    const port = 80;
    const addr = try getAddress(allocator, host, port);

    var conn: Conn = undefined;
    conn.init(allocator, &io_loop, addr, uri);
    defer conn.deinit();

    _ = try io_loop.run();
}

fn getAddress(allocator: mem.Allocator, host: []const u8, port: u16) !net.Address {
    const list = try std.net.getAddressList(allocator, host, port);
    defer list.deinit();
    if (list.addrs.len == 0) return error.UnknownHostName;
    return list.addrs[0];
}

const Conn = struct {
    const Self = @This();

    allocator: mem.Allocator,
    ws_cli: io.ws.Client(*Self),
    send_len: usize = 1,

    pub fn init(
        self: *Self,
        allocator: mem.Allocator,
        io_loop: *io.Loop,
        addr: net.Address,
        uri: []const u8,
    ) void {
        self.* = .{
            .allocator = allocator,
            .ws_cli = undefined,
        };
        self.ws_cli.init(allocator, io_loop, self, addr, uri);
    }

    pub fn deinit(self: *Self) void {
        self.ws_cli.deinit();
    }

    pub fn onConnect(self: *Self) !void {
        log.debug("{*} connected", .{self});
        try self.ws_cli.send("iso medo u ducan nije reko dobar dan");
    }

    pub fn onMessage(self: *Self, msg: io.ws.Message) !void {
        _ = self;
        log.debug("onMessage: {s}", .{msg.payload});
    }

    pub fn onClose(self: *Self) void {
        log.debug("{*} closed", .{self});
        posix.raise(posix.SIG.USR1) catch {};
    }
};
