const std = @import("std");
const net = std.net;
const mem = std.mem;
const assert = std.debug.assert;
const posix = std.posix;
const testing = std.testing;
const io = @import("io.zig");

pub const Sender = struct {
    const Self = @This();

    pub const Result = union(enum) {
        send: struct {
            buf: []const u8,
            err: ?anyerror,
        },
        close: void,
    };

    handler: *anyopaque,
    onComplete: *const fn (*anyopaque, Result) void,
    io_loop: *io.Loop,

    socket: posix.socket_t = 0,
    state: State = .closed,
    op: io.Op = .{},
    addr: net.Address,
    buf: ?[]const u8 = null,

    const State = enum {
        closed,
        connecting,
        open,
        sending,
        closing,
    };

    pub fn init(
        io_loop: *io.Loop,
        addr: net.Address,
        handler: *anyopaque,
        callback: *const fn (*anyopaque, Result) void,
    ) Self {
        return .{
            .io_loop = io_loop,
            .addr = addr,
            .handler = handler,
            .onComplete = callback,
            .state = .closed,
        };
    }

    /// Only one send operation can be submitted at a time.
    pub fn ready(self: *Self) bool {
        return !self.op.active() and self.state != .closing;
    }

    pub fn send(self: *Self, buf: []const u8) void {
        assert(self.ready());
        assert(self.buf == null);
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
        assert(self.buf != null);
        const buf = self.buf.?;
        self.op = io.Op.send(self.socket, buf, self, onSend, onError);
        self.io_loop.submit(&self.op);
        self.state = .sending;
    }

    fn onSocket(self: *Self, socket: posix.socket_t) io.Error!void {
        assert(self.socket == 0);
        self.socket = socket;
        if (self.state == .closing) {
            if (self.buf != null) return self.sendCompleted(error.OperationCanceled);
            return self.close();
        }
        self.state = .open;
        self.sendPending();
    }

    /// Send operation is completed, release pending resources and notify
    /// handler that we are done with sending their buffers.
    fn sendCompleted(self: *Self, err: ?anyerror) void {
        if (self.state == .sending) self.state = .open;
        const res = Result{ .send = .{ .buf = self.buf.?, .err = err } };
        self.buf = null;
        self.onComplete(self.handler, res);
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

        if (self.op.active()) return;
        if (self.socket != 0) {
            self.op = io.Op.closeSocket(self.socket, self, onCancel);
            self.socket = 0;
            return self.io_loop.submit(&self.op);
        }

        self.state = .closed;
        self.onComplete(self.handler, .{ .close = {} });
    }
};

pub const Receiver = struct {
    const Self = @This();

    pub const Msg = io.RecvmsgOp.Msg;

    pub const Result = union(enum) {
        bind: anyerror,
        recv: anyerror!Msg,
        close: void,
    };

    io_loop: *io.Loop,
    bind_addr: net.Address,
    bind_flags: io.Op.BindFlags,
    /// Handler of io callback operations
    handler: *anyopaque,
    /// Callback for io operations
    callback: *const fn (*anyopaque, Result) void,

    op: io.Op = .{},
    recv_op: io.RecvmsgOp = .{},
    socket: posix.socket_t = 0,
    state: State = .closed,

    const State = enum {
        /// Initial and final state
        closed,
        /// Creating socket and binding in progress
        binding,
        /// Ready state
        open,
        /// Receive operation submitted
        receiving,
        /// Closing in progress, if receive is submitted it needs to be canceled
        /// and then socket needs to be closed.
        closing,
    };

    pub fn init(
        io_loop: *io.Loop,
        bind_addr: net.Address,
        bind_flags: io.Op.BindFlags,
        handler: *anyopaque,
        callback: *const fn (*anyopaque, Result) void,
    ) Self {
        return .{
            .bind_addr = bind_addr,
            .bind_flags = bind_flags,
            .io_loop = io_loop,
            .handler = handler,
            .callback = callback,
        };
    }

    pub fn recv(self: *Self, buffer: []u8) void {
        assert(self.state == .open or self.state == .closed);
        self.recv_op.setBuffer(buffer);

        switch (self.state) {
            .open => self.recvSubmit(),
            .closed => self.bind(),
            .binding, .receiving, .closing => unreachable,
        }
    }

    fn recvSubmit(self: *Self) void {
        assert(self.state == .open);
        self.io_loop.submit(&self.recv_op.op);
        self.state = .receiving;
    }

    fn bind(self: *Self) void {
        assert(self.state == .closed);
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
        self.op = io.Op.bind(socket, &self.bind_addr, self.bind_flags, self, onBind, onError);
        self.io_loop.submit(&self.op);
    }

    fn onBind(self: *Self) io.Error!void {
        self.recv_op.init(
            self.socket,
            self.bind_addr.getOsSockLen(),
            self,
            onRecv,
        );
        self.state = .open;
        self.recvSubmit();
    }

    fn onRecv(self: *Self, err_msg: anyerror!Msg) io.Error!void {
        if (self.state == .closing) return;
        if (self.state == .receiving) self.state = .open;

        self.callback(self.handler, .{ .recv = err_msg });
    }

    fn onError(self: *Self, err: anyerror) io.Error!void {
        if (self.state == .closing) return;
        self.callback(self.handler, .{ .bind = err });
    }

    fn onCancel(self: *Self, _: ?anyerror) void {
        self.close();
    }

    pub fn close(self: *Self) void {
        if (self.state == .closed) return;
        if (self.state != .closing) self.state = .closing;

        if (self.op.active()) return;
        const recv_op = &self.recv_op.op;
        if (recv_op.active() and !recv_op.canceled()) {
            self.op = io.Op.cancel(recv_op, self, onCancel);
            return self.io_loop.submit(&self.op);
        }
        if (self.socket != 0) {
            self.op = io.Op.closeSocket(self.socket, self, onCancel);
            self.socket = 0;
            return self.io_loop.submit(&self.op);
        }
        if (recv_op.active()) return;

        self.state = .closed;
        self.callback(self.handler, .{ .close = {} });
    }
};

test "udp send/receive" {
    const SendHandler = struct {
        const Self = @This();
        udp: Sender,
        send_count: usize = 0,
        closed: bool = false,

        fn onComplete(ptr: *anyopaque, res: Sender.Result) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            switch (res) {
                .send => |r| {
                    self.send_count += 1;
                    if (r.err != null) unreachable;
                },
                .close => {
                    assert(!self.closed);
                    self.closed = true;
                },
            }
        }
    };

    const RecvHandler = struct {
        const Self = @This();
        udp: Receiver,
        buffer: [100 + 110 + 1]u8 = undefined,
        buffer_pos: usize = 0,
        recv_count: usize = 0,
        closed: bool = false,
        err: ?anyerror = null,

        fn onComplete(ptr: *anyopaque, res: Receiver.Result) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            switch (res) {
                .bind => |_| unreachable,
                .close => {
                    assert(!self.closed);
                    self.closed = true;
                },
                .recv => |err_msg| {
                    self.recv_count += 1;
                    const msg = err_msg catch |err| {
                        self.err = err;
                        return;
                    };
                    self.buffer_pos += msg.bytes.len;
                    if (msg.flags.trunc) {
                        self.err = error.MessageTruncated;
                    }
                },
            }
        }

        pub fn recv(self: *Self) void {
            self.udp.recv(self.buffer[self.buffer_pos..]);
        }
    };

    const allocator = testing.allocator;
    var io_loop: io.Loop = undefined;
    try io_loop.init(allocator, .{ .entries = 16, .recv_buffers = 0 });
    defer io_loop.deinit();

    const addr = try net.Address.resolveIp("127.0.0.1", 9123);
    var recv_handler: RecvHandler = .{ .udp = undefined };
    recv_handler.udp = .init(&io_loop, addr, &recv_handler, RecvHandler.onComplete);

    var send_handler: SendHandler = .{ .udp = undefined };
    send_handler.udp = .init(&io_loop, addr, &send_handler, SendHandler.onComplete);

    { // Send and receive 100 bytes
        const msg1 = "0123456789" ** 10;
        send_handler.udp.send(msg1);
        recv_handler.recv();

        while (true) {
            try io_loop.tick();
            if (recv_handler.recv_count > 0) break;
        }
        try testing.expectEqualSlices(u8, msg1, recv_handler.buffer[0..recv_handler.buffer_pos]);
    }

    { // Send and recive 110 bytes
        const buffer_head = recv_handler.buffer_pos;
        const msg2 = "abcdefghijk" ** 10;
        send_handler.udp.send(msg2);
        recv_handler.recv();
        while (true) {
            try io_loop.tick();
            if (recv_handler.recv_count > 1) break;
        }
        try testing.expectEqualSlices(u8, msg2, recv_handler.buffer[buffer_head..recv_handler.buffer_pos]);
    }

    { // Msg3 will be truncated on receive!
        const buffer_head = recv_handler.buffer_pos;
        const msg3 = "xy";
        send_handler.udp.send(msg3);
        recv_handler.recv();
        while (true) {
            try io_loop.tick();
            if (recv_handler.recv_count > 2) break;
        }
        try testing.expect(recv_handler.err != null);
        try testing.expectEqual(error.MessageTruncated, recv_handler.err.?);
        try testing.expectEqual(buffer_head + 1, recv_handler.buffer_pos);
        try testing.expectEqualSlices(u8, msg3[0..1], recv_handler.buffer[buffer_head..]);
    }

    recv_handler.recv();
    recv_handler.udp.close();
    send_handler.udp.close();
    try io_loop.drain();

    try testing.expect(send_handler.closed);
    try testing.expect(recv_handler.closed);
}
