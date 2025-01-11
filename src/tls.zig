const std = @import("std");
const assert = std.debug.assert;
const net = std.net;
const mem = std.mem;
const posix = std.posix;
const io = @import("root.zig");
const tls = @import("tls");

const log = std.log.scoped(.tls);

const Side = enum {
    client,
    server,
};

pub fn Client(comptime ChildType: type) type {
    return struct {
        const Self = @This();

        child: ChildType,
        tcp_cli: io.tcp.Client(*Self),
        tls_lib: tls.asyn.Client(*Self),
        err: ?anyerror = null,

        pub fn init(
            self: *Self,
            allocator: mem.Allocator,
            io_loop: *io.Loop,
            child: ChildType,
            address: net.Address,
            opt: tls.ClientOptions,
        ) !void {
            self.* = .{
                .child = child,
                .tcp_cli = io.tcp.Client(*Self).init(allocator, io_loop, self, address),
                .tls_lib = try tls.asyn.Client(*Self).init(allocator, self, opt),
            };
            self.tcp_cli.connect();
        }

        pub fn deinit(self: *Self) void {
            self.tcp_cli.deinit();
            self.tls_lib.deinit();
        }

        fn closeErr(self: *Self, err: anyerror) void {
            if (self.err == null) self.err = err;
            self.tcp_cli.close();
        }

        // ----------------- child api

        pub fn send(self: *Self, cleartext: []const u8) !void {
            self.tls_lib.send(cleartext) catch |err| self.closeErr(err);
        }

        pub fn close(self: *Self) void {
            self.tcp_cli.close();
        }

        // ----------------- tcp callbacks

        /// tcp is connected start tls handshake
        pub fn onConnect(self: *Self) !void {
            self.tls_lib.startHandshake() catch |err| self.closeErr(err);
        }

        /// Ciphertext bytes received from tcp, pass it to tls.
        /// Tls will decrypt it and call onRecvCleartext.
        pub fn onRecv(self: *Self, ciphertext: []u8) !usize {
            return self.tls_lib.onRecv(ciphertext) catch |err| {
                self.closeErr(err);
                return 0;
            };
        }

        /// tcp connection is closed.
        pub fn onClose(self: *Self) void {
            self.child.onClose();
        }

        /// Ciphertext is copied to the kernel tcp buffers.
        /// Safe to release it now.
        pub fn onSend(self: *Self, ciphertext: []const u8) void {
            self.tls_lib.onSend(ciphertext);
        }

        // ----------------- tls lib callbacks

        /// tls handshake finished
        pub fn onHandshake(self: *Self) void {
            self.child.onConnect() catch |err| self.closeErr(err);
        }

        /// decrypted cleartext received from tcp
        pub fn onRecvCleartext(self: *Self, cleartext: []const u8) !void {
            try self.child.onRecv(cleartext);
        }

        /// tls sends ciphertext to tcp
        pub fn sendCiphertext(self: *Self, ciphertext: []const u8) !void {
            try self.tcp_cli.send(ciphertext);
        }
    };
}

pub fn Conn(comptime ChildType: type) type {
    return struct {
        const Self = @This();

        child: ChildType,
        tcp_conn: io.tcp.Conn(*Self),
        tls_lib: tls.asyn.Conn(*Self),
        err: ?anyerror = null,

        pub fn init(
            self: *Self,
            allocator: mem.Allocator,
            io_loop: *io.Loop,
            child: ChildType,
            socket: posix.socket_t,
            opt: tls.ServerOptions,
        ) !void {
            self.* = .{
                .tcp_conn = io.tcp.Conn(*Self).init(allocator, io_loop, self),
                .child = child,
                .tls_lib = try tls.asyn.Conn(*Self).init(allocator, self, opt),
            };
            self.tcp_conn.onConnect(socket);
        }

        pub fn deinit(self: *Self) void {
            self.tls_lib.deinit();
            self.tcp_conn.deinit();
        }

        fn closeErr(self: *Self, err: anyerror) void {
            if (self.err == null) self.err = err;
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
        pub fn onRecv(self: *Self, ciphertext: []u8) !usize {
            return self.tls_lib.onRecv(ciphertext) catch |err| {
                self.closeErr(err);
                return 0;
            };
        }

        /// Tcp connection is closed.
        pub fn onClose(self: *Self) void {
            self.child.onClose();
        }

        /// Ciphertext is copied to the kernel tcp buffers.
        /// Safe to release it now.
        pub fn onSend(self: *Self, ciphertext: []const u8) void {
            self.tls_lib.onSend(ciphertext);
        }

        // ----------------- tls callbacks

        /// tls handshake finished
        pub fn onHandshake(self: *Self) void {
            self.child.onConnect() catch |err| self.closeErr(err);
        }

        /// decrypted cleartext received from tcp
        pub fn onRecvCleartext(self: *Self, cleartext: []const u8) !void {
            try self.child.onRecv(cleartext);
        }

        /// tls sends ciphertext to tcp
        pub fn sendCiphertext(self: *Self, ciphertext: []const u8) !void {
            try self.tcp_conn.send(ciphertext);
        }
    };
}
