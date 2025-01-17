const std = @import("std");
const assert = std.debug.assert;
const net = std.net;
const mem = std.mem;
const posix = std.posix;
const io = @import("root.zig");
const tls = @import("tls");
const RecvBuf = @import("tcp.zig").RecvBuf;

pub fn Client(comptime Handler: type) type {
    return struct {
        const Self = @This();
        const Tcp = io.tcp.Client(Self);
        const Lib = tls.asyn.Client(Self);

        handler: *Handler,
        tcp_cli: Tcp,
        tls_lib: Lib,
        recv_buf: RecvBuf,

        pub fn init(
            self: *Self,
            allocator: mem.Allocator,
            io_loop: *io.Loop,
            handler: *Handler,
            address: net.Address,
            config: tls.config.Client,
        ) !void {
            self.* = .{
                .handler = handler,
                .tcp_cli = Tcp.init(allocator, io_loop, self, address),
                .tls_lib = try Lib.init(allocator, self, config),
                .recv_buf = RecvBuf.init(allocator),
            };
        }

        pub fn connect(self: *Self) void {
            self.tcp_cli.connect();
        }

        pub fn deinit(self: *Self) void {
            self.tcp_cli.deinit();
            self.tls_lib.deinit();
            self.recv_buf.free();
        }

        fn closeErr(self: *Self, err: anyerror) void {
            self.handler.onError(err);
            self.tcp_cli.close();
        }

        // ----------------- child api

        pub fn send(self: *Self, cleartext: []const u8) !void {
            self.tls_lib.send(cleartext) catch |err| self.closeErr(err);
        }

        pub fn sendZc(self: *Self, cleartext: []const u8) !void {
            try self.send(cleartext);
            self.handler.onSend(cleartext);
        }

        pub fn close(self: *Self) void {
            self.tcp_cli.close();
        }

        /// tcp is connected start tls handshake
        pub fn onConnect(self: *Self) void {
            self.tls_lib.onConnect() catch |err| self.closeErr(err);
        }

        /// Ciphertext bytes received from tcp, pass it to tls.
        /// Tls will decrypt it and call onRecvCleartext.
        pub fn onRecv(self: *Self, ciphertext: []u8) usize {
            return self.tls_lib.onRecv(ciphertext) catch |err| {
                self.closeErr(err);
                return 0;
            };
        }

        /// tcp connection is closed.
        pub fn onClose(self: *Self) void {
            self.handler.onClose();
        }

        /// Ciphertext is copied to the kernel tcp buffers.
        /// Safe to release it now.
        pub fn onSend(self: *Self, ciphertext: []const u8) void {
            self.tls_lib.onSend(ciphertext);
        }

        // ----------------- tls lib callbacks

        /// tls handshake finished
        pub fn onHandshake(self: *Self) void {
            self.handler.onConnect();
        }

        /// decrypted cleartext received from tcp
        pub fn onRecvCleartext(self: *Self, cleartext: []u8) !void {
            const buf = try self.recv_buf.append(cleartext);
            errdefer self.recv_buf.remove(cleartext.len) catch |err| {
                self.handler.onError(err);
                self.close();
            };
            const n = self.handler.onRecv(buf);
            self.recv_buf.set(buf[n..]) catch |err| {
                self.handler.onError(err);
                self.close();
            };
        }

        /// tls sends ciphertext to tcp
        pub fn sendCiphertext(self: *Self, ciphertext: []const u8) !void {
            try self.tcp_cli.sendZc(ciphertext);
        }

        pub fn onError(self: *Self, err: anyerror) void {
            self.handler.onError(err);
        }
    };
}

pub fn Conn(comptime Handler: type) type {
    return struct {
        const Self = @This();

        const TcpConn = io.tcp.Conn(Self, Self);

        handler: *Handler,
        tcp_conn: TcpConn,
        tls_lib: tls.asyn.Conn(Self),
        recv_buf: RecvBuf,
        err: ?anyerror = null,

        pub fn init(
            self: *Self,
            allocator: mem.Allocator,
            io_loop: *io.Loop,
            handler: *Handler,
            socket: posix.socket_t,
            opt: tls.config.Server,
        ) !void {
            self.* = .{
                .tcp_conn = TcpConn.init(allocator, io_loop, self),
                .handler = handler,
                .tls_lib = try tls.asyn.Conn(Self).init(allocator, self, opt),
                .recv_buf = RecvBuf.init(allocator),
            };
            self.tcp_conn.onConnect(socket);
        }

        pub fn deinit(self: *Self) void {
            self.tls_lib.deinit();
            self.tcp_conn.deinit();
            self.recv_buf.free();
        }

        fn closeErr(self: *Self, err: anyerror) void {
            self.handler.onError(err);
            self.tcp_conn.close();
        }

        // ----------------- child api

        pub fn send(self: *Self, cleartext: []const u8) !void {
            self.tls_lib.send(cleartext) catch |err| self.closeErr(err);
        }

        pub fn close(self: *Self) void {
            self.tcp_conn.close();
        }

        // ----------------- tcp callbacks

        /// Ciphertext bytes received from tcp, pass it to tls.
        /// Tls will decrypt it and call onRecvCleartext.
        pub fn onRecv(self: *Self, ciphertext: []u8) usize {
            return self.tls_lib.onRecv(ciphertext) catch |err| {
                self.closeErr(err);
                return 0;
            };
        }

        /// Tcp connection is closed.
        pub fn onClose(self: *Self) void {
            self.handler.onClose();
        }

        /// Ciphertext is copied to the kernel tcp buffers.
        /// Safe to release it now.
        pub fn onSend(self: *Self, ciphertext: []const u8) void {
            self.tls_lib.onSend(ciphertext);
        }

        // ----------------- tls lib callbacks

        /// tls handshake finished
        pub fn onHandshake(self: *Self) void {
            self.handler.onConnect() catch |err| self.closeErr(err);
        }

        /// decrypted cleartext received from tcp
        pub fn onRecvCleartext(self: *Self, cleartext: []u8) !void {
            const buf = try self.recv_buf.append(cleartext);
            errdefer self.recv_buf.remove(cleartext.len) catch |err| {
                if (self.err == null) self.err = err;
                self.close();
            };
            const n = try self.handler.onRecv(buf);
            self.recv_buf.set(buf[n..]) catch |err| {
                if (self.err == null) self.err = err;
                self.close();
            };
        }

        /// tls sends ciphertext to tcp
        pub fn sendCiphertext(self: *Self, ciphertext: []const u8) !void {
            try self.tcp_conn.sendZc(ciphertext);
        }
    };
}
