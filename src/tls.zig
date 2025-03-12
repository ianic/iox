const std = @import("std");
const net = std.net;
const mem = std.mem;
const posix = std.posix;

const tls = @import("tls");

const io = @import("root.zig");
const RecvBuf = @import("tcp.zig").RecvBuf;

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
        const Tcp = io.tcp.BufferedConn(TcpFacade);
        const Lib = switch (handshake) {
            .client => tls.asyn.Client(LibFacade),
            .server => tls.asyn.Server(LibFacade),
        };

        allocator: mem.Allocator,
        handler: *Handler,
        tcp: Tcp,
        lib: Lib,
        tcp_facade: TcpFacade,
        lib_facade: LibFacade,

        // Tcp callbacks hidden from ConnT public interface into inner struct
        const TcpFacade = struct {
            inline fn parent(tf: *TcpFacade) *ConnT {
                return @alignCast(@fieldParentPtr("tcp_facade", tf));
            }

            // tcp is connected start tls handshake
            pub fn onConnect(tf: *TcpFacade) !void {
                try tf.parent().lib.connect();
            }

            // Ciphertext bytes received from tcp, pass it to tls lib
            pub fn onRecv(tf: *TcpFacade, ciphertext: []u8) !usize {
                return try tf.parent().lib.recv(ciphertext);
            }

            // tcp connection is closed.
            pub fn onClose(tf: *TcpFacade) void {
                tf.parent().handler.onClose();
            }

            // Ciphertext is copied to the kernel tcp buffers.
            // Safe to release it now.
            pub fn onSend(tf: *TcpFacade, ciphertext: []const u8) void {
                tf.parent().lib.onSend(ciphertext);
            }

            pub fn onError(tf: *TcpFacade, err: anyerror) void {
                if (@hasDecl(Handler, "onError")) tf.parent().handler.onError(err);
            }
        };

        // Tls library callbacks hidden from ConnT public interface into
        const LibFacade = struct {
            recv_buf: RecvBuf = .empty,

            inline fn parent(lf: *LibFacade) *ConnT {
                return @alignCast(@fieldParentPtr("lib_facade", lf));
            }

            // tls handshake finished
            pub fn onConnect(lf: *LibFacade) void {
                if (@hasDecl(Handler, "onConnect")) {
                    const conn = lf.parent();
                    conn.handler.onConnect() catch |err| conn.closeErr(err);
                }
            }

            // decrypted cleartext from tls lib
            pub fn onRecv(lf: *LibFacade, cleartext: []u8) void {
                const conn = lf.parent();
                const buf = lf.recv_buf.append(conn.allocator, cleartext) catch |err| return conn.closeErr(err);
                const n = conn.handler.onRecv(buf) catch |err| return conn.closeErr(err);
                lf.recv_buf.set(conn.allocator, buf[n..]) catch |err| conn.closeErr(err);
            }

            // tls lib sends ciphertext
            pub fn sendZc(lf: *LibFacade, ciphertext: []const u8) !void {
                try lf.parent().tcp.sendZc(ciphertext);
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
            self.lib_facade.recv_buf.free(self.allocator);
            self.tcp.deinit();
            self.lib.deinit();
        }

        fn closeErr(self: *ConnT, err: anyerror) void {
            if (@hasDecl(Handler, "onError")) self.handler.onError(err);
            self.tcp.close();
        }

        pub fn send(self: *ConnT, cleartext: []const u8) !void {
            try self.lib.send(cleartext);
        }

        // TODO: rethink this, needed for the same interface across tls/tcp
        pub fn sendZc(self: *ConnT, cleartext: []const u8) !void {
            try self.send(cleartext);
            self.handler.onSend(cleartext);
        }

        pub fn close(self: *ConnT) void {
            self.tcp.close();
        }
    };
}
