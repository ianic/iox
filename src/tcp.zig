const std = @import("std");
const net = std.net;
const mem = std.mem;
const assert = std.debug.assert;
const posix = std.posix;
const io = @import("io.zig");

const log = std.log.scoped(.io_tcp);

// iovlen in msghdr is limited by IOV_MAX in <limits.h>. On modern Linux
// systems, the limit is 1024. Each message has header and body: 2 iovecs that
// limits number of messages in a batch to 512.
// ref: https://man7.org/linux/man-pages/man2/readv.2.html
const max_iov = 1024;

/// Upstream has to implement callback methods:
///
/// onRecv([]u8) usize      - called with received data,
///                           returns number of consumed bytes,
///                           non consumed part will be preserved for following calls
/// onSend([]const u8)      - after successful send operation with buffer provided to send
///                           buffer lifetime has to be until onSend is called
/// onClose                 - after tcp connection is closed
/// onError(anyerror)       - for error reporting
/// onConnect()             - for client to server connections
///
pub fn ConnT(comptime Handler: type, comptime Parent: type) type {
    return struct {
        const Self = @This();

        allocator: mem.Allocator,
        io_loop: *io.Loop,
        handler: *Handler,
        parent: ?*Parent = null,
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
            connected,
            closing,
        };

        pub fn init(allocator: mem.Allocator, io_loop: *io.Loop, handler: *Handler) Self {
            return .{
                .allocator = allocator,
                .io_loop = io_loop,
                .handler = handler,
                .socket = 0,
                .state = .closed,
                .send_list = std.ArrayList(posix.iovec_const).init(allocator),
                .recv_buf = RecvBuf.init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.send_iov);
            self.send_list.deinit();
            self.recv_buf.free();
            self.* = undefined;
        }

        /// Set connected tcp socket.
        pub fn onConnect(self: *Self, socket: posix.socket_t) void {
            self.socket = socket;
            self.state = .connected;
            // start multishot receive
            self.recv_op = io.Op.recv(self.socket, self, onRecv, onRecvFail);
            self.io_loop.submit(&self.recv_op);
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
            const buf = try self.recv_buf.append(bytes);
            const n = self.handler.onRecv(buf);
            self.recv_buf.set(buf[n..]) catch |err| {
                self.handler.onError(err);
                self.close();
            };

            if (!self.recv_op.hasMore() and self.state == .connected)
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

            { // release pending send buffers
                self.sendCompleted();
                for (self.send_list.items) |vec| {
                    var buf: []const u8 = undefined;
                    buf.ptr = vec.base;
                    buf.len = vec.len;
                    self.handler.onSend(buf);
                }
                self.send_list.clearAndFree();
            }

            // TODO rethink this
            const self_parent = self.parent;
            self.handler.onClose();
            if (self_parent) |parent|
                parent.destroy(self);
        }
    };
}

pub fn Client(comptime Handler: type) type {
    return struct {
        const Self = @This();
        const Conn = ConnT(Handler, Self);

        io_loop: *io.Loop,
        handler: *Handler,
        address: std.net.Address,
        conn: Conn,

        connect_op: io.Op = .{},
        close_op: io.Op = .{},

        pub fn init(
            allocator: mem.Allocator,
            io_loop: *io.Loop,
            handler: *Handler,
            address: net.Address,
        ) Self {
            return .{
                .io_loop = io_loop,
                .handler = handler,
                .address = address,
                .conn = Conn.init(allocator, io_loop, handler),
            };
        }

        pub fn deinit(self: *Self) void {
            self.conn.deinit();
            self.* = undefined;
        }

        /// Start connect operation. `onConnect` callback will be fired when
        /// finished.
        pub fn connect(self: *Self) void {
            assert(self.conn.state == .closed);
            assert(!self.connect_op.active() and !self.close_op.active());

            self.connect_op = io.Op.connect(
                .{ .addr = &self.address },
                self,
                onConnect,
                onConnectFail,
            );
            self.io_loop.submit(&self.connect_op);
        }

        fn onConnect(self: *Self, socket: posix.socket_t) io.Error!void {
            self.conn.onConnect(socket);
            self.handler.onConnect();
        }

        fn onConnectFail(self: *Self, mybe_err: ?anyerror) void {
            if (mybe_err) |err| self.handler.onError(err);
            self.close();
        }

        pub fn sendZc(self: *Self, buf: []const u8) io.Error!void {
            try self.conn.sendZc(buf);
        }

        pub fn sendVZc(self: *Self, vec: []const []const u8) io.Error!void {
            try self.conn.sendVZc(vec);
        }

        fn onCancel(self: *Self, _: ?anyerror) void {
            self.close();
        }

        pub fn close(self: *Self) void {
            if (self.conn.state != .closed)
                return self.conn.close();

            if (self.connect_op.active() and !self.close_op.active()) {
                self.close_op = io.Op.cancel(&self.connect_op, self, onCancel);
                return self.io_loop.submit(&self.close_op);
            }

            if (self.connect_op.active() or
                self.close_op.active())
                return;

            self.handler.onClose();
        }

        fn destroy(_: *Self, _: *Conn) void {}
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

/// Factory will be called to finish initialization.
pub fn Listener(comptime Factory: type, comptime Handler: type) type {
    return struct {
        const Self = @This();

        pub const Conn = ConnT(Handler, Self);

        allocator: mem.Allocator,
        socket: posix.socket_t = 0,
        io_loop: *io.Loop,
        accept_op: io.Op = .{},
        close_op: io.Op = .{},
        conns: std.AutoHashMap(*Conn, *Handler),
        factory: *Factory,
        metric: struct {
            // Total number of
            accept: usize = 0, // accepted connections
            close: usize = 0, // closed (completed) connections
        } = .{},

        pub fn init(
            allocator: mem.Allocator,
            io_loop: *io.Loop,
            factory: *Factory,
        ) Self {
            return .{
                .allocator = allocator,
                .io_loop = io_loop,
                .factory = factory,
                .conns = std.AutoHashMap(*Conn, *Handler).init(allocator),
            };
        }

        /// Start multishot accept
        pub fn bind(self: *Self, addr: net.Address) !void {
            self.socket = try listenSocket(addr);
            self.accept_op = io.Op.accept(self.socket, self, onAccept, onAcceptFail);
            self.io_loop.submit(&self.accept_op);
        }

        pub fn deinit(self: *Self) void {
            // destroy all connections
            var iter = self.conns.iterator();
            while (iter.next()) |kv| {
                const tcp_conn = kv.key_ptr.*;
                const conn = kv.value_ptr.*;
                tcp_conn.deinit();
                conn.deinit();
                self.allocator.destroy(conn);
                self.allocator.destroy(tcp_conn);
            }
            self.conns.deinit();
        }

        fn onAccept(self: *Self, socket: posix.socket_t, addr: net.Address) io.Error!void {
            // Create new collection
            try self.conns.ensureUnusedCapacity(1);
            const handler = try self.allocator.create(Handler);
            errdefer self.allocator.destroy(handler);
            const tcp_conn = try self.allocator.create(Conn);
            errdefer self.allocator.destroy(tcp_conn);
            tcp_conn.* = Conn.init(self.allocator, self.io_loop, handler);
            tcp_conn.parent = self;
            tcp_conn.onConnect(socket);
            // Pass new connection to the child to finish initialization
            self.factory.onAccept(handler, tcp_conn, socket, addr);

            // Add to list of live connections
            self.conns.putAssumeCapacityNoClobber(tcp_conn, handler);
            self.metric.accept +%= 1;
        }

        fn onAcceptFail(self: *Self, err: anyerror) io.Error!void {
            self.factory.onError(err);
            self.io_loop.submit(&self.accept_op); // restart operation
        }

        /// Destroy closed connection
        fn destroy(self: *Self, tcp_conn: *Conn) void {
            const kv = (self.conns.fetchRemove(tcp_conn)) orelse unreachable;
            const conn = kv.value;
            tcp_conn.deinit();
            conn.deinit();
            self.allocator.destroy(conn);
            self.allocator.destroy(tcp_conn);
            self.metric.close +%= 1;
        }

        fn onCancel(self: *Self, _: ?anyerror) void {
            self.close();
        }

        /// Stop listening and shutdown listening socket
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

pub fn listenSocket(addr: net.Address) !posix.socket_t {
    return (try addr.listen(.{ .reuse_address = true })).stream.handle;
}

pub fn SimpleListener(comptime Factory: type) type {
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
            self.factory.onAccept(socket, addr);
        }

        fn onAcceptFail(self: *Self, err: anyerror) io.Error!void {
            self.factory.onError(err);
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
