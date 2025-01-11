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

pub fn Conn(comptime ChildType: type, comptime side: Side) type {
    return struct {
        const Self = @This();

        allocator: mem.Allocator,
        child: ChildType,
        tcp_conn: io.tcp.Conn(*Self),
        tls_conn: switch (side) {
            .client => tls.asyn.Client(*Self),
            .server => tls.asyn.Server(*Self),
        },

        state: State = .closed,

        const State = enum {
            closed, //     initial/final state
            connecting, // establishing tcp connection
            handshake, //  tcp connected, doing tls handshake
            connected, //  tls handshake done, client can send/receive
        };

        pub fn init(
            self: *Self,
            allocator: mem.Allocator,
            io_loop: *io.Loop,
            child: ChildType,
        ) void {
            self.* = .{
                .allocator = allocator,
                .tcp_conn = io.tcp.Conn(*Self).init(allocator, io_loop, self),
                .child = child,
                .tls_conn = undefined,
            };
        }

        pub fn deinit(self: *Self) void {
            self.tls_conn.deinit();
            self.tcp_conn.deinit();
        }

        // ----------------- child api

        pub fn connect(self: *Self, address: net.Address, opt: tls.ClientOptions) !void {
            assert(side == .client);
            self.tls_conn = try tls.asyn.Client(*Self).init(self.allocator, self, opt);
            self.tcp_conn.connect(address);
            self.state = .connecting;
        }

        pub fn connected(self: *Self, socket: posix.socket_t, addr: net.Address, opt: tls.ServerOptions) !void {
            assert(side == .server);
            self.tcp_conn.connected(socket, addr);
            self.tls_conn = try tls.asyn.Server(*Self).init(self.allocator, self, opt);
        }

        pub fn send(self: *Self, cleartext: []const u8) !void {
            if (self.state != .connected) return error.InvalidState;
            self.tls_conn.send(cleartext) catch |err| {
                log.err("tls conn send {}", .{err});
                self.tcp_conn.close();
            };
        }

        pub fn close(self: *Self) void {
            self.tcp_conn.close();
        }

        // ----------------- tcp callbacks

        /// tcp is connected start tls handshake
        pub fn onConnect(self: *Self) !void {
            self.state = .handshake;
            self.tls_conn.startHandshake() catch |err| {
                log.err("tls conn onConnect {}", .{err});
                self.tcp_conn.close();
            };
        }

        /// Ciphertext bytes received from tcp, pass it to tls.
        /// Tls will decrypt it and call onRecvCleartext.
        pub fn onRecv(self: *Self, ciphertext: []u8) !usize {
            return self.tls_conn.onRecv(ciphertext) catch |err| brk: {
                switch (err) {
                    error.EndOfFile => {},
                    else => log.err("tls conn onRecv {}", .{err}),
                }
                self.tcp_conn.close();
                break :brk 0;
            };
        }

        /// Tcp connection is closed.
        pub fn onClose(self: *Self) void {
            self.state = .closed;
            self.child.onClose();
        }

        /// Ciphertext is copied to the kernel tcp buffers.
        /// Safe to release it now.
        pub fn onSend(self: *Self, ciphertext: []const u8) void {
            self.tls_conn.onSend(ciphertext);
        }

        // ----------------- tls callbacks

        /// tls handshake finished
        pub fn onHandshake(self: *Self) void {
            self.state = .connected;
            self.child.onConnect() catch |err| {
                log.err("onConnect {}", .{err});
                self.tcp_conn.close();
            };
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
