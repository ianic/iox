const std = @import("std");
const assert = std.debug.assert;
const net = std.net;
const mem = std.mem;
const posix = std.posix;
const io = @import("root.zig");
const tls = @import("tls");
const RecvBuf = @import("tcp.zig").RecvBuf;

fn TcpFacade(comptime T: type) type {
    return struct {
        const Self = @This();
        parent: *T,

        // tcp is connected start tls handshake
        pub fn onConnect(self: *Self) void {
            self.parent.lib.connect() catch |err| self.parent.closeErr(err);
        }

        // Ciphertext bytes received from tcp, pass it to tls lib
        pub fn onRecv(self: *Self, ciphertext: []u8) usize {
            return self.parent.lib.recv(ciphertext) catch |err| {
                self.parent.closeErr(err);
                return 0;
            };
        }

        // tcp connection is closed.
        pub fn onClose(self: *Self) void {
            self.parent.handler.onClose();
        }

        // Ciphertext is copied to the kernel tcp buffers.
        // Safe to release it now.
        pub fn onSend(self: *Self, ciphertext: []const u8) void {
            self.parent.lib.onSend(ciphertext);
        }

        pub fn onError(self: *Self, err: anyerror) void {
            self.parent.handler.onError(err);
        }
    };
}

fn LibFacade(comptime T: type) type {
    return struct {
        const Self = @This();
        parent: *T,
        recv_buf: RecvBuf,

        // tls handshake finished
        pub fn onConnect(self: *Self) void {
            self.parent.handler.onConnect();
        }

        // decrypted cleartext from tls lib
        pub fn onRecv(self: *Self, cleartext: []u8) void {
            const buf = self.recv_buf.append(cleartext) catch |err| return self.parent.closeErr(err);
            const n = self.parent.handler.onRecv(buf);
            self.recv_buf.set(buf[n..]) catch |err| self.parent.closeErr(err);
        }

        // tls lib sends ciphertext
        pub fn sendZc(self: *Self, ciphertext: []const u8) !void {
            try self.parent.tcp.sendZc(ciphertext);
        }
    };
}

pub const HandshakeKind = enum {
    client,
    server,
};

pub fn Conn(comptime Handler: type, comptime handshake: HandshakeKind) type {
    const Config = switch (handshake) {
        .client => io.tls.config.Client,
        .server => io.tls.config.Server,
    };
    return struct {
        const Self = @This();
        const Tcp = io.tcp.Conn(TcpFacade(Self));
        const Lib = tls.asyn.Conn2(LibFacade(Self), Config);

        handler: *Handler,
        tcp: Tcp,
        lib: Lib,
        tcp_facade: TcpFacade(Self),
        lib_facade: LibFacade(Self),

        fn init(
            self: *Self,
            allocator: mem.Allocator,
            io_loop: *io.Loop,
            handler: *Handler,
            socket: posix.socket_t,
            config: Config,
        ) io.Error!void {
            self.* = .{
                .handler = handler,
                .tcp_facade = .{ .parent = self },
                .lib_facade = .{ .parent = self, .recv_buf = RecvBuf.init(allocator) },
                .tcp = Tcp.init(allocator, io_loop, &self.tcp_facade),
                .lib = Lib.init(allocator, &self.lib_facade, config) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => unreachable,
                },
            };
            self.tcp.open(socket);
            if (handshake == .client) {
                // client is doing active handshake, server passive
                self.lib.connect() catch |err| {
                    self.handler.onError(err);
                    return self.tcp.close();
                };
            }
        }

        pub fn deinit(self: *Self) void {
            self.lib_facade.recv_buf.free();
            self.tcp.deinit();
            self.lib.deinit();
        }

        fn closeErr(self: *Self, err: anyerror) void {
            self.handler.onError(err);
            self.tcp.close();
        }

        pub fn send(self: *Self, cleartext: []const u8) !void {
            try self.lib.send(cleartext);
        }

        pub fn sendZc(self: *Self, cleartext: []const u8) !void {
            try self.send(cleartext);
            self.handler.onSend(cleartext);
        }

        pub fn close(self: *Self) void {
            self.tcp.close();
        }
    };
}

const _tcp = @import("tcp.zig");

pub fn Connector(comptime Factory: type) type {
    return _tcp.GenericConnector(Factory, upgrade);
}

pub fn Listener(comptime Factory: type) type {
    return _tcp.GenericListener(Factory, upgrade);
}

fn upgrade(allocator: mem.Allocator, io_loop: *io.Loop, factory: anytype, socket: posix.socket_t) io.Error!void {
    const handler, var conn = try factory.create();
    try conn.init(allocator, io_loop, handler, socket, factory.config);
}
