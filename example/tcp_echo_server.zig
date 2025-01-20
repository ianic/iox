const std = @import("std");
const io = @import("iox");
const assert = std.debug.assert;
const mem = std.mem;
const net = std.net;
const posix = std.posix;

const log = std.log.scoped(.server);

// Start server:
//   $ zig build && zig-out/bin/tcp_echo
// Send file and receive echo output:
//   $ nc -w 1 localhost 9000 < some-file-name
// Send some text:
//   $ echo '1\n2\n3' | nc -w 1 localhost 9000
//
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var io_loop: io.Loop = undefined;
    try io_loop.init(allocator, .{});
    defer io_loop.deinit();

    var factory = Factory.init(allocator);
    defer factory.deinit();

    var listener = Listener.init(allocator, &io_loop, &factory);
    const addr = net.Address.initIp4([4]u8{ 0, 0, 0, 0 }, 9000);
    try listener.bind(addr);

    _ = try io_loop.run();
}

const Listener = io.tcp.Listener(Factory);

const Factory = struct {
    const Self = @This();

    allocator: mem.Allocator,
    handlers: InstanceMap(Handler),

    fn init(allocator: mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .handlers = InstanceMap(Handler).init(allocator),
        };
    }

    fn deinit(self: *Self) void {
        self.handlers.deinit();
    }

    pub fn create(self: *Self) !struct { *Handler, *io.tcp.Conn(Handler) } {
        const handler = try self.handlers.create();
        handler.* = .{
            .allocator = self.allocator,
            .parent = self,
            .tcp = undefined,
        };
        return .{ handler, &handler.tcp };
    }

    pub fn onError(_: *Self, err: anyerror) void {
        log.err("listener on error {}", .{err});
    }

    pub fn onClose(_: *Self) void {
        log.debug("listener closed ", .{});
    }
};

const Handler = struct {
    const Self = @This();
    const Tcp = io.tcp.Conn(Self);

    allocator: mem.Allocator,
    parent: *Factory,
    tcp: Tcp,

    pub fn deinit(self: *Self) void {
        self.tcp.deinit();
    }

    pub fn onConnect(self: *Self) void {
        log.debug("{*} connected socket: {} ", .{ self, self.tcp.socket });
    }

    pub fn onRecv(self: *Self, bytes: []const u8) usize {
        // log.debug("{*} recv {} bytes", .{ self, bytes.len });
        self.send(bytes) catch |err| {
            log.err("send {}", .{err});
            self.tcp.close();
        };
        return bytes.len;
    }

    fn send(self: *Self, bytes: []const u8) !void {
        const buf = try self.allocator.dupe(u8, bytes);
        try self.tcp.sendZc(buf);
    }

    pub fn onSend(self: *Self, buf: []const u8) void {
        self.allocator.free(buf);
    }

    pub fn onClose(self: *Self) void {
        log.debug("{*} closed", .{self});
        self.deinit();
        self.parent.handlers.destroy(self);
    }

    pub fn onError(self: *Self, err: anyerror) void {
        log.err("{*} on error {}", .{ self, err });
    }
};

pub fn InstanceMap(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: mem.Allocator,
        instances: std.AutoHashMap(*T, void),

        pub fn init(allocator: mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .instances = std.AutoHashMap(*T, void).init(allocator),
            };
        }

        pub fn create(self: *Self) !*T {
            try self.instances.ensureUnusedCapacity(1);
            const instance = try self.allocator.create(T);
            errdefer self.allocator.destroy(instance);
            self.instances.putAssumeCapacityNoClobber(instance, {});
            return instance;
        }

        pub fn destroy(self: *Self, instance: *T) void {
            assert(self.instances.remove(instance));
            self.allocator.destroy(instance);
        }

        pub fn deinit(self: *Self) void {
            var iter = self.instances.keyIterator();
            while (iter.next()) |k| {
                const instance = k.*;
                instance.deinit();
                self.allocator.destroy(instance);
            }
            self.instances.deinit();
        }
    };
}
