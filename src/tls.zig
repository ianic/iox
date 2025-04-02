const std = @import("std");
const net = std.net;
const mem = std.mem;
const posix = std.posix;
const assert = std.debug.assert;
const tls = @import("tls");
const io = @import("root.zig");
const BufferedRecv = @import("tcp.zig").BufferedRecv;

pub fn Client() type {
    return Conn(.client);
}

pub fn Conn(comptime handshake_kind: io.HandshakeKind) type {
    const Config = switch (handshake_kind) {
        .client => tls.config.Client,
        .server => tls.config.Server,
    };
    const HandshakeType = switch (handshake_kind) {
        .client => tls.nonblock.Client,
        .server => tls.nonblock.Server,
    };
    return struct {
        const ConnT = @This();

        /// Handler callbacks
        /// Error returned in onRecv/onConnect callbacks will close connection.
        pub const VTable = struct {
            /// data is received
            onRecv: *const fn (*anyopaque, []u8) anyerror!usize,
            /// send is done, buffers can be released now
            onSend: *const fn (*anyopaque, []const u8) void,
            /// connection closed, cleanup done, safe to deinit
            onClose: *const fn (*anyopaque) void,

            /// Optional callbacks
            /// tls connection is established
            onConnect: ?*const fn (*anyopaque) anyerror!void = null,
            /// unexpected error
            onError: ?*const fn (*anyopaque, anyerror) void = null,
        };

        handler: *anyopaque,
        vtable: VTable,

        allocator: mem.Allocator,
        buf_recv: BufferedRecv,
        tcp: io.tcp.BufferedConn,

        handshake: ?*HandshakeType = null,
        connection: ?tls.nonblock.Connection = null,
        config: Config,

        pub fn init(
            self: *ConnT,
            allocator: mem.Allocator,
            io_loop: *io.Loop,
            handler: *anyopaque,
            vtable: VTable,
            config: Config,
        ) io.Error!void {
            self.* = .{
                .handler = handler,
                .vtable = vtable,
                .allocator = allocator,
                .buf_recv = .{},
                .tcp = undefined,
                .config = config,
            };
            self.tcp.init(allocator, io_loop, self, .{
                .onConnect = onTcpConnect,
                .onRecv = onHandshakeRecv,
                .onSend = onTcpSend,
                .onClose = onTcpClose,
                .onError = onTcpError,
            }, .{});
        }

        pub fn deinit(self: *ConnT) void {
            if (self.handshake) |handshake| self.allocator.destroy(handshake);
            self.buf_recv.deinit(self.allocator);
            self.tcp.deinit();
            self.* = undefined;
        }

        fn handshakeRun(self: *ConnT, recv_buf: []const u8) !usize {
            var handshake = self.handshake orelse unreachable;

            var send_buf: [tls.max_ciphertext_record_len]u8 = undefined;
            const res = try handshake.run(recv_buf, &send_buf);
            if (res.send.len > 0) {
                const buf = try self.allocator.dupe(u8, res.send);
                try self.tcp.send(buf);
            }

            if (handshake.done()) {
                self.connection = tls.nonblock.Connection.init(handshake.inner.cipher);
                self.tcp.vtable.onRecv = onTcpRecv; // replace callback
                self.allocator.destroy(handshake);
                self.handshake = null;
                // call handler onConnect
                if (self.vtable.onConnect) |cb| cb(self.handler) catch |err| {
                    if (self.vtable.onError) |cbe| cbe(self.handler, err);
                    self.tcp.close();
                };
            }
            return res.recv_pos;
        }

        // *** tcp callbacks

        /// Tcp receive callback during handshake, after handshake onTcpRecv will be used.
        fn onHandshakeRecv(ptr: *anyopaque, ciphertext: []u8) !usize {
            const self: *ConnT = @ptrCast(@alignCast(ptr));
            return try self.handshakeRun(ciphertext);
        }

        /// Notification that tcp is connected: start tls handshake
        fn onTcpConnect(ptr: *anyopaque) !void {
            const self: *ConnT = @ptrCast(@alignCast(ptr));
            assert(self.handshake == null);
            // init self.handshake
            const handshake = try self.allocator.create(HandshakeType);
            handshake.* = HandshakeType.init(self.config);
            self.handshake = handshake;
            self.tcp.vtable.onRecv = onHandshakeRecv;
            // send client hello
            if (handshake_kind == .client) _ = try self.handshakeRun(&.{});
        }

        /// Ciphertext bytes received from tcp, pass it to the tls lib
        fn onTcpRecv(ptr: *anyopaque, ciphertext: []u8) !usize {
            const self: *ConnT = @ptrCast(@alignCast(ptr));
            var tls_conn = &(self.connection orelse unreachable);
            // decrypt
            const res = try tls_conn.decrypt(ciphertext, ciphertext);
            if (res.cleartext.len > 0) {
                // send cleartext to handler, preserve unprocessed in buf_recv
                try self.buf_recv.onRecv(self.allocator, res.cleartext, self.handler, self.vtable.onRecv);
            }
            if (res.closed) return error.EndOfStream;
            return res.ciphertext_pos;
        }

        /// Ciphertext is copied to the kernel tcp buffers.
        /// Safe to release it now.
        fn onTcpSend(ptr: *anyopaque, ciphertext: []const u8) void {
            const self: *ConnT = @ptrCast(@alignCast(ptr));
            self.allocator.free(ciphertext);
        }

        /// Notification that tcp connection is closed.
        fn onTcpClose(ptr: *anyopaque) void {
            const self: *ConnT = @ptrCast(@alignCast(ptr));
            self.vtable.onClose(self.handler);
        }

        /// Unexpected error in tcp
        fn onTcpError(ptr: *anyopaque, err: anyerror) void {
            const self: *ConnT = @ptrCast(@alignCast(ptr));
            if (self.vtable.onError) |cb| cb(self.handler, err);
        }

        // *** public interface

        pub fn connect(self: *ConnT, addr: net.Address) void {
            self.tcp.connect(addr);
        }

        pub fn accept(self: *ConnT, socket: posix.socket_t) void {
            self.tcp.accept(socket);
        }

        pub fn send(self: *ConnT, cleartext: []const u8) !void {
            var tls_conn = &(self.connection orelse return error.InvalidState);
            if (cleartext.len == 0) return;

            // Allocate ciphertext buffer
            const ciphertext = try self.allocator.alloc(u8, tls_conn.encryptedLength(cleartext.len));
            errdefer self.allocator.free(ciphertext);
            // Fill ciphertext with encrypted tls records
            const res = try tls_conn.encrypt(cleartext, ciphertext);
            assert(res.cleartext_pos == cleartext.len);
            assert(res.unused_cleartext.len == 0);
            assert(res.ciphertext.len == ciphertext.len);
            try self.tcp.send(ciphertext);

            // Cleartext data is copied in encrypt into ciphertext, cleartext is free here.
            // Holding same interface as tcp, requiring handler to have onSend.
            self.vtable.onSend(self.handler, cleartext);
        }

        pub fn close(self: *ConnT) void {
            self.tcp.close();
        }
    };
}
