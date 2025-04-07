const std = @import("std");
const net = std.net;
const mem = std.mem;
const assert = std.debug.assert;
const posix = std.posix;
const io = @import("io.zig");

const log = std.log.scoped(.io_tcp);

pub const Sender = struct {
    const Self = @This();

    /// Handler callbacks
    pub const VTable = struct {
        /// send is done, buffers can be released now
        onSend: ?*const fn (*anyopaque, []posix.iovec_const, ?anyerror) void = null,
        /// connection closed, cleanup done, safe to deinit
        onClose: ?*const fn (*anyopaque) void = null,
    };

    handler: *anyopaque,
    vtable: VTable,
    io_loop: *io.Loop,

    socket: posix.socket_t = 0,
    state: State = .closed,
    op: io.Op = .{},
    iov: []posix.iovec_const = &.{},
    msghdr: posix.msghdr_const = .{
        .iov = undefined,
        .iovlen = 0,
        .name = null,
        .namelen = 0,
        .control = null,
        .controllen = 0,
        .flags = 0,
    },

    const State = enum {
        closed,
        connecting,
        open,
        closing,
    };

    pub fn init(io_loop: *io.Loop, handler: *anyopaque, vtable: VTable) Self {
        return .{
            .io_loop = io_loop,
            .handler = handler,
            .vtable = vtable,
            .state = .closed,
        };
    }

    /// Only one send operation can be submitted at a time.
    pub fn ready(self: *Self) bool {
        return !self.op.active() and self.state != .closing;
    }

    pub fn send(self: *Self, iov: []posix.iovec_const, addr: *net.Address) void {
        if (iov.len == 0) return;
        assert(self.ready());

        self.iov = iov;
        self.msghdr.iov = undefined;
        self.msghdr.iovlen = 0;
        self.msghdr.name = &addr.any;
        self.msghdr.namelen = addr.getOsSockLen();

        if (self.socket == 0) return self.createSocke(addr);
        self.sendPending();
    }

    fn createSocke(self: *Self, addr: *net.Address) void {
        self.state = .connecting;
        self.op = io.Op.createSocket(
            .{
                .socket_type = posix.SOCK.DGRAM | posix.SOCK.CLOEXEC,
                .addr = addr,
            },
            self,
            onSocket,
            onError,
        );
        self.io_loop.submit(&self.op);
    }

    fn sendPending(self: *Self) void {
        assert(self.msghdr.iovlen == 0);
        if (self.iov.len == 0) return;
        self.msghdr.iov = self.iov.ptr;
        self.msghdr.iovlen = @intCast(self.iov.len);
        self.op = io.Op.sendv(self.socket, &self.msghdr, self, onSend, onError);
        self.io_loop.submit(&self.op);
    }

    fn onSocket(self: *Self, socket: posix.socket_t) io.Error!void {
        assert(self.socket == 0);
        self.socket = socket;
        if (self.state == .closing) return self.close();
        self.state = .open;
        self.sendPending();
    }

    /// Send operation is completed, release pending resources and notify
    /// handler that we are done with sending their buffers.
    fn sendCompleted(self: *Self, err: ?anyerror) void {
        self.msghdr.iov = undefined;
        self.msghdr.iovlen = 0;
        if (self.vtable.onSend) |cb| cb(self.handler, self.iov, err);
        self.iov = &.{};
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
        onClose: ?*const fn (*anyopaque) void,
        /// unexpected error
        onError: ?*const fn (*anyopaque, anyerror) void,
    };

    handler: *anyopaque,
    vtable: VTable,
    io_loop: *io.Loop,
    op: io.Op = .{},
    close_op: io.Op = .{},
    socket: posix.socket_t = 0,
    state: State = .closed,

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

    pub fn bind(self: *Self, addr: *net.Address) void {
        self.state = .binding;
        self.op = io.Op.createSocket(
            .{
                .socket_type = posix.SOCK.DGRAM | posix.SOCK.CLOEXEC,
                .addr = addr,
            },
            self,
            onSocket,
            onError,
        );
        self.io_loop.submit(&self.op);
    }

    fn onSocket(self: *Self, socket: posix.socket_t) io.Error!void {
        self.socket = socket;
        const addr = self.op.args.socket.addr;
        self.op = io.Op.bind(socket, addr, self, onBind, onError);
        self.io_loop.submit(&self.op);
    }

    fn onBind(self: *Self) io.Error!void {
        self.state = .open;
        self.op = io.Op.recv(self.socket, self, onRecv, onError);
        self.io_loop.submit(&self.op);
    }

    fn onRecv(self: *Self, bytes: []u8) io.Error!void {
        self.vtable.onRecv(self.handler, bytes) catch |err| {
            return self.onError(err);
        };
        if (!self.op.hasMore() and !self.op.canceled() and self.state == .open)
            self.io_loop.submit(&self.op);
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

        if (self.op.active() and !self.op.canceled() and !self.close_op.active()) {
            self.close_op = io.Op.cancel(&self.op, self, onCancel);
            return self.io_loop.submit(&self.close_op);
        }

        if (self.socket != 0 and !self.close_op.active()) {
            self.close_op = io.Op.closeSocket(self.socket, self, onCancel);
            self.socket = 0;
            return self.io_loop.submit(&self.close_op);
        }

        if (self.close_op.active() or
            self.op.active())
            return;

        self.state = .closed;
        if (self.vtable.onClose) |cb| cb(self.handler);
    }
};

const testing = std.testing;
pub const FixedSendVec = @import("tcp.zig").FixedSendVec;

test "Sender" {
    //if (true) return error.SkipZigTest;
    // To run this test first start listening on udp port:
    // $ nc -kluvw 0 localhost 9000

    const SendHandler = struct {
        const Self = @This();
        udp: Sender,
        send_count: usize = 0,
        closed: bool = false,

        fn onSend(ptr: *anyopaque, iov: []posix.iovec_const, err: ?anyerror) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.send_count += 1;
            if (err != null) unreachable;
            _ = iov;
            //std.debug.print("onSend: iov.len: {} error: {any}\n", .{ iov.len, err });
        }
        fn onClose(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.closed = true;
        }
    };
    var send_handler: SendHandler = .{ .udp = undefined };

    const allocator = testing.allocator;
    var io_loop: io.Loop = undefined;
    try io_loop.init(allocator, .{ .entries = 16, .recv_buffers = 2, .recv_buffer_len = 64 * 1024 });
    defer io_loop.deinit();

    var addr = try net.Address.resolveIp("127.0.0.1", 9123);
    send_handler.udp = .init(&io_loop, &send_handler, .{
        .onClose = SendHandler.onClose,
        .onSend = SendHandler.onSend,
    });

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
    recv_handler.udp.bind(&addr);

    while (true) {
        std.debug.print(".", .{});
        try io_loop.tick();
        if (recv_handler.udp.state == .open) break;
    }

    var send_vec: FixedSendVec(4) = .{};
    assert(send_vec.prep("iso medo u ducan\n"));
    assert(send_vec.prep("nije reko dobar dan\n"));
    assert(send_vec.prep("ajde medo van nisi reko dobar dan\n"));
    assert(send_vec.prep("0123456789abcdf" ** 1024));
    send_handler.udp.send(send_vec.get(), &addr);

    while (true) {
        std.debug.print(",", .{});
        try io_loop.tick();
        if (recv_handler.msgs.items.len > 0) break;
    }

    recv_handler.udp.close();
    send_handler.udp.close();
    try io_loop.drain();

    try testing.expect(send_handler.closed);
    try testing.expect(recv_handler.closed);
}
