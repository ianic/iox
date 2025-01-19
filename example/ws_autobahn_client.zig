const std = @import("std");
const io = @import("iox");
const assert = std.debug.assert;
const mem = std.mem;
const net = std.net;
const posix = std.posix;

const log = std.log.scoped(.main);
pub const std_options = std.Options{ .log_level = .debug };

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    assert(std.os.argv.len > 1);
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const cases_count = try std.fmt.parseUnsigned(usize, args[1], 10);
    std.log.debug("number of test cases: {d}", .{cases_count});

    const port = 9001;
    const hostname = "localhost";

    var io_loop: io.Loop = undefined;
    try io_loop.init(allocator, .{});
    defer io_loop.deinit();

    var handlers = try allocator.alloc(Handler, cases_count);
    defer allocator.free(handlers);
    var configs = try allocator.alloc(io.ws.Config, cases_count);
    defer allocator.free(configs);

    var case_no: usize = 1;
    while (case_no <= cases_count) : (case_no += 1) {
        const idx = case_no - 1;

        const config = io.ws.Config{
            .scheme = .ws,
            .host = try allocator.dupe(u8, hostname),
            .port = port,
            .addr = net.Address.initIp4([4]u8{ 127, 0, 0, 1 }, port),
            .uri = try std.fmt.allocPrint(
                allocator,
                "ws://{s}:{d}/runCase?case={d}&agent=iox_ws.zig",
                .{ hostname, port, case_no },
            ),
        };
        configs[idx] = config;
        log.debug("connecting to {s}", .{config.uri});

        var handler = &handlers[idx];
        try handler.ws.connect(allocator, &io_loop, handler, config);
    }

    try io_loop.drain();

    for (0..cases_count) |i| {
        configs[i].deinit(allocator);
        handlers[i].deinit();
    }
}

const Handler = struct {
    const Self = @This();

    ws: io.ws.Client(Self),

    fn deinit(self: *Self) void {
        self.ws.deinit();
    }

    pub fn onConnect(self: *Self) void {
        log.debug("{*} connected", .{self});
    }

    pub fn onRecv(self: *Self, msg: io.ws.Msg) void {
        log.debug("{*} message len: {}", .{ self, msg.data.len });
        self.ws.send(msg) catch |err| {
            log.err("send {}", .{err});
            self.ws.close();
        };
    }

    pub fn onError(self: *Self, err: anyerror) void {
        log.err("{*} {}", .{ self, err });
    }

    pub fn onClose(self: *Self) void {
        log.debug("{*} closed", .{self});
    }
};
