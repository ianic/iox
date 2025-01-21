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

    var clients = try allocator.alloc(Client, cases_count);
    defer allocator.free(clients);

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
        log.debug("connecting to {s}", .{config.uri});

        var client = &clients[idx];
        client.init(allocator, &io_loop, config);
    }

    try io_loop.drain();

    for (0..cases_count) |i| {
        clients[i].deinit();
    }
}

const Client = struct {
    const Self = @This();

    allocator: mem.Allocator,
    config: io.ws.Config,
    handler: ?*Handler = null,
    connector: io.ws.Connector(Self),

    fn init(
        self: *Self,
        allocator: mem.Allocator,
        io_loop: *io.Loop,
        config: io.ws.Config,
    ) void {
        self.* = .{
            .allocator = allocator,
            .config = config,
            .connector = io.ws.Connector(Self).init(allocator, io_loop, self, config.addr),
        };
        self.connector.connect();
    }

    fn deinit(self: *Self) void {
        if (self.handler) |handler| {
            handler.deinit();
            self.allocator.destroy(handler);
        }
        self.config.deinit(self.allocator);
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
    }
};

const Handler = struct {
    const Self = @This();
    const Ws = io.ws.Conn(Self, .client);

    ws: Ws,

    fn deinit(self: *Self) void {
        self.ws.deinit();
    }

    pub fn onConnect(_: *Self) void {
        // log.debug("{*} connected", .{self});
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

    pub fn onClose(_: *Self) void {
        //log.debug("{*} closed", .{self});
    }
};
