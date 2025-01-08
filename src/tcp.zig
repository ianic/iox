const std = @import("std");
const net = std.net;
const mem = std.mem;
const assert = std.debug.assert;
const posix = std.posix;
const io = @import("io.zig");

const log = std.log.scoped(.io_tcp);

/// ClientType has to implement callback methods
///
/// onConnect()*            - after successful connect operation
///                           * optional, clients which have socket (from listen)
///                             should start with connected method
/// onRecv([]u8) !usize     - called with received data,
///                           returns number of consumed bytes,
///                           non consumed part will be preserved for following calls
/// onSend([]const u8)      - after successful send operation with buffer provided to send
///                           buffer lifetime has to be until onSend is called
/// onClose                 - after tcp connection is closed
///
pub fn Conn(comptime ClientType: type) type {
    return struct {
        const Self = @This();

        allocator: mem.Allocator,
        io_loop: *io.Loop,
        client: ClientType,
        address: std.net.Address = undefined,
        socket: posix.socket_t = 0,
        state: State = .closed,

        connect_op: io.Op = .{},
        close_op: io.Op = .{},
        recv_op: io.Op = .{},
        recv_buf: RecvBuf,
        send_op: io.Op = .{},
        send_list: std.ArrayList(posix.iovec_const), // pending send buffers
        send_iov: []posix.iovec_const = &.{}, // because msghdr.iov is pointer
        send_msghdr: posix.msghdr_const = .{ .iov = undefined, .iovlen = 0, .name = null, .namelen = 0, .control = null, .controllen = 0, .flags = 0 },

        const State = enum {
            closed,
            connecting,
            connected,
            closing,
        };

        pub fn init(allocator: mem.Allocator, io_loop: *io.Loop, client: ClientType) Self {
            return .{
                .allocator = allocator,
                .io_loop = io_loop,
                .client = client,
                .send_list = std.ArrayList(posix.iovec_const).init(allocator),
                .recv_buf = RecvBuf.init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.send_iov);
            self.send_list.deinit();
            self.recv_buf.free();
        }

        /// Start connect operation. `onConnect` callback will be fired when
        /// finished.
        pub fn connect(self: *Self, address: net.Address) void {
            assert(self.state == .closed);
            assert(!self.connect_op.active() and !self.send_op.active() and !self.recv_op.active() and !self.close_op.active());
            assert(self.socket == 0);

            self.address = address;
            self.connect_op = io.Op.connect(
                .{ .addr = &self.address },
                self,
                onConnect,
                onConnectFail,
            );
            self.io_loop.submit(&self.connect_op);
            self.state = .connecting;
        }

        fn onConnect(self: *Self, socket: posix.socket_t) io.Error!void {
            // log.debug("{} connected socket {}", .{ self.address, socket });
            self.connected(socket, self.address);
            try self.client.onConnect();
        }

        fn onConnectFail(self: *Self, err: ?anyerror) void {
            if (err) |e| log.info("{} connect failed {}", .{ self.address, e });
            self.close();
        }

        /// Set connected tcp socket. After successful client connect operation
        /// or after server listener accepts client socket.
        pub fn connected(self: *Self, socket: posix.socket_t, address: net.Address) void {
            self.socket = socket;
            self.address = address;
            self.state = .connected;
            self.recv_op = io.Op.recv(self.socket, self, onRecv, onRecvFail);
            self.io_loop.submit(&self.recv_op);
        }

        /// Send `buf` to the tcp connection. It is client's responsibility to
        /// ensure lifetime of `buf` until `onSend(buf)` is called.
        pub fn send(self: *Self, buf: []const u8) io.Error!void {
            if (self.state == .closed)
                return self.client.onSend(buf);
            errdefer self.client.onSend(buf);

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
            try self.sendPending();
        }

        pub fn prepSend(self: *Self, buf: []const u8) io.Error!void {
            try self.send_list.append(.{ .base = buf.ptr, .len = buf.len });
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
        /// client that we are done with sending their buffers.
        fn sendCompleted(self: *Self) void {
            const iovlen: u32 = @intCast(self.send_msghdr.iovlen);
            self.send_msghdr.iovlen = 0;
            // Call client callback for each sent buffer
            for (self.send_iov[0..iovlen]) |vec| {
                var buf: []const u8 = undefined;
                buf.ptr = vec.base;
                buf.len = vec.len;
                self.client.onSend(buf);
            }
        }

        fn onSend(self: *Self) io.Error!void {
            // log.debug("{} onSend", .{self.address});
            self.sendCompleted();
            try self.sendPending();
        }

        fn onSendFail(self: *Self, err: anyerror) io.Error!void {
            switch (err) {
                error.BrokenPipe, error.ConnectionResetByPeer => {},
                else => log.err("{} send failed {}", .{ self.address, err }),
            }
            self.sendCompleted();
            self.close();
        }

        fn onRecv(self: *Self, bytes: []u8) io.Error!void {
            const buf = try self.recv_buf.append(bytes);
            errdefer self.recv_buf.remove(bytes.len) catch self.close();
            const n = try self.client.onRecv(buf);
            try self.recv_buf.set(buf[n..]);

            if (!self.recv_op.hasMore() and self.state == .connected)
                self.io_loop.submit(&self.recv_op);
        }

        fn onRecvFail(self: *Self, err: anyerror) io.Error!void {
            switch (err) {
                error.EndOfFile, error.ConnectionResetByPeer => {},
                else => log.err("{} recv failed {}", .{ self.address, err }),
            }
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
            if (self.recv_op.active() and !self.close_op.active()) {
                self.close_op = io.Op.cancel(&self.recv_op, self, onCancel);
                return self.io_loop.submit(&self.close_op);
            }

            if (self.connect_op.active() or
                self.recv_op.active() or
                self.send_op.active() or
                self.close_op.active())
                return;

            self.state = .closed;
            self.sendCompleted();
            // log.debug("{} closed", .{self.address});
            self.client.onClose();
        }
    };
}

// iovlen in msghdr is limited by IOV_MAX in <limits.h>. On modern Linux
// systems, the limit is 1024. Each message has header and body: 2 iovecs that
// limits number of messages in a batch to 512.
// ref: https://man7.org/linux/man-pages/man2/readv.2.html
const max_iov = 1024;

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

pub fn Listener(comptime ClientType: type, comptime ConnType: type) type {
    return struct {
        const Self = @This();

        allocator: mem.Allocator,
        socket: posix.socket_t,
        io_loop: *io.Loop,
        accept_op: io.Op = .{},
        close_op: io.Op = .{},
        conns: std.AutoHashMap(*ConnType, void),
        client: ClientType,
        metric: struct {
            // Total number of
            accept: usize = 0, // accepted connections
            close: usize = 0, // closed (completed) connections
        } = .{},

        pub fn init(
            self: *Self,
            allocator: mem.Allocator,
            io_loop: *io.Loop,
            socket: posix.socket_t,
            client: ClientType,
        ) void {
            self.* = .{
                .allocator = allocator,
                .io_loop = io_loop,
                .socket = socket,
                .conns = std.AutoHashMap(*ConnType, void).init(allocator),
                .client = client,
            };
            self.accept_op = io.Op.accept(socket, self, onAccept, onAcceptFail);
            self.io_loop.submit(&self.accept_op);
        }

        pub fn deinit(self: *Self) void {
            // destroy all connections
            var iter = self.conns.keyIterator();
            while (iter.next()) |e| {
                const conn = e.*;
                conn.deinit();
                self.allocator.destroy(conn);
            }
            self.conns.deinit();
        }

        fn onAccept(self: *Self, socket: posix.socket_t, addr: net.Address) io.Error!void {
            // Create new collection
            try self.conns.ensureUnusedCapacity(1);
            const conn = try self.allocator.create(ConnType);
            errdefer self.allocator.destroy(conn);
            // call client to init connection
            try self.client.onAccept(conn, socket, addr);
            // add to live connections list
            self.conns.putAssumeCapacityNoClobber(conn, {});
            self.metric.accept +%= 1;
        }

        fn onAcceptFail(self: *Self, err: anyerror) io.Error!void {
            log.err("accept failed {}", .{err});
            self.io_loop.submit(&self.accept_op); // restart operation
        }

        /// Destroy closed connection
        pub fn destroy(self: *Self, conn: *ConnType) void {
            assert(self.conns.remove(conn));
            self.allocator.destroy(conn);
            self.metric.close +%= 1;
        }

        fn onCancel(self: *Self, _: ?anyerror) void {
            self.close();
        }

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
            self.client.onClose();
        }
    };
}
