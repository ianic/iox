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
            // .ReleaseSafe => .{ debug_allocator.allocator(), true },
            // .ReleaseSmall => .{ std.heap.smp_allocator, false },
            // .ReleaseFast => .{ std.heap.c_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    var io_loop: io.Loop = undefined;
    try io_loop.init(allocator, .{
        .recv_buffers = 1024,
        .recv_buffer_len = 64 * 1024,
    });
    defer io_loop.deinit();

    const addr = net.Address.initIp4([4]u8{ 127, 0, 0, 1 }, 9000);
    var server: Server = undefined;
    try server.bind(allocator, &io_loop, addr);
    defer server.deinit();

    var ts = io_loop.now();
    while (true) {
        try io_loop.tick();
        const elapsed = io_loop.now() - ts;

        if (elapsed > 10 * std.time.ns_per_s) {
            const sec = @as(f64, @floatFromInt(elapsed)) / std.time.ns_per_s;
            std.debug.print("{} operations {} bytes {d:9.1} MB/s {d:9.3} GB/s \n", .{
                stat.msgs,
                stat.bytes,
                @as(f64, @floatFromInt(stat.bytes)) / 1024 / 1024 / sec,
                @as(f64, @floatFromInt(stat.bytes)) / 1024 / 1024 / 1024 / sec,
            });
            ts = io_loop.now();
            stat = .{};
        }
    }
}

var stat = struct {
    msgs: usize = 0,
    bytes: usize = 0,
}{};

const Server = struct {
    const Self = @This();

    allocator: mem.Allocator,
    pool: ConnectionPool,
    tcp: io.tcp.Server(Self),

    fn bind(self: *Self, allocator: mem.Allocator, io_loop: *io.Loop, addr: net.Address) !void {
        self.* = .{
            .allocator = allocator,
            .pool = ConnectionPool.init(allocator),
            .tcp = undefined,
        };
        self.tcp = .init(io_loop, self);
        try self.tcp.bind(addr);
    }

    fn deinit(self: *Self) void {
        self.pool.deinit();
    }

    pub fn onAccept(self: *Self, io_loop: *io.Loop, socket: posix.socket_t, _: net.Address) io.Error!void {
        const conn = try self.pool.create();
        conn.* = .{
            .allocator = self.allocator,
            .pool = &self.pool,
            .tcp = undefined,
        };
        conn.tcp.init(self.allocator, io_loop, conn, .{});
        conn.tcp.accept(socket);
    }

    pub fn onError(_: *Self, err: anyerror) void {
        log.err("listener on error {}", .{err});
    }

    pub fn onClose(_: *Self) void {
        log.err("listener closed ", .{});
    }
};

const Conn = struct {
    const Self = @This();

    allocator: mem.Allocator,
    pool: *ConnectionPool,
    tcp: io.tcp.BufferedConn(Self),

    pub fn deinit(self: *Self) void {
        self.tcp.deinit();
    }

    pub fn onConnect(self: *Self) !void {
        log.debug("{*} connected socket: {} ", .{ self, self.tcp.conn.socket });
    }

    pub fn onRecv(self: *Self, bytes: []const u8) !usize {
        stat.bytes += bytes.len;
        stat.msgs += 1;
        // log.debug("{*} recv {} bytes", .{ self, bytes.len });
        try self.send(bytes);
        return bytes.len;
    }

    fn send(self: *Self, bytes: []const u8) !void {
        const buf = try self.allocator.dupe(u8, bytes);
        try self.tcp.send(buf);
    }

    pub fn onSend(self: *Self, buf: []const u8) void {
        self.allocator.free(buf);
    }

    pub fn onClose(self: *Self) void {
        log.debug("{*} closed", .{self});
        self.deinit();
        self.pool.destroy(self);
    }

    pub fn onError(self: *Self, err: anyerror) void {
        if (err != error.ShortSend)
            log.err("{*} on error {}", .{ self, err });
    }
};
