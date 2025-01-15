const std = @import("std");
const net = std.net;
const mem = std.mem;
const io = @import("root.zig");
const ws = @import("ws");

pub fn Client(comptime Upstream: type) type {
    return struct {
        const Self = @This();
        const TcpClient = io.tcp.Client(*Self.TcpDelegate);
        const WsLib = ws.asyn.Client(Upstream, *TcpClient);

        const TcpDelegate = struct {
            parent: *Self,

            pub fn onConnect(self: *TcpDelegate) !void {
                self.parent.ws_lib.connect() catch |err| {
                    self.parent.upstream.onError(err);
                    self.parent.close();
                };
            }

            pub fn onRecv(self: *TcpDelegate, bytes: []u8) !usize {
                return self.parent.ws_lib.recv(bytes) catch |err| {
                    self.parent.upstream.onError(err);
                    self.parent.close();
                    return 0;
                };
            }

            pub fn onSend(self: *TcpDelegate, bytes: []const u8) void {
                self.parent.ws_lib.onSend(bytes);
            }

            pub fn onError(self: *TcpDelegate, err: anyerror) void {
                self.parent.upstream.onError(err);
            }

            pub fn onClose(self: *TcpDelegate) void {
                self.parent.upstream.onClose();
            }
        };

        upstream: Upstream,
        tcp_cli: TcpClient,
        tcp_delegate: TcpDelegate,
        ws_lib: WsLib,

        pub fn connect(
            self: *Self,
            allocator: mem.Allocator,
            io_loop: *io.Loop,
            upstream: Upstream,
            address: net.Address,
            uri: []const u8,
        ) void {
            self.* = .{
                .upstream = upstream,
                .tcp_cli = TcpClient.init(allocator, io_loop, &self.tcp_delegate, address),
                .ws_lib = WsLib.init(allocator, upstream, &self.tcp_cli, uri),
                .tcp_delegate = TcpDelegate{ .parent = self },
            };
            self.tcp_cli.connect();
        }

        pub fn deinit(self: *Self) void {
            self.tcp_cli.deinit();
            self.ws_lib.deinit();
        }

        pub fn send(self: *Self, bytes: []const u8) !void {
            try self.ws_lib.send(bytes);
        }

        pub fn close(self: *Self) void {
            self.tcp_cli.close();
        }
    };
}
