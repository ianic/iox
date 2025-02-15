const std = @import("std");
const net = std.net;
const mem = std.mem;
const assert = std.debug.assert;
const posix = std.posix;
const io = @import("io.zig");
const timer = @import("timer.zig");

const log = std.log.scoped(.io_tcp);

// iovlen in msghdr is limited by IOV_MAX in <limits.h>. On modern Linux
// systems, the limit is 1024. Each message has header and body: 2 iovecs that
// limits number of messages in a batch to 512.
// ref: https://man7.org/linux/man-pages/man2/readv.2.html
const max_iov = 1024;

pub fn Conn(comptime Handler: type) type {
    return struct {
        const Self = @This();

        allocator: mem.Allocator,
        io_loop: *io.Loop,
        handler: *Handler,
        socket: posix.socket_t,
        state: State = .closed,

        close_op: io.Op = .{},
        recv_op: io.Op = .{},
        recv_buf: RecvBuf,
        send_op: io.Op = .{},
        send_list: std.ArrayList(posix.iovec_const), // pending send buffers
        send_iov: []posix.iovec_const = &.{}, // because msghdr.iov is pointer
        send_msghdr: posix.msghdr_const = .{ .iov = undefined, .iovlen = 0, .name = null, .namelen = 0, .control = null, .controllen = 0, .flags = 0 },

        const State = enum {
            closed,
            open,
            closing,
        };

        pub fn init(
            self: *Self,
            allocator: mem.Allocator,
            io_loop: *io.Loop,
            handler: *Handler,
            socket: posix.socket_t,
        ) void {
            self.* = .{
                .allocator = allocator,
                .io_loop = io_loop,
                .handler = handler,
                .socket = socket,
                .send_list = std.ArrayList(posix.iovec_const).init(allocator),
                .recv_buf = RecvBuf.init(allocator),
                .state = .open,

                .close_op = .{},
                .recv_op = .{},
                .send_op = .{},
                .send_iov = &.{},
                .send_msghdr = .{ .iov = undefined, .iovlen = 0, .name = null, .namelen = 0, .control = null, .controllen = 0, .flags = 0 },
            };
            // start multishot receive
            self.recv_op = io.Op.recv(self.socket, self, onRecv, onRecvFail);
            self.io_loop.submit(&self.recv_op);

            handler.onConnect();
        }

        pub fn deinit(self: *Self) void {
            self.freeBuffers();
            self.allocator.free(self.send_iov);
            self.send_list.deinit();
            self.recv_buf.free();
            self.* = undefined;
        }

        /// Zero copy send it is callers responsibility to ensure lifetime of
        /// `buf` until `onSend(buf)` is called.
        pub fn sendZc(self: *Self, buf: []const u8) io.Error!void {
            if (self.state == .closed)
                return self.handler.onSend(buf);

            if (buf.len == 0)
                return try self.sendPending();

            // optimization
            if (!self.send_op.active() and self.send_iov.len > 0 and self.send_list.items.len == 0) {
                self.send_iov[0] = .{ .base = buf.ptr, .len = buf.len };
                self.send_msghdr.iovlen = 1;

                self.send_op = io.Op.sendv(self.socket, &self.send_msghdr, self, onSend, onSendFail);
                self.io_loop.submit(&self.send_op);
                return;
            }

            try self.send_list.append(.{ .base = buf.ptr, .len = buf.len });
            errdefer _ = self.send_list.pop(); // reset send_list on error
            try self.sendPending();
        }

        /// Vectorized zero copy send.
        /// Example:
        ///   sendVZc(&[_][]const u8{buf1, buf2, buf3});
        pub fn sendVZc(self: *Self, vec: []const []const u8) io.Error!void {
            if (self.state == .closed) {
                for (vec) |buf| self.handler.onSend(buf);
                return;
            }
            try self.send_list.ensureUnusedCapacity(vec.len);

            const send_list_len = self.send_list.items.len;
            for (vec) |buf| if (buf.len > 0)
                self.send_list.appendAssumeCapacity(.{ .base = buf.ptr, .len = buf.len });

            errdefer self.send_list.items.len = send_list_len; // reset send_list
            try self.sendPending();
        }

        /// Start send operation for buffers accumulated in send_list.
        fn sendPending(self: *Self) !void {
            if (self.send_op.active() or self.send_list.items.len == 0) return;

            // Move send_list buffers to send_iov, and prepare msghdr. send_list
            // can accumulate new buffers while send_iov is in the kernel.
            try self.prepareIov();
            // Start send operation
            self.send_op = io.Op.sendv(self.socket, &self.send_msghdr, self, onSend, onSendFail);
            self.io_loop.submit(&self.send_op);
        }

        fn prepareIov(self: *Self) !void {
            const iovlen: u32 = @min(max_iov, self.send_list.items.len);

            if (self.send_iov.len < iovlen) {
                // resize self.send_iov
                const iov = try self.allocator.alloc(posix.iovec_const, iovlen);
                errdefer self.allocator.free(iov);
                self.allocator.free(self.send_iov);
                self.send_iov = iov;
                self.send_msghdr.iov = self.send_iov.ptr;
            }
            // copy from send_list to send_iov
            @memcpy(self.send_iov[0..iovlen], self.send_list.items[0..iovlen]);
            // shrink self.send_list
            mem.copyForwards(posix.iovec_const, self.send_list.items[0..], self.send_list.items[iovlen..]);
            self.send_list.items.len -= iovlen;

            self.send_msghdr.iovlen = @intCast(iovlen);
        }

        /// Send operation is completed, release pending resources and notify
        /// handler that we are done with sending their buffers.
        fn sendCompleted(self: *Self) void {
            const iovlen: u32 = @intCast(self.send_msghdr.iovlen);
            self.send_msghdr.iovlen = 0;
            // Call handler callback for each sent buffer
            for (self.send_iov[0..iovlen]) |vec| {
                var buf: []const u8 = undefined;
                buf.ptr = vec.base;
                buf.len = vec.len;
                self.handler.onSend(buf);
            }
        }

        fn onSend(self: *Self) io.Error!void {
            self.sendCompleted();
            try self.sendPending();
        }

        fn onSendFail(self: *Self, err: anyerror) io.Error!void {
            switch (err) {
                error.BrokenPipe, error.ConnectionResetByPeer, error.OperationCanceled => {},
                else => self.handler.onError(err),
            }
            self.sendCompleted();
            self.close();
        }

        fn onRecv(self: *Self, bytes: []u8) io.Error!void {
            if (self.state == .closing) return;
            const buf = try self.recv_buf.append(bytes);
            const n = self.handler.onRecv(buf);
            self.recv_buf.set(buf[n..]) catch |err| {
                self.handler.onError(err);
                self.close();
            };

            if (!self.recv_op.hasMore() and self.state == .open)
                self.io_loop.submit(&self.recv_op);
        }

        fn onRecvFail(self: *Self, err: anyerror) io.Error!void {
            switch (err) {
                error.EndOfFile, error.ConnectionResetByPeer, error.OperationCanceled => {},
                else => self.handler.onError(err),
            }
            self.close();
        }

        fn onCancel(self: *Self, _: ?anyerror) void {
            self.close();
        }

        pub fn close(self: *Self) void {
            if (self.state == .closed) return;
            if (self.state != .closing) self.state = .closing;

            if (self.recv_op.active() and !self.close_op.active()) {
                self.close_op = io.Op.cancel(&self.recv_op, self, onCancel);
                return self.io_loop.submit(&self.close_op);
            }

            if (self.socket != 0 and !self.close_op.active()) {
                self.close_op = io.Op.shutdown(self.socket, self, onCancel);
                self.socket = 0;
                return self.io_loop.submit(&self.close_op);
            }

            if (self.recv_op.active() or
                self.send_op.active() or
                self.close_op.active())
                return;

            self.state = .closed;

            self.freeBuffers();
            self.handler.onClose();
        }

        fn freeBuffers(self: *Self) void {
            self.sendCompleted();
            for (self.send_list.items) |vec| {
                var buf: []const u8 = undefined;
                buf.ptr = vec.base;
                buf.len = vec.len;
                self.handler.onSend(buf);
            }
            self.send_list.clearAndFree();
        }
    };
}

pub const RecvBuf = struct {
    allocator: mem.Allocator,
    buf: []u8 = &.{},

    const Self = @This();

    pub fn init(allocator: mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn free(self: *Self) void {
        self.allocator.free(self.buf);
        self.buf = &.{};
    }

    pub fn append(self: *Self, bytes: []u8) ![]u8 {
        if (self.buf.len == 0) return bytes;
        const old_len = self.buf.len;
        self.buf = try self.allocator.realloc(self.buf, old_len + bytes.len);
        @memcpy(self.buf[old_len..], bytes);
        return self.buf;
    }

    pub fn set(self: *Self, bytes: []const u8) !void {
        if (bytes.len == 0) return self.free();
        if (self.buf.len == bytes.len and self.buf.ptr == bytes.ptr) return;

        const new_buf = try self.allocator.dupe(u8, bytes);
        self.free();
        self.buf = new_buf;
    }

    pub fn remove(self: *Self, n: usize) !void {
        if (self.buf.len == 0) return;
        const new_len = self.buf.len - n;
        self.buf = try self.allocator.realloc(self.buf, new_len);
    }
};

const testing = std.testing;

test "recv_buf remove" {
    var recv_buf = RecvBuf.init(testing.allocator);
    defer recv_buf.free();

    try recv_buf.set("iso medo u ducan ");
    _ = try recv_buf.append(@constCast("nije reko dobar dan"));
    try testing.expectEqual(36, recv_buf.buf.len);
    try testing.expectEqualStrings("iso medo u ducan nije reko dobar dan", recv_buf.buf);
    _ = try recv_buf.remove(20);
    try testing.expectEqual(16, recv_buf.buf.len);
    try testing.expectEqualStrings("iso medo u ducan", recv_buf.buf);
}

pub fn listenSocket(addr: net.Address) !posix.socket_t {
    return (try addr.listen(.{ .reuse_address = true })).stream.handle;
}

pub fn Listener(comptime Factory: type) type {
    return GenericListener(Factory, upgrade);
}

pub fn GenericListener(
    comptime Factory: type,
    comptime upgradeFn: *const fn (mem.Allocator, *io.Loop, anytype, posix.socket_t) io.Error!void,
) type {
    return struct {
        const Self = @This();

        allocator: mem.Allocator,
        socket: posix.socket_t = 0,
        io_loop: *io.Loop,
        accept_op: io.Op = .{},
        close_op: io.Op = .{},
        factory: *Factory,

        pub fn init(
            allocator: mem.Allocator,
            io_loop: *io.Loop,
            factory: *Factory,
        ) Self {
            return .{
                .allocator = allocator,
                .io_loop = io_loop,
                .factory = factory,
            };
        }

        /// Start multishot accept
        pub fn bind(self: *Self, addr: net.Address) !void {
            self.socket = try listenSocket(addr);
            self.accept_op = io.Op.accept(self.socket, self, onAccept, onAcceptFail);
            self.io_loop.submit(&self.accept_op);
        }

        fn onAccept(self: *Self, socket: posix.socket_t, addr: net.Address) io.Error!void {
            _ = addr;
            try upgradeFn(self.allocator, self.io_loop, self.factory, socket);
        }

        fn onAcceptFail(self: *Self, err: anyerror) io.Error!void {
            if (@hasDecl(Factory, "onError")) self.factory.onError(err);
            self.io_loop.submit(&self.accept_op); // restart operation
        }

        fn onCancel(self: *Self, _: ?anyerror) void {
            self.close();
        }

        /// Stop listening
        pub fn close(self: *Self) void {
            if (self.close_op.active()) return;
            if (self.accept_op.active()) {
                self.close_op = io.Op.cancel(&self.accept_op, self, onCancel);
                return self.io_loop.submit(&self.close_op);
            }
            if (self.socket != 0) {
                self.close_op = io.Op.shutdown(self.socket, self, onCancel);
                self.socket = 0;
                return self.io_loop.submit(&self.close_op);
            }
            self.factory.onClose();
        }
    };
}

pub fn Connector(comptime Factory: type) type {
    return GenericConnector(Factory, upgrade);
}

fn upgrade(allocator: mem.Allocator, io_loop: *io.Loop, factory: anytype, socket: posix.socket_t) io.Error!void {
    const handler, var conn = try factory.create();
    conn.init(allocator, io_loop, handler, socket);
}

pub fn GenericConnector(
    comptime Factory: type,
    comptime upgradeFn: *const fn (mem.Allocator, *io.Loop, anytype, posix.socket_t) io.Error!void,
) type {
    return struct {
        const Self = @This();

        allocator: mem.Allocator,
        address: std.net.Address,
        io_loop: *io.Loop,
        connect_op: io.Op = .{},
        close_op: io.Op = .{},
        factory: *Factory,

        pub fn init(
            allocator: mem.Allocator,
            io_loop: *io.Loop,
            factory: *Factory,
            address: net.Address,
        ) Self {
            return .{
                .allocator = allocator,
                .io_loop = io_loop,
                .factory = factory,
                .address = address,
            };
        }

        pub fn connect(self: *Self) void {
            if (self.connect_op.active() or self.close_op.active()) return;
            self.connect_op = io.Op.connect(
                .{ .addr = &self.address },
                self,
                onConnect,
                onConnectFail,
            );
            self.io_loop.submit(&self.connect_op);
        }

        fn onConnect(self: *Self, socket: posix.socket_t) io.Error!void {
            try upgradeFn(self.allocator, self.io_loop, self.factory, socket);
        }

        fn onConnectFail(self: *Self, err: anyerror) void {
            self.factory.onError(err);
            self.close();
        }

        fn onCancel(self: *Self, _: ?anyerror) void {
            self.close();
        }

        pub fn close(self: *Self) void {
            if (self.connect_op.active() and !self.close_op.active()) {
                self.close_op = io.Op.cancel(&self.connect_op, self, onCancel);
                return self.io_loop.submit(&self.close_op);
            }

            if (self.connect_op.active() or
                self.close_op.active())
                return;

            self.factory.onClose();
        }
    };
}

pub fn Client(Handler: type) type {
    return struct {
        const Self = @This();

        handler: *Handler,
        conn: *?Conn(Handler),
        connector: Connector(Self),

        pub fn connect(
            self: *Self,
            allocator: mem.Allocator,
            io_loop: *io.Loop,
            handler: *Handler,
            conn: *?Conn(Handler),
            addr: net.Address,
        ) void {
            self.* = .{
                .connector = Connector(Self).init(allocator, io_loop, self, addr),
                .handler = handler,
                .conn = conn,
            };
            self.conn.* = null;
            self.connector.connect();
        }

        pub fn reconnect(self: *Self) void {
            self.connector.connect();
        }

        pub fn create(self: *Self) !struct { *Handler, *Conn(Handler) } {
            self.conn.* = undefined;
            return .{ self.handler, &self.conn.*.? };
        }

        pub fn onError(self: *Self, err: anyerror) void {
            self.handler.onError(err);
        }

        pub fn onClose(self: *Self) void {
            self.handler.onClose();
        }
    };
}

pub fn Conn2(comptime Handler: type) type {
    return struct {
        const Self = @This();

        io_loop: *io.Loop,
        handler: *Handler,
        socket: posix.socket_t = 0,
        state: State = .closed,

        connect_op: io.Op = .{},
        close_op: io.Op = .{},
        recv_op: io.Op = .{},
        send_op: io.Op = .{},
        send_iov: []posix.iovec_const = &.{},
        send_msghdr: posix.msghdr_const = .{
            .iov = undefined,
            .iovlen = 0,
            .name = null,
            .namelen = 0,
            .control = null,
            .controllen = 0,
            .flags = 0,
        },

        timer_op: ?timer.Op = null,
        address: ?net.Address = null,
        options: Options = .{},
        reconnect_count: usize = 0,
        reconnect_delay: u32 = 0,
        recv_count: usize = 0,

        pub const Options = struct {
            reconnect: struct {
                enabled: bool = false,
                /// First reconnect try is immediately (0 delay), after that
                /// delay is doubled each time to reach max delay in this number
                /// of steps.
                steps_to_max: u4 = 5,
                /// Maximum reconnect delay.
                max_delay: u32 = 1000,
            } = .{},
            /// If there is no bytes received for this duration (in
            /// milliseconds) onRecvTimout callback will be called (if that
            /// method is defined in Handler).
            recv_idle_timeout: u32 = 60_000,
        };

        const State = enum {
            closed,
            connecting,
            open,
            closing,
        };

        pub fn init(io_loop: *io.Loop, handler: *Handler, options: Options) Self {
            return .{
                .io_loop = io_loop,
                .handler = handler,
                .options = options,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.timer_op) |*op| op.deinit();
        }

        pub fn accept(self: *Self, socket: posix.socket_t) void {
            assert(self.socket == 0);
            self.socket = socket;
            self.state = .open;
            // Start multishot receive
            self.recv_op = io.Op.recv(self.socket, self, onRecv, onRecvFail);
            self.io_loop.submit(&self.recv_op);
            if (@hasDecl(Handler, "onConnect")) self.handler.onConnect();
            if (@hasDecl(Handler, "onRecvTimeout") and self.options.recv_idle_timeout > 0)
                self.setTimer(self.options.recv_idle_timeout) catch {};
        }

        pub fn connect(self: *Self, address: net.Address) void {
            assert(self.state == .closed);
            self.address = address;
            self.state = .connecting;
            self.reconnect();
        }

        fn reconnect(self: *Self) void {
            assert(self.state == .connecting);
            assert(self.address != null);
            self.connect_op = io.Op.connect(
                .{ .addr = &self.address.? },
                self,
                onConnect,
                onConnectFail,
            );
            self.io_loop.submit(&self.connect_op);
        }

        fn scheduleReconnect(self: *Self) void {
            if (self.reconnect_count > 0) {
                self.reconnect_delay = @min(
                    @max(
                        1,
                        self.options.reconnect.max_delay / (@as(u16, 1) << self.options.reconnect.steps_to_max),
                        self.reconnect_delay * 2,
                    ),
                    self.options.reconnect.max_delay,
                );
            }
            self.reconnect_count += 1;
            if (self.reconnect_delay == 0)
                return self.reconnect();
            self.setTimer(self.reconnect_delay) catch {
                self.reconnect();
            };
        }

        fn setTimer(self: *Self, delay_ms: u32) !void {
            if (self.timer_op == null) {
                self.timer_op = undefined;
                self.timer_op.?.init(&self.io_loop.timer_queue, self, onTimer);
            }
            try self.timer_op.?.update(self.io_loop.tsFromDelay(delay_ms));
        }

        fn onTimer(self: *Self, _: u64) !u64 {
            switch (self.state) {
                .connecting => self.reconnect(),
                .open => {
                    if (self.recv_count == 0 and @hasDecl(Handler, "onRecvTimeout"))
                        self.handler.onRecvTimeout();
                    self.recv_count = 0;
                    if (self.options.recv_idle_timeout > 0)
                        return self.io_loop.tsFromDelay(self.options.recv_idle_timeout);
                },
                else => {},
            }
            return timer.infinite;
        }

        fn onConnect(self: *Self, socket: posix.socket_t) io.Error!void {
            if (self.state == .closing) return self.closeOrReconnect();
            assert(self.state == .connecting);
            self.reconnect_count = 0;
            self.accept(socket);
        }

        fn onConnectFail(self: *Self, err: anyerror) void {
            if (self.state == .closing) return self.closeOrReconnect();
            assert(self.state == .connecting);
            if (@hasDecl(Handler, "onDisconnect")) self.handler.onDisconnect(err);
            switch (err) {
                // Retriable errors: https://man7.org/linux/man-pages/man2/connect.2.html
                error.ConnectionRefused, // ECONNREFUSED
                error.OperationNowInProgress, // EINPROGRESS
                error.InterruptedSystemCall, // EINTR
                error.TransportEndpointIsAlreadyConnected, // EISCONN
                error.NetworkIsUnreachable, // ENETUNREACH
                error.NoRouteToHost, // EHOSTUNREACH
                error.ConnectionTimedOut, // ETIMEDOUT
                error.OperationCanceled, // ECANCELED
                error.OperationAlreadyInProgress, // EALREADY
                error.TryAgain, // EAGAIN
                => self.scheduleReconnect(),
                // Not retriable error
                else => return self.close(),
            }
        }

        pub fn sendReady(self: *Self) bool {
            return self.state == .open and !self.send_op.active();
        }

        pub fn send(self: *Self, iov: []posix.iovec_const) void {
            assert(self.sendReady());
            if (iov.len == 0) return;
            self.send_iov = iov;
            self.send_msghdr.iov = self.send_iov.ptr;
            self.send_msghdr.iovlen = @intCast(self.send_iov.len);
            self.send_op = io.Op.sendv(self.socket, &self.send_msghdr, self, onSend, onSendFail);
            self.io_loop.submit(&self.send_op);
        }

        /// Send operation is completed, release pending resources and notify
        /// handler that we are done with sending their buffers.
        fn sendCompleted(self: *Self, err: ?anyerror) void {
            self.send_msghdr.iov = undefined;
            self.send_msghdr.iovlen = 0;
            self.handler.onSend(self.send_iov, err);
        }

        fn onSend(self: *Self) io.Error!void {
            self.sendCompleted(null);
        }

        fn onSendFail(self: *Self, err: anyerror) io.Error!void {
            switch (err) {
                error.BrokenPipe, error.ConnectionResetByPeer, error.OperationCanceled => {},
                // The socket has been closed before the send operation is attempted.
                error.SocketOperationOnNonsocket => {},
                else => if (@hasDecl(Handler, "onError")) self.handler.onError(err),
            }
            self.sendCompleted(err);
            self.disconnected(err);
        }

        fn onRecv(self: *Self, bytes: []u8) io.Error!void {
            self.recv_count += 1;
            if (self.state == .closing) return;
            self.handler.onRecv(bytes);
            if (!self.recv_op.hasMore() and self.state == .open)
                self.io_loop.submit(&self.recv_op);
        }

        fn onRecvFail(self: *Self, err: anyerror) io.Error!void {
            switch (err) {
                error.EndOfFile, error.ConnectionResetByPeer, error.OperationCanceled => {},
                else => if (@hasDecl(Handler, "onError")) self.handler.onError(err),
            }
            self.disconnected(err);
        }

        pub fn close(self: *Self) void {
            if (self.state == .closed) return;
            self.state = .closing;
            self.closeOrReconnect();
        }

        fn onCancel(self: *Self, _: ?anyerror) void {
            self.closeOrReconnect();
        }

        fn closeOrReconnect(self: *Self) void {
            if (self.connect_op.active() and !self.close_op.active()) {
                self.close_op = io.Op.cancel(&self.connect_op, self, onCancel);
                return self.io_loop.submit(&self.close_op);
            }

            if (self.recv_op.active() and !self.close_op.active()) {
                self.close_op = io.Op.cancel(&self.recv_op, self, onCancel);
                return self.io_loop.submit(&self.close_op);
            }

            if (self.socket != 0 and !self.close_op.active()) {
                self.close_op = io.Op.shutdown(self.socket, self, onCancel);
                self.socket = 0;
                return self.io_loop.submit(&self.close_op);
            }

            if (self.recv_op.active() or
                self.send_op.active() or
                self.close_op.active() or
                self.connect_op.active())
                return;

            // Reconnect
            if (self.state == .connecting and self.options.reconnect.enabled and self.address != null)
                return self.scheduleReconnect();

            // Close
            self.state = .closed;
            self.handler.onClose();
        }

        fn disconnected(self: *Self, err: anyerror) void {
            if (@hasDecl(Handler, "onDisconnect")) self.handler.onDisconnect(err);
            if (self.state == .open)
                self.state = if (self.address != null and self.options.reconnect.enabled) .connecting else .closing;
            self.closeOrReconnect();
        }
    };
}

pub fn FixedSendVec(comptime size: usize) type {
    return struct {
        const Self = @This();

        iov: [size]posix.iovec_const = undefined,
        pos: usize = 0,

        pub fn prep(self: *Self, buf: []const u8) bool {
            if (buf.len == 0) return true;
            if (self.pos == self.iov.len) return false;
            self.iov[self.pos] = .{ .base = buf.ptr, .len = buf.len };
            self.pos += 1;
            return true;
        }

        pub fn get(self: *Self) []posix.iovec_const {
            defer self.pos = 0;
            return self.iov[0..self.pos];
        }
    };
}

pub fn Listener2(comptime Factory: type) type {
    return struct {
        const Self = @This();

        socket: posix.socket_t = 0,
        io_loop: *io.Loop,
        accept_op: io.Op = .{},
        close_op: io.Op = .{},
        factory: *Factory,

        pub fn init(
            io_loop: *io.Loop,
            factory: *Factory,
        ) Self {
            return .{
                .io_loop = io_loop,
                .factory = factory,
            };
        }

        /// Start multishot accept
        pub fn bind(self: *Self, addr: net.Address) !void {
            self.socket = try listenSocket(addr);
            self.accept_op = io.Op.accept(self.socket, self, onAccept, onAcceptFail);
            self.io_loop.submit(&self.accept_op);
        }

        fn onAccept(self: *Self, socket: posix.socket_t, addr: net.Address) io.Error!void {
            try self.factory.onAccept(self.io_loop, socket, addr);
        }

        fn onAcceptFail(self: *Self, err: anyerror) io.Error!void {
            if (@hasDecl(Factory, "onError")) self.factory.onError(err);
            self.io_loop.submit(&self.accept_op); // restart operation
        }

        fn onCancel(self: *Self, _: ?anyerror) void {
            self.close();
        }

        /// Stop listening
        pub fn close(self: *Self) void {
            if (self.close_op.active()) return;
            if (self.accept_op.active()) {
                self.close_op = io.Op.cancel(&self.accept_op, self, onCancel);
                return self.io_loop.submit(&self.close_op);
            }
            if (self.socket != 0) {
                self.close_op = io.Op.shutdown(self.socket, self, onCancel);
                self.socket = 0;
                return self.io_loop.submit(&self.close_op);
            }
            if (@hasDecl(Factory, "onError")) self.factory.onClose();
        }
    };
}

test "Conn2" {
    //if (true) return error.SkipZigTest;
    //
    // Run this test, in terminal start tcp listener on port 9999:
    // $ nc -l - p 9999
    // Stop listener, start again, stop...
    // Connection should reconnect and finish test when 10 attempts reached.

    const allocator = testing.allocator;
    var loop: io.Loop = undefined;
    try loop.init(allocator, .{
        .entries = 4,
        .recv_buffers = 2,
        .recv_buffer_len = 4096,
        .connect_timeout = .{ .sec = 1, .nsec = 0 },
    });
    defer loop.deinit();

    const Handler = struct {
        const Self = @This();
        tcp: Conn2(Self),
        send_vec: FixedSendVec(4) = .{},

        pub fn onError(_: *Self, err: anyerror) void {
            std.debug.print("onError {}\n", .{err});
        }

        pub fn onConnect(self: *Self) void {
            std.debug.print("onConnect\n", .{});
            assert(self.send_vec.prep("pero "));
            assert(self.send_vec.prep("zdero "));
            assert(self.send_vec.prep("jozo "));
            assert(self.send_vec.prep("bozo "));
            assert(!self.send_vec.prep("nemere "));
            self.tcp.send(self.send_vec.get());
        }

        pub fn onDisconnect(self: *Self, err: anyerror) void {
            std.debug.print("onDisconnect {} {}\n", .{ err, self.tcp.reconnect_count });
            if (self.tcp.reconnect_count == 10) self.tcp.close();
        }

        pub fn onRecv(_: *Self, bytes: []const u8) void {
            std.debug.print("onRecv {s}\n", .{bytes});
        }

        pub fn onSend(_: *Self, iov: []posix.iovec_const, err: ?anyerror) void {
            std.debug.print("onSend {?}\n", .{err});
            for (iov) |v| {
                std.debug.print("onSend v: {*} {}\n", .{ v.base, v.len });
            }
        }

        pub fn onClose(_: *Self) void {
            std.debug.print("onClose\n", .{});
        }

        pub fn onRecvTimeout(_: *Self) void {
            std.debug.print("onRecvTimeout\n", .{});
        }
    };

    var handler: Handler = .{ .tcp = undefined };
    handler.tcp = Conn2(Handler).init(&loop, &handler, .{
        .reconnect = .{ .enabled = true },
        .recv_idle_timeout = 10_000,
    });
    const addr = net.Address.initIp4([4]u8{ 127, 0, 0, 1 }, 9999);
    // const addr = net.Address.initIp4([4]u8{ 10, 0, 0, 1 }, 9999);
    handler.tcp.connect(addr);

    while (handler.tcp.state != .closed) {
        try loop.tick();
    }

    //_ = try loop.run();
}
