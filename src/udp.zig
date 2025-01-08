const std = @import("std");
const net = std.net;
const mem = std.mem;
const assert = std.debug.assert;
const posix = std.posix;
const io = @import("io.zig");

const log = std.log.scoped(.io_tcp);

pub fn Sender(comptime ClientType: type) type {
    return struct {
        const Self = @This();

        allocator: mem.Allocator,
        io_loop: *io.Loop,
        client: ClientType,
        address: std.net.Address = undefined,
        socket: posix.socket_t = 0,
        state: State = .closed,
        max_packet_size: u16 = 508,

        connect_op: io.Op = .{},
        close_op: io.Op = .{},
        send_op: io.Op = .{},
        send_list: std.ArrayList([]const u8), // pending send buffers
        send_buf: []const u8 = &.{}, // current send buffer
        send_offset: usize = 0, // bytes already sent from send_buf

        const State = enum {
            closed,
            connecting,
            connected,
            closing,
        };

        pub fn init(allocator: mem.Allocator, io_loop: *io.Loop, client: ClientType, address: net.Address) Self {
            return .{
                .allocator = allocator,
                .io_loop = io_loop,
                .client = client,
                .address = address,
                .send_list = std.ArrayList([]const u8).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.send_list.deinit();
        }

        /// Start connect operation. `onConnect` callback will be fired when
        /// finished.
        fn connect(self: *Self) void {
            assert(self.state == .closed);
            assert(!self.connect_op.active() and !self.send_op.active() and !self.close_op.active());
            assert(self.socket == 0);

            self.connect_op = io.Op.connect(
                .{
                    .socket_type = posix.SOCK.DGRAM | posix.SOCK.CLOEXEC,
                    .addr = &self.address,
                },
                self,
                onConnect,
                onConnectFail,
            );
            self.io_loop.submit(&self.connect_op);
            self.state = .connecting;
        }

        fn onConnect(self: *Self, socket: posix.socket_t) io.Error!void {
            log.debug("{} connected socket {}", .{ self.address, socket });
            self.socket = socket;
            self.state = .connected;
            self.sendPending();
        }

        fn onConnectFail(self: *Self, err: ?anyerror) void {
            if (err) |e| {
                log.info("{} connect failed {}", .{ self.address, e });
                self.freeSendList(e);
                self.close();
            }
        }

        pub fn send(self: *Self, buf: []const u8) io.Error!void {
            try self.send_list.append(buf);

            switch (self.state) {
                .closed => self.connect(),
                .connecting, .closing => {},
                .connected => self.sendPending(),
            }
        }

        /// Start send operation for buffers accumulated in send_list.
        fn sendPending(self: *Self) void {
            if (self.send_op.active() or
                (self.send_list.items.len == 0 and self.send_buf.len == 0)) return;

            if (self.send_buf.len == 0) {
                // get next buffer from send_list
                self.send_offset = 0;
                self.send_buf = self.send_list.items[0];
                _ = self.send_list.orderedRemove(0);
            }

            // send at most max_packet_size
            const buf = self.send_buf[self.send_offset..];
            const n = @min(buf.len, self.max_packet_size);
            defer self.send_offset += n;

            self.send_op = io.Op.send(self.socket, buf[0..n], self, onSend, onSendFail);
            self.io_loop.submit(&self.send_op);
        }

        /// Send operation is completed, release pending resources and notify
        /// client that we are done with sending their buffers.
        fn sendCompleted(self: *Self, err: ?anyerror) void {
            if (err != null or self.send_buf.len == self.send_offset) {
                self.client.onSend(self.send_buf, err);
                self.send_buf = &.{};
                self.send_offset = 0;
            }
            if (err) |e| self.freeSendList(e);
        }

        fn freeSendList(self: *Self, err: anyerror) void {
            for (self.send_list.items) |buf|
                self.client.onSend(buf, err);
            self.send_list.clearAndFree();
        }

        fn onSend(self: *Self) io.Error!void {
            self.sendCompleted(null);
            self.sendPending();
        }

        fn onSendFail(self: *Self, err: anyerror) io.Error!void {
            switch (err) {
                error.BrokenPipe, error.ConnectionResetByPeer, error.ConnectionRefused => {},
                else => log.err("{} send failed {}", .{ self.address, err }),
            }
            self.sendCompleted(err);
            self.close();
        }

        fn onCancel(self: *Self, _: ?anyerror) void {
            self.close();
        }

        pub fn close(self: *Self) void {
            if (self.state == .closed) return;
            if (self.state != .closing) self.state = .closing;

            if (self.connect_op.active() and !self.close_op.active()) {
                self.close_op = io.Op.cancel(&self.connect_op, self, onCancel);
                return self.io_loop.submit(&self.close_op);
            }
            if (self.socket != 0 and !self.close_op.active()) {
                self.close_op = io.Op.shutdown(self.socket, self, onCancel);
                self.socket = 0;
                return self.io_loop.submit(&self.close_op);
            }

            if (self.connect_op.active() or
                self.send_op.active() or
                self.close_op.active())
                return;

            self.state = .closed;
            self.freeSendList(error.Closed);
            log.debug("{} closed", .{self.address});
            self.client.onClose();
        }
    };
}

const TestClient = struct {
    const Self = @This();
    udp: Sender(*Self),

    fn init(self: *Self, allocator: mem.Allocator, io_loop: *io.Loop, address: net.Address) void {
        self.* = .{
            .udp = Sender(*Self).init(allocator, io_loop, self, address),
        };
    }

    fn onSend(self: *Self, buf: []const u8, err: ?anyerror) void {
        _ = self;
        _ = buf;
        if (err) |e| {
            log.err("client onSend {}", .{e});
        }
    }

    fn onClose(self: *Self) void {
        _ = self;
    }
};

const testing = std.testing;

test {
    if (true) return error.SkipZigTest;
    // To run this test first start listening on udp port:
    // $ nc -kluvw 0 localhost 9000

    const allocator = testing.allocator;
    var io_loop: io.Loop = undefined;
    try io_loop.init(allocator, .{ .entries = 4, .recv_buffers = 0, .recv_buffer_len = 0 });
    defer io_loop.deinit();

    const address = try net.Address.resolveIp("127.0.0.1", 9000);

    var client: TestClient = undefined;
    client.init(allocator, &io_loop, address);

    try client.udp.send("iso medo u ducan\n");
    try client.udp.send("nije reko dobar dan\n");
    try client.udp.send("ajde medo van nisi reko dobar dan\n\n");

    for (0..5) |_| {
        try io_loop.tick();
    }
    client.udp.close();
    try io_loop.drain();
}
