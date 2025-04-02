const std = @import("std");
const net = std.net;
const mem = std.mem;
const assert = std.debug.assert;
const posix = std.posix;
const io = @import("io.zig");
const timer = @import("timer.zig");
const testing = std.testing;

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

/// Basic tcp connection. After init call accept with tcp server accepted socket
/// or connect with address to connect to.
///
/// Caller provides handler and vtable of handler callback functions. Callback
/// will be used to notify handler; onConnect when connection is establisehd
/// onRecv when data is received ...
///
///
/// Interface:
///   accept(posix.socket_t) void      - init server connection
///   connect(net.Address) void        - start client connection
///   send(iov: []iovec_const) void    - send data
///   sendReady() bool                 - only one send operation at a time
///   close() void                     - close tcp connection
///
pub const Conn = struct {
    const Self = @This();

    /// Handler callbacks
    /// Error returned in onRecv/onConnect callbacks will close connection.
    pub const VTable = struct {
        /// data is received
        onRecv: *const fn (*anyopaque, []u8) anyerror!void,
        /// send is done, buffers can be released now
        onSend: *const fn (*anyopaque, []posix.iovec_const, ?anyerror) void,
        /// connection closed, cleanup done, safe to deinit
        onClose: *const fn (*anyopaque) void,

        /// Optional callbacks
        /// tcp connection is established
        onConnect: ?*const fn (*anyopaque) anyerror!void = null,
        /// connection dropped, will reconnect if configured
        onDisconnect: ?*const fn (*anyopaque, anyerror) void = null,
        /// timeout on receive, time to send application ping
        onRecvTimeout: ?*const fn (*anyopaque) void = null,
        /// unexpected error
        onError: ?*const fn (*anyopaque, anyerror) void = null,
    };

    handler: *anyopaque,
    vtable: VTable,

    io_loop: *io.Loop,
    state: State = .closed,
    socket: posix.socket_t = 0,
    address: ?net.Address = null,

    timer_op: ?timer.Op = null,
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

    options: Options = .{},
    /// Number of consecutive reconnect, use this in onDisconnect to decide
    /// when it is enough.
    reconnect_count: usize = 0,
    /// Current reconnect delay, it will double in each cycle
    reconnect_delay: u32 = 0,
    /// Number of recv since last timeout
    recv_count: usize = 0,
    /// Number of consecutive timeouts
    recv_timeout_count: usize = 0,

    const State = enum {
        closed,
        connecting,
        open,
        closing,
    };

    pub fn init(
        io_loop: *io.Loop,
        handler: *anyopaque,
        vtable: VTable,
        options: Options,
    ) Self {
        return .{
            .io_loop = io_loop,
            .handler = handler,
            .vtable = vtable,
            .options = options,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.timer_op) |*op| op.deinit();
    }

    /// Open connection on socket accepted by tcp server.
    pub fn accept(self: *Self, socket: posix.socket_t) void {
        assert(self.state == .closed);
        self.open(socket);
    }

    fn open(self: *Self, socket: posix.socket_t) void {
        assert(self.socket == 0);
        self.socket = socket;
        self.state = .open;
        self.recv_timeout_count = 0;
        // Start multishot receive
        self.recv_op = io.Op.recv(self.socket, self, onRecv, onRecvFail);
        self.io_loop.submit(&self.recv_op);
        if (self.vtable.onRecvTimeout != null and self.options.recv_idle_timeout > 0)
            self.setTimer(self.options.recv_idle_timeout) catch {};
        // Raise onConnect event
        if (self.vtable.onConnect) |cb| cb(self.handler) catch |err| {
            if (self.vtable.onError) |cbe| cbe(self.handler, err);
            return self.close();
        };
    }

    /// Connect to the remote tcp server. Use options in init to configure retries.
    pub fn connect(self: *Self, address: net.Address) void {
        assert(self.state == .closed);
        self.address = address;
        self.state = .connecting;
        self.connectSubmit();
    }

    fn connectSubmit(self: *Self) void {
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

    fn connectSchedule(self: *Self) void {
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
            return self.connectSubmit();
        self.setTimer(self.reconnect_delay) catch {
            self.connectSubmit();
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
            .connecting => self.connectSubmit(),
            .open => {
                if (self.recv_count == 0) {
                    self.recv_timeout_count += 1;
                    if (self.vtable.onRecvTimeout) |cb| cb(self.handler);
                }
                self.recv_count = 0;
                if (self.options.recv_idle_timeout > 0)
                    return self.io_loop.tsFromDelay(self.options.recv_idle_timeout);
            },
            else => {},
        }
        return timer.infinite;
    }

    /// Successful connect callback
    fn onConnect(self: *Self, socket: posix.socket_t) io.Error!void {
        if (self.state == .closing) return self.closeOrReconnect();
        assert(self.state == .connecting);
        self.reconnect_count = 0;
        self.open(socket);
    }

    /// Failed connect callback
    fn onConnectFail(self: *Self, err: anyerror) void {
        if (self.state == .closing) return self.closeOrReconnect();
        assert(self.state == .connecting);
        if (self.vtable.onDisconnect) |cb| cb(self.handler, err);
        if (self.options.reconnect.enabled)
            self.connectSchedule()
        else
            self.close();
    }

    pub fn sendActive(self: *Self) bool {
        return self.send_op.active();
    }

    /// Only one send operation can be submitted at a time.
    pub fn sendReady(self: *Self) bool {
        return self.state == .open and !self.send_op.active();
    }

    /// Prepare vectored send operation. When all data is copied to the
    /// kernel buffers, or the operations is failed, handler.onSend will be
    /// called. Buffers in the iov has to have lifetame at least until
    /// handler.onSend is called.
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
        self.vtable.onSend(self.handler, self.send_iov, err);
    }

    /// Successful send callback
    fn onSend(self: *Self) io.Error!void {
        self.sendCompleted(null);
    }

    /// Failed send callback
    fn onSendFail(self: *Self, err: anyerror) io.Error!void {
        switch (err) {
            error.BrokenPipe, error.ConnectionResetByPeer, error.OperationCanceled => {},
            // The socket has been closed before the send operation is attempted.
            error.SocketOperationOnNonsocket => {},
            else => if (self.vtable.onError) |cb| cb(self.handler, err),
        }
        self.sendCompleted(err);
        self.disconnected(err);
    }

    /// Successful recv callback
    fn onRecv(self: *Self, bytes: []u8) io.Error!void {
        self.recv_count += 1;
        self.recv_timeout_count = 0;
        if (self.state == .closing) return;
        self.vtable.onRecv(self.handler, bytes) catch |err| {
            if (self.vtable.onError) |cb| cb(self.handler, err);
            return self.close();
        };
        if (!self.recv_op.hasMore() and !self.recv_op.canceled() and self.state == .open)
            self.io_loop.submit(&self.recv_op);
    }

    /// Failed recv callback
    fn onRecvFail(self: *Self, err: anyerror) io.Error!void {
        switch (err) {
            error.EndOfFile, error.ConnectionResetByPeer, error.OperationCanceled => {},
            else => if (self.vtable.onError) |cb| cb(self.handler, err),
        }
        self.disconnected(err);
    }

    /// Close tcp connection. Caller should wait for handler.onClose to
    /// deinit this.
    pub fn close(self: *Self) void {
        if (self.state == .closed) return;
        if (self.state == .closing) return;
        self.state = .closing;
        self.closeOrReconnect();
    }

    fn onCancel(self: *Self, _: ?anyerror) void {
        self.closeOrReconnect();
    }

    /// Submit cancel/close on pending operations/open socket. Completed
    /// operations will again call this function. When all is closed it will
    /// proceed to close or reconnect.
    fn closeOrReconnect(self: *Self) void {
        if (self.connect_op.active() and !self.connect_op.canceled() and !self.close_op.active()) {
            self.close_op = io.Op.cancel(&self.connect_op, self, onCancel);
            return self.io_loop.submit(&self.close_op);
        }

        if (self.recv_op.active() and !self.recv_op.canceled() and !self.close_op.active()) {
            self.close_op = io.Op.cancel(&self.recv_op, self, onCancel);
            return self.io_loop.submit(&self.close_op);
        }

        if (self.socket != 0 and !self.close_op.active()) {
            self.close_op = io.Op.closeSocket(self.socket, self, onCancel);
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
            return self.connectSchedule();

        // Close
        self.state = .closed;
        self.vtable.onClose(self.handler);
    }

    fn disconnected(self: *Self, err: anyerror) void {
        // state == closing is callers initiated close no need to notify about that
        if (self.state != .closing) if (self.vtable.onDisconnect) |cb| cb(self.handler, err);
        self.reconnect();
    }

    fn reconnect(self: *Self) void {
        if (self.state == .closed) return;
        if (self.state == .open)
            self.state = if (self.address != null and self.options.reconnect.enabled) .connecting else .closing;
        self.closeOrReconnect();
    }
};

/// Conn can have only one send operation active, BufferedConn collects buffers
/// to be sent into pending list while previous send operation is active.
/// Removes burden of checking conn.sendReady from the Handler. Handler can send
/// in any moment.
///
/// Receive is also buffered, allowing handler to consume only part of the data.
/// It now returns number of bytes consumed from the provided data. New arrivals
/// will be appended to the unconsumed part for the following calls.
///
/// Interface:
///   accept(posix.socket_t) void      - init server connection
///   connect(net.Address) void        - start client connection
///   send([]const u8) void            - send buffer
///   sendv([][]const u8) void         - vectored send
///   conn.close() void                - close tcp connection
///
pub const BufferedConn = struct {
    const Self = @This();

    pub const VTable = struct {
        /// data received, returns number of bytes consumed
        onRecv: *const fn (*anyopaque, []u8) anyerror!usize,
        /// send done, buffer released
        onSend: *const fn (*anyopaque, []const u8) void,
        /// cleanup done, safe to deinit
        onClose: *const fn (*anyopaque) void,

        /// tcp connection established
        onConnect: ?*const fn (*anyopaque) anyerror!void = null,
        /// connection disrupted
        onDisconnect: ?*const fn (*anyopaque, anyerror) void = null,
        /// timeout on receive (time to send application ping)
        onRecvTimeout: ?*const fn (*anyopaque) void = null,
        /// unexpected error
        onError: ?*const fn (*anyopaque, anyerror) void = null,
    };

    handler: *anyopaque,
    vtable: VTable,

    conn: Conn,
    allocator: mem.Allocator,
    buf_recv: BufferedRecv,
    /// pending send buffers
    pending: std.ArrayListUnmanaged(posix.iovec_const),
    /// growable buffers for conn.send
    send_iov: []posix.iovec_const = &.{},
    /// number of send_iov buffers currently in the kernel
    iovlen: usize = 0,

    pub fn init(
        self: *Self,
        allocator: mem.Allocator,
        io_loop: *io.Loop,
        handler: *anyopaque,
        vtable: VTable,
        options: Options,
    ) void {
        self.* = .{
            .handler = handler,
            .vtable = vtable,
            .conn = Conn.init(
                io_loop,
                self,
                .{
                    .onRecv = Self.onRecv,
                    .onSend = Self.onSend,
                    .onClose = Self.onClose,
                    .onConnect = Self.onConnect,
                    .onDisconnect = vtable.onDisconnect,
                    .onError = vtable.onError,
                    .onRecvTimeout = vtable.onRecvTimeout,
                },
                options,
            ),
            .allocator = allocator,
            .pending = .empty,
            .buf_recv = .{},
            .send_iov = &.{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.clearSendList();
        self.pending.deinit(self.allocator);
        self.allocator.free(self.send_iov);
        self.buf_recv.deinit(self.allocator);
        self.conn.deinit();
        self.* = undefined;
    }

    /// Open connection on socket accepted by tcp server.
    pub fn accept(self: *Self, socket: posix.socket_t) void {
        self.conn.accept(socket);
    }

    /// Connect to the remote tcp server. Use options in init to configure retries.
    pub fn connect(self: *Self, address: net.Address) void {
        self.conn.connect(address);
    }

    fn clearSendList(self: *Self) void {
        // buffers in pending
        for (self.pending.items) |vec|
            self.vtable.onSend(self.handler, bufFromVec(vec));
        self.pending.clearAndFree(self.allocator);
        // buffers in send_iov
        for (self.send_iov[0..self.iovlen]) |vec|
            self.vtable.onSend(self.handler, bufFromVec(vec));
    }

    /// Send data. It is callers responsibility to ensure lifetime of
    /// buf until handler.onSend(buf) is called.
    pub fn send(self: *Self, buf: []const u8) io.Error!void {
        if (self.conn.state == .closed)
            return self.vtable.onSend(self.handler, buf);
        if (buf.len == 0)
            return try self.sendPending();
        const vec = vecFromBuf(buf);

        // optimization
        if (self.conn.sendReady() and self.send_iov.len > 0 and self.pending.items.len == 0) {
            self.iovlen = 1;
            self.send_iov[0] = vec;
            self.conn.send(self.send_iov[0..self.iovlen]);
            return;
        }

        try self.pending.append(self.allocator, vec);
        errdefer _ = self.pending.pop(); // reset on error
        try self.sendPending();
    }

    /// Vectored send.
    /// Example:
    ///   sendv(&[_][]const u8{buf1, buf2, buf3});
    pub fn sendv(self: *Self, bufs: []const []const u8) io.Error!void {
        if (self.conn.state == .closed) {
            for (bufs) |buf| self.vtable.onSend(self.handler, buf);
            return;
        }
        try self.pending.ensureUnusedCapacity(self.allocator, bufs.len);

        const before_len = self.pending.items.len;
        for (bufs) |buf| if (buf.len > 0)
            self.pending.appendAssumeCapacity(vecFromBuf(buf));

        errdefer self.pending.items.len = before_len;
        try self.sendPending();
    }

    /// Start send operation for buffers accumulated in pending.
    fn sendPending(self: *Self) !void {
        if (!self.conn.sendReady() or self.pending.items.len == 0) return;
        self.conn.send(try self.prepareIov());
    }

    /// Move pending buffers to send_iov. Pending can accumulate new
    /// buffers while send_iov is in the kernel.
    fn prepareIov(self: *Self) ![]posix.iovec_const {
        const iovlen: u32 = @min(max_iov, self.pending.items.len);

        if (self.send_iov.len < iovlen) {
            // resize self.send_iov
            const iov = try self.allocator.alloc(posix.iovec_const, iovlen);
            errdefer self.allocator.free(iov);
            self.allocator.free(self.send_iov);
            self.send_iov = iov;
        }
        // copy from send_list to send_iov
        @memcpy(self.send_iov[0..iovlen], self.pending.items[0..iovlen]);
        // shrink self.send_list
        mem.copyForwards(posix.iovec_const, self.pending.items[0..], self.pending.items[iovlen..]);
        self.pending.items.len -= iovlen;
        self.iovlen = iovlen;

        return self.send_iov[0..self.iovlen];
    }

    fn onSend(context: *anyopaque, iov: []posix.iovec_const, err: ?anyerror) void {
        const self: *Self = @ptrCast(@alignCast(context));
        self.iovlen = 0;
        for (iov) |vec|
            self.vtable.onSend(self.handler, bufFromVec(vec));
        if (err == null)
            self.sendPending() catch |e| {
                if (self.vtable.onError) |cb| cb(self.handler, e);
                self.close();
            };
    }

    fn onRecv(context: *anyopaque, bytes: []u8) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(context));
        try self.buf_recv.onRecv(self.allocator, bytes, self.handler, self.vtable.onRecv);
    }

    /// Close tcp connection. Caller should wait for handler.onClose to
    /// deinit this.
    pub fn close(self: *Self) void {
        self.conn.close();
    }

    fn onClose(context: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(context));
        self.clearSendList();
        self.vtable.onClose(self.handler);
    }

    fn onConnect(context: *anyopaque) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(context));
        try self.sendPending();
        if (self.vtable.onConnect) |cb| try cb(self.handler);
    }
};

pub const Server = struct {
    const Self = @This();

    pub const VTable = struct {
        onAccept: *const fn (*anyopaque, *io.Loop, posix.socket_t, net.Address) io.Error!void,
        onClose: ?*const fn (*anyopaque) void = null,
        onError: ?*const fn (*anyopaque, anyerror) void = null,
    };

    context: *anyopaque,
    vtable: VTable,
    socket: posix.socket_t = 0,
    io_loop: *io.Loop,
    accept_op: io.Op = .{},
    close_op: io.Op = .{},

    pub fn init(
        io_loop: *io.Loop,
        context: *anyopaque,
        vtable: VTable,
    ) Self {
        return .{
            .io_loop = io_loop,
            .context = context,
            .vtable = vtable,
        };
    }

    /// Start multishot accept
    pub fn bind(self: *Self, addr: net.Address) !void {
        self.socket = try listenSocket(addr);
        self.accept_op = io.Op.accept(self.socket, self, onAccept, onAcceptFail);
        self.io_loop.submit(&self.accept_op);
    }

    fn onAccept(self: *Self, socket: posix.socket_t, addr: net.Address) io.Error!void {
        try self.vtable.onAccept(self.context, self.io_loop, socket, addr);
    }

    fn onAcceptFail(self: *Self, err: anyerror) io.Error!void {
        switch (err) {
            error.OperationCanceled => {},
            else => {
                if (self.vtable.onError) |cb| cb(self.context, err);
                self.io_loop.submit(&self.accept_op); // restart operation
            },
        }
    }

    fn onCancel(self: *Self, _: ?anyerror) void {
        self.close();
    }

    /// Stop listening
    pub fn close(self: *Self) void {
        if (self.close_op.active()) return;
        if (self.accept_op.active() and !self.accept_op.canceled()) {
            self.close_op = io.Op.cancel(&self.accept_op, self, onCancel);
            return self.io_loop.submit(&self.close_op);
        }
        if (self.socket != 0) {
            self.close_op = io.Op.closeSocket(self.socket, self, onCancel);
            self.socket = 0;
            return self.io_loop.submit(&self.close_op);
        }
        if (self.vtable.onClose) |cb| cb(self.context);
    }
};

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

pub const BufferedRecv = struct {
    const Self = @This();

    buf: []u8 = &.{},

    pub fn deinit(self: *Self, allocator: mem.Allocator) void {
        self.free(allocator);
    }

    fn free(self: *Self, allocator: mem.Allocator) void {
        if (self.buf.len == 0) return;
        allocator.free(self.buf);
        self.buf = &.{};
    }

    fn append(self: *Self, allocator: mem.Allocator, bytes: []u8) ![]u8 {
        if (self.buf.len == 0) return bytes;
        const old_len = self.buf.len;
        self.buf = try allocator.realloc(self.buf, old_len + bytes.len);
        @memcpy(self.buf[old_len..], bytes);
        return self.buf;
    }

    fn set(self: *Self, allocator: mem.Allocator, bytes: []const u8) !void {
        if (bytes.len == 0) return self.free(allocator);
        if (self.buf.len == bytes.len and self.buf.ptr == bytes.ptr) return;

        const new_buf = try allocator.dupe(u8, bytes);
        self.free(allocator);
        self.buf = new_buf;
    }

    pub fn onRecv(
        self: *Self,
        allocator: mem.Allocator,
        bytes: []u8,
        context: *anyopaque,
        cb: *const fn (*anyopaque, []u8) anyerror!usize,
    ) !void {
        const buf = try self.append(allocator, bytes);
        const n = try cb(context, buf);
        try self.set(allocator, buf[n..]);
    }
};

pub fn listenSocket(addr: std.net.Address) !std.posix.socket_t {
    return (try addr.listen(.{ .reuse_address = true })).stream.handle;
}

test "Conn" {
    // if (true) return error.SkipZigTest;
    //
    // Run this test, in terminal start tcp listener on port 9999:
    // $ nc -l -p 9999
    // or in one liner
    // $ nc -l -p 9999 &;  zig test src/tcp.zig --test-filter Conn2
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
        tcp: Conn,
        send_vec: FixedSendVec(4) = .{},

        pub fn onError(_: *anyopaque, err: anyerror) void {
            std.debug.print("onError {}\n", .{err});
        }

        fn onConnect(context: *anyopaque) !void {
            const self: *Self = @ptrCast(@alignCast(context));
            std.debug.print("onConnect\n", .{});
            assert(self.send_vec.prep("pero "));
            assert(self.send_vec.prep("zdero "));
            assert(self.send_vec.prep("jozo "));
            assert(self.send_vec.prep("bozo\n"));
            assert(!self.send_vec.prep("nemere "));
            self.tcp.send(self.send_vec.get());
        }

        fn onDisconnect(context: *anyopaque, err: anyerror) void {
            const self: *Self = @ptrCast(@alignCast(context));
            std.debug.print("onDisconnect {} {}\n", .{ err, self.tcp.reconnect_count });
            if (self.tcp.reconnect_count == 10) self.tcp.close();
        }

        fn onRecv(_: *anyopaque, bytes: []u8) !void {
            std.debug.print("onRecv {s}\n", .{bytes});
        }

        fn onSend(_: *anyopaque, iov: []posix.iovec_const, err: ?anyerror) void {
            std.debug.print("onSend {?}\n", .{err});
            for (iov) |v| {
                std.debug.print("onSend v: {*} {}\n", .{ v.base, v.len });
            }
        }

        fn onClose(_: *anyopaque) void {
            std.debug.print("onClose\n", .{});
        }

        fn onRecvTimeout(context: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(context));
            std.debug.print("onRecvTimeout {}\n", .{self.tcp.recv_timeout_count});
            if (self.tcp.recv_timeout_count > 3)
                self.tcp.reconnect();
        }
    };

    var handler: Handler = .{ .tcp = undefined };
    handler.tcp = Conn.init(&loop, &handler, .{
        .onRecv = Handler.onRecv,
        .onSend = Handler.onSend,
        .onClose = Handler.onClose,
        .onConnect = Handler.onConnect,
        .onDisconnect = Handler.onDisconnect,
        .onError = Handler.onError,
        .onRecvTimeout = Handler.onRecvTimeout,
    }, .{
        .reconnect = .{ .enabled = true },
        .recv_idle_timeout = 1_000,
    });
    const addr = net.Address.initIp4([4]u8{ 127, 0, 0, 1 }, 9999);
    handler.tcp.connect(addr);

    while (handler.tcp.state != .closed) {
        try loop.tick();
    }
}

fn bufFromVec(vec: posix.iovec_const) []const u8 {
    var buf: []const u8 = undefined;
    buf.ptr = vec.base;
    buf.len = vec.len;
    return buf;
}

fn vecFromBuf(buf: []const u8) posix.iovec_const {
    return .{ .base = buf.ptr, .len = buf.len };
}

test "BufferedConn" {
    // jsif (true) return error.SkipZigTest;
    //
    // $ nc -l -p 9999 &;  zig test src/tcp.zig --test-filter Buffered

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
        tcp: BufferedConn,
        send_vec: FixedSendVec(4) = .{},

        pub fn onError(_: *anyopaque, err: anyerror) void {
            std.debug.print("onError {}\n", .{err});
        }

        pub fn onConnect(_: *anyopaque) !void {
            std.debug.print("onConnect\n", .{});
        }

        pub fn onSend(_: *anyopaque, buf: []const u8) void {
            std.debug.print("onSend v: {*} {} '{s}'\n", .{ buf.ptr, buf.len, buf });
        }

        pub fn onDisconnect(context: *anyopaque, err: anyerror) void {
            const self: *Self = @ptrCast(@alignCast(context));
            std.debug.print("onDisconnect {} {}\n", .{ err, self.tcp.conn.reconnect_count });
            if (self.tcp.conn.reconnect_count == 10) self.tcp.close();
        }

        pub fn onRecv(_: *anyopaque, bytes: []const u8) anyerror!usize {
            std.debug.print("onRecv {s}\n", .{bytes});
            return bytes.len;
        }

        pub fn onClose(_: *anyopaque) void {
            std.debug.print("onClose\n", .{});
        }

        pub fn onRecvTimeout(context: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(context));
            std.debug.print("onRecvTimeout {}\n", .{self.tcp.conn.recv_timeout_count});
            if (self.tcp.conn.recv_timeout_count > 3)
                self.tcp.conn.reconnect();
        }
    };

    const addr = net.Address.initIp4([4]u8{ 127, 0, 0, 1 }, 9999);

    var handler: Handler = .{ .tcp = undefined };
    handler.tcp.init(
        testing.allocator,
        &loop,
        &handler,
        .{
            .onRecv = Handler.onRecv,
            .onSend = Handler.onSend,
            .onClose = Handler.onClose,
            .onConnect = Handler.onConnect,
            .onDisconnect = Handler.onDisconnect,
            .onError = Handler.onError,
            .onRecvTimeout = Handler.onRecvTimeout,
        },
        .{
            .reconnect = .{ .enabled = true },
            .recv_idle_timeout = 1_000,
        },
    );
    defer handler.tcp.deinit();
    handler.tcp.connect(addr);

    try handler.tcp.send("pero ");
    try handler.tcp.send("zdero ");
    try handler.tcp.sendv(&[_][]const u8{ "jozo ", "bozo", "\n" });

    while (handler.tcp.conn.state != .closed) {
        try loop.tick();
    }

    //_ = try loop.run();
}

// iovlen in msghdr is limited by IOV_MAX in <limits.h>. On modern Linux
// systems, the limit is 1024. Each message has header and body: 2 iovecs that
// limits number of messages in a batch to 512.
// ref: https://man7.org/linux/man-pages/man2/readv.2.html
const max_iov = 1024;
