const std = @import("std");
const net = std.net;
const mem = std.mem;
const posix = std.posix;

const tls = @import("tls");

const io = @import("root.zig");
const RecvBuf = @import("tcp.zig").RecvBuf;
const BufferedRecv = @import("tcp.zig").BufferedRecv;

pub fn Client(comptime Handler: type) type {
    return Conn(Handler, .client);
}

pub fn Conn(comptime Handler: type, comptime handshake: io.HandshakeKind) type {
    const Config = switch (handshake) {
        .client => tls.config.Client,
        .server => tls.config.Server,
    };
    return struct {
        const ConnT = @This();
        const Lib = switch (handshake) {
            .client => tls.asyn.Client(LibFacade),
            .server => tls.asyn.Server(LibFacade),
        };

        handler: *Handler,
        allocator: mem.Allocator,
        buf_recv: BufferedRecv(Handler),
        tcp: io.tcp.BufferedConn(TcpFacade),
        lib: Lib,
        tcp_facade: TcpFacade,
        lib_facade: LibFacade,

        /// Tcp callbacks hidden from ConnT public interface into this inner struct.
        const TcpFacade = struct {
            inline fn parent(tf: *TcpFacade) *ConnT {
                return @alignCast(@fieldParentPtr("tcp_facade", tf));
            }

            /// Notification that tcp is connected: start tls handshake
            pub fn onConnect(tf: *TcpFacade) !void {
                try tf.parent().lib.onConnect();
            }

            /// Ciphertext bytes received from tcp, pass it to the tls lib
            pub fn onRecv(tf: *TcpFacade, ciphertext: []u8) !usize {
                return try tf.parent().lib.onRecv(ciphertext);
            }

            /// Notification that tcp connection is closed.
            pub fn onClose(tf: *TcpFacade) void {
                tf.parent().handler.onClose();
            }

            /// Ciphertext is copied to the kernel tcp buffers.
            /// Safe to release it now.
            pub fn onSend(tf: *TcpFacade, ciphertext: []const u8) void {
                tf.parent().lib.onSend(ciphertext);
            }

            pub fn onError(tf: *TcpFacade, err: anyerror) void {
                if (@hasDecl(Handler, "onError")) tf.parent().handler.onError(err);
            }
        };

        /// Tls library callbacks hidden from ConnT public interface.
        const LibFacade = struct {
            inline fn parent(lf: *LibFacade) *ConnT {
                return @alignCast(@fieldParentPtr("lib_facade", lf));
            }

            /// Notification that tls handshake has finished.
            pub fn onConnect(lf: *LibFacade) void {
                if (@hasDecl(Handler, "onConnect")) {
                    const conn = lf.parent();
                    conn.handler.onConnect() catch |err| {
                        if (@hasDecl(Handler, "onError")) conn.handler.onError(err);
                        conn.tcp.close();
                    };
                }
            }

            /// Passing decrypted cleartext to the handler.
            /// Making call to handler.onRecv buffered.
            pub fn onRecv(lf: *LibFacade, cleartext: []u8) !void {
                const conn = lf.parent();
                try conn.buf_recv.onRecv(conn.allocator, cleartext, conn.handler);
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
            handler: *Handler,
            config: Config,
        ) io.Error!void {
            self.* = .{
                .allocator = allocator,
                .buf_recv = .{},
                .handler = handler,
                .tcp_facade = .{},
                .lib_facade = .{},
                .tcp = undefined,
                .lib = Lib.init(allocator, &self.lib_facade, config) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => unreachable,
                },
            };
            self.tcp.init(allocator, io_loop, &self.tcp_facade, .{});
        }

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
        }

        pub fn send(self: *ConnT, cleartext: []const u8) !void {
            try self.lib.send(cleartext);
            // lib.send is copying data into ciphertext, cleartext is free here.
            // Holding same interface as tcp, requiring handler to have onSend.
            self.handler.onSend(cleartext);
        }

        pub fn close(self: *ConnT) void {
            self.tcp.close();
        }
    };
}
