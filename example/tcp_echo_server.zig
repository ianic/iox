const std = @import("std");
const builtin = @import("builtin");
const io = @import("iox");
const assert = std.debug.assert;
const mem = std.mem;
const net = std.net;
const posix = std.posix;
const ConnectionPool = io.ConnectionPool(Conn);

const log = std.log.scoped(.server);
var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

// Start server:
//   $ zig build && zig-out/bin/tcp_echo_server
// Send file and receive echo output:
//   $ nc -w 1 localhost 9000 < some-file-name
// Send some text:
//   $ echo '1\n2\n3' | nc -w 1 localhost 9000
//
pub fn main() !void {
    const allocator, const is_debug = gpa: {
        break :gpa switch (builtin.mode) {
            .Debug => .{ debug_allocator.allocator(), true },
            else => .{ std.heap.c_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    var io_loop: io.Loop = undefined;
    try io_loop.init(allocator, .{
        .recv_buffers = 64,
    });
    defer io_loop.deinit();

    const addr = net.Address.initIp4([4]u8{ 127, 0, 0, 1 }, 9000);
    var server: Server = undefined;
    try server.bind(allocator, &io_loop, addr);
    defer server.deinit();

    std.debug.print("  msgs/s    cqe/s   loop/s ->GB/s <-GB/s no-buf\n", .{});
    var ts = io_loop.now();
    while (true) {
        try io_loop.tick();
        const elapsed = io_loop.now() - ts;

        if (elapsed > 10 * std.time.ns_per_s) {
            const sec = @as(f64, @floatFromInt(elapsed)) / std.time.ns_per_s;
            std.debug.print("{d:8.1} {d:8.1} {d:8.1}  {d:5.3}  {d:5.3} {d:5.3}% {}/{} \n", .{
                pers(stat.msgs, sec),
                pers(io_loop.metric.cqes.diff(), sec),
                pers(io_loop.metric.loops.diff(), sec),

                //gbs(stat.bytes, sec),

                gbs(io_loop.metric.send_bytes.diff(), sec),
                gbs(io_loop.metric.recv_bytes.diff(), sec),

                io_loop.metric.recv_buf_grp.noBufsPercent(),
                io_loop.metric.recv_buf_grp.no_bufs.diff(),
                io_loop.metric.recv_buf_grp.success.diff(),
            });
            ts = io_loop.now();
            stat = .{};
        }
    }
}

pub fn pers(count: usize, sec: f64) f64 {
    return @as(f64, @floatFromInt(count)) / sec;
}
pub fn mbs(bytes: usize, sec: f64) f64 {
    return @as(f64, @floatFromInt(bytes)) / 1024 / 1024 / sec;
}
pub fn gbs(bytes: usize, sec: f64) f64 {
    return @as(f64, @floatFromInt(bytes)) / 1024 / 1024 / 1024 / sec;
}

var stat = struct {
    msgs: usize = 0,
    bytes: usize = 0,
}{};

const Server = struct {
    const Self = @This();

    allocator: mem.Allocator,
    pool: ConnectionPool,
    tcp: io.tcp.Server,

    fn bind(self: *Self, allocator: mem.Allocator, io_loop: *io.Loop, addr: net.Address) !void {
        self.* = .{
            .allocator = allocator,
            .pool = ConnectionPool.init(allocator),
            .tcp = undefined,
        };
        self.tcp = .init(io_loop, self, .{
            .onAccept = Server.onAccept,
            .onError = Server.onError,
            .onClose = Server.onClose,
        });
        try self.tcp.bind(addr);
    }

    fn deinit(self: *Self) void {
        self.pool.deinit();
    }

    fn onAccept(context: *anyopaque, io_loop: *io.Loop, socket: posix.socket_t, _: net.Address) io.Error!void {
        const self: *Self = @ptrCast(@alignCast(context));
        const conn = try self.pool.create();
        conn.* = .{
            .allocator = self.allocator,
            .pool = &self.pool,
            .tcp = undefined,
        };
        conn.tcp.init(
            self.allocator,
            io_loop,
            conn,
            .{
                .onRecv = Conn.onRecv,
                .onSend = Conn.onSend,
                .onClose = Conn.onClose,
                .onConnect = Conn.onConnect,
                .onError = Conn.onError,
            },
            .{},
        );
        conn.tcp.accept(socket);
    }

    fn onError(_: *anyopaque, err: anyerror) void {
        log.err("listener on error {}", .{err});
    }

    fn onClose(_: *anyopaque) void {
        log.err("listener closed ", .{});
    }
};

const Conn = struct {
    const Self = @This();

    allocator: mem.Allocator,
    pool: *ConnectionPool,
    tcp: io.tcp.BufferedConn,

    pub fn deinit(self: *Self) void {
        self.tcp.deinit();
    }

    pub fn onConnect(context: *anyopaque) !void {
        const self: *Self = @ptrCast(@alignCast(context));
        log.debug("{*} connected socket: {} ", .{ self, self.tcp.conn.socket });
    }

    pub fn onRecv(context: *anyopaque, bytes: []const u8) !usize {
        const self: *Self = @ptrCast(@alignCast(context));
        stat.bytes += bytes.len;
        stat.msgs += 1;
        // log.debug("{*} recv {} bytes", .{ self, bytes.len });
        try self.send(bytes);
        return bytes.len;
    }

    fn send(self: *Self, bytes: []const u8) !void {
        try self.tcp.send(try self.allocator.dupe(u8, bytes));
    }

    pub fn onSend(context: *anyopaque, buf: []const u8) void {
        const self: *Self = @ptrCast(@alignCast(context));
        self.allocator.free(buf);
    }

    pub fn onClose(context: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(context));
        log.debug("{*} closed", .{self});
        self.deinit();
        self.pool.destroy(self);
    }

    pub fn onError(context: *anyopaque, err: anyerror) void {
        const self: *Self = @ptrCast(@alignCast(context));
        if (err != error.ShortSend)
            log.err("{*} on error {}", .{ self, err });
    }
};
