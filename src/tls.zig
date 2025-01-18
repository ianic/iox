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

pub fn Client(comptime Handler: type) type {
    return struct {
        const Self = @This();
        const Tcp = io.tcp.Client(TcpFacade(Self));
        const Lib = tls.asyn.Client(LibFacade(Self));

        handler: *Handler,
        tcp: Tcp,
        lib: Lib,
        tcp_facade: TcpFacade(Self),
        lib_facade: LibFacade(Self),

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
                .tcp_facade = .{ .parent = self },
                .lib_facade = .{ .parent = self, .recv_buf = RecvBuf.init(allocator) },
                .tcp = Tcp.init(allocator, io_loop, &self.tcp_facade, address),
                .lib = try Lib.init(allocator, &self.lib_facade, config),
            };
        }

        pub fn connect(self: *Self) void {
            self.tcp.connect();
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

pub fn Conn(comptime Handler: type) type {
    return struct {
        const Self = @This();
        const Tcp = io.tcp.Conn(TcpFacade(Self));
        const Lib = tls.asyn.Conn(LibFacade(Self));

        handler: *Handler,
        tcp: Tcp,
        lib: Lib,
        tcp_facade: TcpFacade(Self),
        lib_facade: LibFacade(Self),

        pub fn init(
            self: *Self,
            allocator: mem.Allocator,
            io_loop: *io.Loop,
            handler: *Handler,
            socket: posix.socket_t,
            config: tls.config.Server,
        ) !void {
            self.* = .{
                .handler = handler,
                .tcp_facade = .{ .parent = self },
                .lib_facade = .{ .parent = self, .recv_buf = RecvBuf.init(allocator) },
                .tcp = Tcp.init(allocator, io_loop, &self.tcp_facade),
                .lib = try Lib.init(allocator, &self.lib_facade, config),
            };
            self.tcp.connect(socket);
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
