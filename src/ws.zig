const std = @import("std");
const assert = std.debug.assert;
const net = std.net;
const mem = std.mem;
const posix = std.posix;
const io = @import("root.zig");
const ws = @import("ws");

pub fn Client(comptime ChildType: type) type {
    return struct {
        const Self = @This();

        child: ChildType,
        tcp_cli: io.tcp.Client(*Self),
        ws_lib: ws.asyn.Client(*Self),
        err: ?anyerror = null,

        pub fn init(
            self: *Self,
            allocator: mem.Allocator,
            io_loop: *io.Loop,
            child: ChildType,
            address: net.Address,
            uri: []const u8,
        ) void {
            self.* = .{
                .child = child,
                .tcp_cli = io.tcp.Client(*Self).init(allocator, io_loop, self, address),
                .ws_lib = ws.asyn.Client(*Self).init(allocator, self, uri),
            };
            self.tcp_cli.connect();
        }

        pub fn deinit(self: *Self) void {
            self.tcp_cli.deinit();
            self.ws_lib.deinit();
        }

        fn closeErr(self: *Self, err: anyerror) void {
            if (self.err == null) self.err = err;
            self.tcp_cli.close();
        }

        // ----------------- child api

        pub fn send(self: *Self, bytes: []const u8) !void {
            self.ws_lib.send(bytes) catch |err| self.closeErr(err);
        }

        pub fn close(self: *Self) void {
            self.tcp_cli.close();
        }

        // ----------------- tcp callbacks

        pub fn onConnect(self: *Self) !void {
            self.ws_lib.onConnect() catch |err| self.closeErr(err);
        }

        pub fn onRecv(self: *Self, bytes: []u8) !usize {
            return self.ws_lib.onRecv(bytes) catch |err| {
                self.closeErr(err);
                return 0;
            };
        }

        pub fn onClose(self: *Self) void {
            self.child.onClose();
        }

        pub fn onSend(self: *Self, bytes: []const u8) void {
            self.ws_lib.onSend(bytes);
        }

        // ----------------- ws lib callbacks

        pub fn onWsHandshake(self: *Self) !void {
            self.child.onConnect() catch |err| self.closeErr(err);
        }

        pub fn onWsMessage(self: *Self, msg: ws.Message) !void {
            try self.child.onMessage(msg);
        }

        pub fn wsSendZc(self: *Self, bytes: []const u8) !void {
            try self.tcp_cli.sendZc(bytes);
        }

        pub fn getError(self: *Self) ?anyerror {
            if (self.err) |e| return e;
            if (self.tcp_cli.getError()) |e| return e;
            return null;
        }
    };
}
