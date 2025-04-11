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

    io_loop: *io.Loop,
    bind_addr: net.Address,
    handler: *anyopaque,
    vtable: VTable,

    op: io.Op = .{},
    recv_op: io.RecvmsgOp = .{},
    socket: posix.socket_t = 0,
    buffer: ?[]u8 = null,
    state: State = .closed,

    const State = enum {
        closed,
        binding,
        open,
        closing,
    };

    pub fn init(
        io_loop: *io.Loop,
        bind_addr: net.Address,
        handler: *anyopaque,
        vtable: VTable,
    ) Self {
        return .{
            .bind_addr = bind_addr,
            .io_loop = io_loop,
            .handler = handler,
            .vtable = vtable,
        };
    }

    pub fn recv(self: *Self, buffer: []u8) void {
        assert(self.buffer == null);
        self.buffer = buffer;

        switch (self.state) {
            .open => self.recvSubmit(),
            .closed => self.bind(),
            .binding => {},
            .closing => {},
        }
    }

    fn recvSubmit(self: *Self) void {
        const buf = self.buffer.?;
        self.recv_op.submit(self.io_loop, buf);
    }

    fn bind(self: *Self) void {
        assert(self.socket == 0);
        self.state = .binding;
        self.op = io.Op.createSocket(
            .{
                .socket_type = posix.SOCK.DGRAM | posix.SOCK.CLOEXEC,
                .addr = &self.bind_addr,
            },
            self,
            onSocket,
            onError,
        );
        self.io_loop.submit(&self.op);
    }

    fn onSocket(self: *Self, socket: posix.socket_t) io.Error!void {
        self.socket = socket;
        self.op = io.Op.bind(socket, &self.bind_addr, self, onBind, onError);
        self.io_loop.submit(&self.op);
    }

    fn onBind(self: *Self) io.Error!void {
        self.recv_op.init(
            self.socket,
            self.bind_addr.getOsSockLen(),
            self,
            onRecv,
            onError,
        );
        self.state = .open;
        self.recvSubmit();
    }

    fn onRecv(self: *Self, buf: []u8) io.Error!void {
        self.buffer = null;
        // NOTE: sender address is in self.recv_op.addr
        self.vtable.onRecv(self.handler, buf) catch |err| {
            return self.onError(err);
        };
    }

    fn onError(self: *Self, err: anyerror) io.Error!void {
        self.buffer = null;
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

        fn onSend(ptr: *anyopaque, buf: []const u8, err: ?anyerror) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.send_count += 1;
            if (err != null) unreachable;
            _ = buf;
        }
        fn onClose(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            assert(!self.closed);
            self.closed = true;
        }
    };
    const RecvHandler = struct {
        const Self = @This();
        udp: Receiver,
        buffer: [100 + 110]u8 = undefined,
        buffer_pos: usize = 0,
        recv_count: usize = 0,
        closed: bool = false,

        fn onRecv(ptr: *anyopaque, bytes: []u8) io.Error!void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.buffer_pos += bytes.len;
            self.recv_count += 1;
        }

        pub fn recv(self: *Self) void {
            self.udp.recv(self.buffer[self.buffer_pos..]);
        }

        fn onError(_: *anyopaque, err: anyerror) void {
            std.debug.print("onError: {}\n", .{err});
            unreachable;
        }
        fn onClose(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            assert(!self.closed);
            self.closed = true;
        }
    };

    const allocator = testing.allocator;
    var io_loop: io.Loop = undefined;
    try io_loop.init(allocator, .{ .entries = 16, .recv_buffers = 0 });
    defer io_loop.deinit();

    var recv_handler: RecvHandler = .{ .udp = undefined };
    const addr = try net.Address.resolveIp("127.0.0.1", 9123);
    recv_handler.udp = .init(&io_loop, addr, &recv_handler, .{
        .onRecv = RecvHandler.onRecv,
        .onClose = RecvHandler.onClose,
        .onError = RecvHandler.onError,
    });

    var send_handler: SendHandler = .{ .udp = undefined };
    send_handler.udp = .init(&io_loop, addr, &send_handler, .{
        .onClose = SendHandler.onClose,
        .onSend = SendHandler.onSend,
    });

    {
        const msg1 = "0123456789" ** 10;
        send_handler.udp.send(msg1);
        recv_handler.recv();

        while (true) {
            //std.debug.print(",", .{});
            try io_loop.tick();
            if (recv_handler.recv_count > 0) break;
        }
        try testing.expectEqualSlices(u8, msg1, recv_handler.buffer[0..recv_handler.buffer_pos]);
    }

    {
        const buffer_head = recv_handler.buffer_pos;
        const msg2 = "abcdefghijk" ** 10;
        send_handler.udp.send(msg2);
        recv_handler.recv();
        while (true) {
            //std.debug.print(";", .{});
            try io_loop.tick();
            if (recv_handler.recv_count > 1) break;
        }
        try testing.expectEqualSlices(u8, msg2, recv_handler.buffer[buffer_head..recv_handler.buffer_pos]);
    }

    recv_handler.udp.close();
    send_handler.udp.close();
    try io_loop.drain();

    try testing.expect(send_handler.closed);
    try testing.expect(recv_handler.closed);
}
