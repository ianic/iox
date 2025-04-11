const std = @import("std");
const net = std.net;
const mem = std.mem;
const assert = std.debug.assert;
const posix = std.posix;
const testing = std.testing;

const io = @import("io.zig");

const log = std.log.scoped(.io_tcp);

pub const Sender = struct {
    const Self = @This();

    /// Handler callbacks
    pub const VTable = struct {
        /// send is done, buffers can be released now
        onSend: ?*const fn (*anyopaque, []const u8, ?anyerror) void = null,
        /// connection closed, cleanup done, safe to deinit
        onClose: ?*const fn (*anyopaque) void = null,
    };

    handler: *anyopaque,
    vtable: VTable,
    io_loop: *io.Loop,

    socket: posix.socket_t = 0,
    state: State = .closed,
    op: io.Op = .{},
    addr: net.Address,
    buf: []const u8 = &.{},

    const State = enum {
        closed,
        connecting,
        open,
        closing,
    };

    pub fn init(io_loop: *io.Loop, addr: net.Address, handler: *anyopaque, vtable: VTable) Self {
        return .{
            .io_loop = io_loop,
            .addr = addr,
            .handler = handler,
            .vtable = vtable,
            .state = .closed,
        };
    }

    /// Only one send operation can be submitted at a time.
    pub fn ready(self: *Self) bool {
        return !self.op.active() and self.state != .closing;
    }

    pub fn send(self: *Self, buf: []const u8) void {
        assert(self.ready());
        self.buf = buf;
        if (self.socket == 0) return self.createSocket();
        self.sendPending();
    }

    fn createSocket(self: *Self) void {
        self.state = .connecting;
        self.op = io.Op.connect(
            .{
                .socket_type = posix.SOCK.DGRAM | posix.SOCK.CLOEXEC,
                .addr = &self.addr,
            },
            self,
            onSocket,
            onError,
        );
        self.io_loop.submit(&self.op);
    }

    fn sendPending(self: *Self) void {
        if (self.buf.len == 0) return;
        self.op = io.Op.send(self.socket, self.buf, self, onSend, onError);
        self.io_loop.submit(&self.op);
    }

    fn onSocket(self: *Self, socket: posix.socket_t) io.Error!void {
        assert(self.socket == 0);
        self.socket = socket;
        if (self.state == .closing) {
            if (self.buf.len > 0) return self.sendCompleted(error.OperationCanceled);
            return self.close();
        }
        self.state = .open;
        self.sendPending();
    }

    /// Send operation is completed, release pending resources and notify
    /// handler that we are done with sending their buffers.
    fn sendCompleted(self: *Self, err: ?anyerror) void {
        if (self.vtable.onSend) |cb| cb(self.handler, self.buf, err);
        self.buf = &.{};
        if (self.state == .closing) return self.close();
    }

    fn onSend(self: *Self) io.Error!void {
        self.sendCompleted(null);
    }

    fn onError(self: *Self, err: anyerror) io.Error!void {
        self.sendCompleted(err);
    }

    fn onCancel(self: *Self, _: ?anyerror) void {
        self.close();
    }

    pub fn close(self: *Self) void {
        if (self.state == .closed) return;
        if (self.state != .closing) self.state = .closing;

        if (self.socket != 0 and !self.op.active()) {
            self.op = io.Op.closeSocket(self.socket, self, onCancel);
            self.socket = 0;
            return self.io_loop.submit(&self.op);
        }

        if (self.op.active())
            return;

        self.state = .closed;
        if (self.vtable.onClose) |cb| cb(self.handler);
    }
};

pub const Receiver = struct {
    const Self = @This();

    /// Handler callbacks
    pub const VTable = struct {
        /// send is done, buffers can be released now
        onRecv: *const fn (*anyopaque, []u8) anyerror!void,
        /// connection closed, cleanup done, safe to deinit
        onClose: ?*const fn (*anyopaque) void = null,
        /// unexpected error
        onError: ?*const fn (*anyopaque, anyerror) void = null,
    };

    handler: *anyopaque,
    vtable: VTable,
    io_loop: *io.Loop,
    op: io.Op = .{},
    recv_op: io.RecvmsgOp = .{},
    socket: posix.socket_t = 0,
    state: State = .closed,
    addr: net.Address = undefined,
    buffer: [1024 * 64]u8 = undefined,

    const State = enum {
        closed,
        binding,
        open,
        closing,
    };

    pub fn init(io_loop: *io.Loop, handler: *anyopaque, vtable: VTable) Self {
        return .{
            .io_loop = io_loop,
            .handler = handler,
            .vtable = vtable,
        };
    }

    pub fn bind(self: *Self, addr: net.Address) void {
        self.addr = addr;
        self.state = .binding;
        self.op = io.Op.createSocket(
            .{
                .socket_type = posix.SOCK.DGRAM | posix.SOCK.CLOEXEC,
                .addr = &self.addr,
            },
            self,
            onSocket,
            onError,
        );
        self.io_loop.submit(&self.op);
    }

    fn onSocket(self: *Self, socket: posix.socket_t) io.Error!void {
        self.socket = socket;
        self.op = io.Op.bind(socket, &self.addr, self, onBind, onError);
        self.io_loop.submit(&self.op);
    }

    fn onBind(self: *Self) io.Error!void {
        self.state = .open;
        self.recv_op.init(
            self.socket,
            self.addr.getOsSockLen(),
            &self.buffer,
            self,
            onRecv,
            onError,
        );
        self.recv_op.submit(self.io_loop);
    }

    fn onRecv(self: *Self, buf: []u8) io.Error!void {
        // NOTE: sender address is in self.recv_op.addr
        self.vtable.onRecv(self.handler, buf) catch |err| {
            return self.onError(err);
        };
        self.recv_op.submit(self.io_loop);
    }

    fn onError(self: *Self, err: anyerror) io.Error!void {
        if (err != error.OperationCanceled) {
            if (self.vtable.onError) |cb| cb(self.handler, err);
        }
        self.close();
    }

    fn onCancel(self: *Self, _: ?anyerror) void {
        self.close();
    }

    pub fn close(self: *Self) void {
        if (self.state == .closed) return;
        if (self.state != .closing) self.state = .closing;

        const recv_op = &self.recv_op.op;
        if (recv_op.active() and !recv_op.canceled() and !self.op.active()) {
            self.op = io.Op.cancel(recv_op, self, onCancel);
            return self.io_loop.submit(&self.op);
        }

        if (self.socket != 0 and !self.op.active()) {
            self.op = io.Op.closeSocket(self.socket, self, onCancel);
            self.socket = 0;
            return self.io_loop.submit(&self.op);
        }

        if (recv_op.active() or
            self.op.active())
            return;

        self.state = .closed;
        if (self.vtable.onClose) |cb| cb(self.handler);
    }
};

test "udp send/receive" {
    const SendHandler = struct {
        const Self = @This();
        udp: Sender,
        send_count: usize = 0,
        closed: bool = false,

        fn onSend(ptr: *anyopaque, iov: []const u8, err: ?anyerror) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.send_count += 1;
            if (err != null) unreachable;
            _ = iov;
        }
        fn onClose(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.closed = true;
        }
    };
    var send_handler: SendHandler = .{ .udp = undefined };

    const allocator = testing.allocator;
    var io_loop: io.Loop = undefined;
    try io_loop.init(allocator, .{ .entries = 16, .recv_buffers = 0 });
    defer io_loop.deinit();

    const RecvHandler = struct {
        const Self = @This();
        udp: Receiver,
        allocator: mem.Allocator,
        msgs: std.ArrayList([]const u8),
        closed: bool = false,

        fn onRecv(ptr: *anyopaque, bytes: []u8) io.Error!void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            try self.msgs.append(try self.allocator.dupe(u8, bytes));
        }

        fn onError(_: *anyopaque, err: anyerror) void {
            std.debug.print("onError: {}\n", .{err});
            unreachable;
        }
        fn onClose(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.closed = true;
        }
    };
    var recv_handler: RecvHandler = .{
        .allocator = allocator,
        .msgs = std.ArrayList([]const u8).init(allocator),
        .udp = undefined,
    };
    defer {
        for (recv_handler.msgs.items) |buf| allocator.free(buf);
        recv_handler.msgs.deinit();
    }
    recv_handler.udp = .init(&io_loop, &recv_handler, .{
        .onRecv = RecvHandler.onRecv,
        .onClose = RecvHandler.onClose,
        .onError = RecvHandler.onError,
    });
    var addr = try net.Address.resolveIp("127.0.0.1", 0);
    recv_handler.udp.bind(addr);

    while (true) {
        //std.debug.print(".", .{});
        try io_loop.tick();
        if (recv_handler.udp.state == .open) break;
    }

    // Read system assigned port into addr
    var addr_len: posix.socklen_t = addr.getOsSockLen();
    try posix.getsockname(recv_handler.udp.socket, &addr.any, &addr_len);

    send_handler.udp = .init(&io_loop, addr, &send_handler, .{
        .onClose = SendHandler.onClose,
        .onSend = SendHandler.onSend,
    });

    const msg1 = "0123456789" ** 10;
    send_handler.udp.send(msg1);
    while (true) {
        //std.debug.print(",", .{});
        try io_loop.tick();
        if (recv_handler.msgs.items.len > 0) break;
    }

    const msg2 = "abcdefghijk" ** 10;
    send_handler.udp.send(msg2);
    while (true) {
        //std.debug.print(";", .{});
        try io_loop.tick();
        if (recv_handler.msgs.items.len > 1) break;
    }

    recv_handler.udp.close();
    send_handler.udp.close();
    try io_loop.drain();

    try testing.expectEqualSlices(u8, msg1, recv_handler.msgs.items[0]);
    try testing.expectEqualSlices(u8, msg2, recv_handler.msgs.items[1]);

    try testing.expect(send_handler.closed);
    try testing.expect(recv_handler.closed);
}
