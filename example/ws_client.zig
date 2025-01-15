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

    var cli: Client = .{};
    cli.connect(allocator, &io_loop, addr, uri);
    defer cli.deinit();

    _ = try io_loop.run();
}

fn getAddress(allocator: mem.Allocator, host: []const u8, port: u16) !net.Address {
    const list = try std.net.getAddressList(allocator, host, port);
    defer list.deinit();
    if (list.addrs.len == 0) return error.UnknownHostName;
    return list.addrs[0];
}

const Client = struct {
    const Self = @This();

    ws: io.ws.Client(*Self) = undefined,

    fn connect(
        self: *Self,
        allocator: mem.Allocator,
        io_loop: *io.Loop,
        addr: net.Address,
        uri: []const u8,
    ) void {
        self.ws.connect(allocator, io_loop, self, addr, uri);
    }

    fn deinit(self: *Self) void {
        self.ws.deinit();
    }

    pub fn onConnect(self: *Self) void {
        log.debug("{*} connected", .{self});
        self.ws.send("iso medo u ducan nije reko dobar dan") catch |err| {
            log.err("send {}", .{err});
            self.ws.close();
        };
    }

    pub fn onMessage(self: *Self, msg: io.ws.Message) void {
        log.debug("{*} message: {s}", .{ self, msg.payload });
        self.ws.close();
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
