const std = @import("std");
const net = std.net;
const mem = std.mem;
const posix = std.posix;
const tls = @import("tls");
const io = @import("root.zig");
const BufferedRecv = @import("tcp.zig").BufferedRecv;

pub fn Client() type {
    return Conn(.client);
}

pub fn Conn(comptime handshake: io.HandshakeKind) type {
    const Config = switch (handshake) {
        .client => tls.config.Client,
        .server => tls.config.Server,
    };
    return struct {
        const ConnT = @This();
        const Lib = switch (handshake) {
            .client => tls.callback.Client(LibFacade),
            .server => tls.callback.Server(LibFacade),
        };

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
        lib: Lib,
        lib_facade: LibFacade,

        /// Tls library callbacks hidden from ConnT public interface.
        const LibFacade = struct {
            inline fn parent(lf: *LibFacade) *ConnT {
                return @alignCast(@fieldParentPtr("lib_facade", lf));
            }

            /// Notification that tls handshake has finished.
            pub fn onConnect(lf: *LibFacade) void {
                const conn = lf.parent();
                if (conn.vtable.onConnect) |cb| cb(conn.handler) catch |err| {
                    if (conn.vtable.onError) |cbe| cbe(conn.handler, err);
                    conn.tcp.close();
                };
            }

            /// Passing decrypted cleartext to the handler.
            /// Making call to handler.onRecv buffered.
            pub fn onRecv(lf: *LibFacade, cleartext: []u8) !void {
                const conn = lf.parent();
                try conn.buf_recv.onRecv(conn.allocator, cleartext, conn.handler, conn.vtable.onRecv);
            }

            /// tls lib sends ciphertext to the tcp connection.
            pub fn send(lf: *LibFacade, ciphertext: []const u8) !void {
                try lf.parent().tcp.send(ciphertext);
            }
        };

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
                .lib_facade = .{},
                .tcp = undefined,
                .lib = Lib.init(allocator, self.lib_facade, config) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => unreachable,
                },
            };
            self.tcp.init(allocator, io_loop, self, .{
                .onConnect = onTcpConnect,
                .onRecv = onTcpRecv,
                .onSend = onTcpSend,
                .onClose = onTcpClose,
                .onError = onTcpError,
            }, .{});
        }

        // *** tcp callbacks

        /// Notification that tcp is connected: start tls handshake
        fn onTcpConnect(ptr: *anyopaque) !void {
            const self: *ConnT = @ptrCast(@alignCast(ptr));
            try self.lib.onConnect();
        }

        /// Ciphertext bytes received from tcp, pass it to the tls lib
        fn onTcpRecv(ptr: *anyopaque, ciphertext: []u8) !usize {
            const self: *ConnT = @ptrCast(@alignCast(ptr));
            return try self.lib.onRecv(ciphertext);
        }

        /// Ciphertext is copied to the kernel tcp buffers.
        /// Safe to release it now.
        fn onTcpSend(ptr: *anyopaque, ciphertext: []const u8) void {
            const self: *ConnT = @ptrCast(@alignCast(ptr));
            self.lib.onSend(ciphertext);
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

        pub fn deinit(self: *ConnT) void {
            self.buf_recv.deinit(self.allocator);
            self.tcp.deinit();
            self.lib.deinit();
            self.* = undefined;
        }

        pub fn send(self: *ConnT, cleartext: []const u8) !void {
            try self.lib.send(cleartext);
            // lib.send is copying data into ciphertext, cleartext is free here.
            // Holding same interface as tcp, requiring handler to have onSend.
            self.vtable.onSend(self.handler, cleartext);
        }

        pub fn close(self: *ConnT) void {
            self.tcp.close();
        }
    };
}
