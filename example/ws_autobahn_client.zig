const std = @import("std");
const io = @import("iox");
const assert = std.debug.assert;
const mem = std.mem;
const net = std.net;
const posix = std.posix;

const log = std.log.scoped(.main);

pub fn main() !void {
    assert(std.os.argv.len > 1);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const cases_count = try std.fmt.parseUnsigned(usize, args[1], 10);
    std.log.debug("number of test cases: {d}", .{cases_count});

    const hostname = "localhost";
    const port = 9001;
    const addr = net.Address.initIp4([4]u8{ 127, 0, 0, 1 }, port);

    var io_loop: io.Loop = undefined;
    try io_loop.init(allocator, .{});
    defer io_loop.deinit();

    var clients = try allocator.alloc(Client, cases_count);
    defer allocator.free(clients);

    var case_no: usize = 1;
    while (case_no <= cases_count) : (case_no += 1) {
        const uri = try std.fmt.allocPrint(allocator, "ws://{s}:{d}/runCase?case={d}&agent=iox_ws.zig", .{ hostname, port, case_no });
        std.debug.print("{s}\n", .{uri});

        var cli: *Client = &clients[case_no - 1];
        cli.connect(allocator, &io_loop, addr, uri);
    }

    // _ = try io_loop.run();
    try io_loop.drain();

    for (0..cases_count) |i| {
        var cli: *Client = &clients[i];
        allocator.free(cli.uri);
        cli.deinit();
    }
}

const Client = struct {
    const Self = @This();

    ws: io.ws.Client(*Self) = undefined,
    uri: []const u8 = &.{},

    fn connect(
        self: *Self,
        allocator: mem.Allocator,
        io_loop: *io.Loop,
        addr: net.Address,
        uri: []const u8,
    ) void {
        self.uri = uri;
        self.ws.connect(allocator, io_loop, self, addr, uri);
    }

    fn deinit(self: *Self) void {
        self.ws.deinit();
    }

    pub fn onConnect(self: *Self) void {
        log.debug("{*} connected", .{self});
    }

    pub fn onMessage(self: *Self, msg: io.ws.Message) void {
        log.debug("{*} message len: {}", .{ self, msg.payload.len });
        self.ws.send(msg.payload) catch |err| {
            log.err("send {}", .{err});
            self.ws.close();
        };
    }

    pub fn onError(self: *Self, err: anyerror) void {
        log.err("{*} {}", .{ self, err });
    }

    pub fn onClose(self: *Self) void {
        log.debug("{*} closed", .{self});
        // posix.raise(posix.SIG.USR1) catch {};
    }
};

fn getAddress(allocator: mem.Allocator, host: []const u8, port: u16) !net.Address {
    const list = try std.net.getAddressList(allocator, host, port);
    defer list.deinit();
    if (list.addrs.len == 0) return error.UnknownHostName;
    return list.addrs[0];
}
