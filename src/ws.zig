const std = @import("std");
const net = std.net;
const mem = std.mem;
const io = @import("root.zig");
const ws = @import("ws");

pub fn Client(comptime Upstream: type) type {
    return struct {
        const Self = @This();

        pub const Tcp = io.tcp.Client(Delegate);
        pub const Tls = io.tls.Client(Delegate);
        pub const WsLib = ws.asyn.Client(Upstream, Downstream);

        const Downstream = union(enum) {
            tcp: *Tcp,
            tls: *Tls,

            pub fn sendZc(self: Downstream, data: []const u8) !void {
                switch (self) {
                    inline else => |cli| return cli.sendZc(data),
                }
            }
            pub fn close(self: Downstream) void {
                switch (self) {
                    inline else => |cli| cli.close(),
                }
            }
            pub fn connect(self: Downstream) void {
                switch (self) {
                    inline else => |cli| cli.connect(),
                }
            }
            pub fn deinit(self: Downstream) void {
                switch (self) {
                    inline else => |cli| cli.deinit(),
                }
            }
            fn destroy(self: Downstream, allocator: mem.Allocator) void {
                switch (self) {
                    inline else => |cli| allocator.destroy(cli),
                }
            }
        };

        const Delegate = struct {
            parent: *Self,

            pub fn onConnect(self: *Delegate) void {
                self.parent.ws_lib.connect() catch |err| {
                    self.parent.upstream.onError(err);
                    self.parent.close();
                };
            }

            pub fn onRecv(self: *Delegate, bytes: []u8) usize {
                return self.parent.ws_lib.recv(bytes) catch |err| {
                    if (err != error.EndOfStream) self.parent.upstream.onError(err);
                    self.parent.close();
                    return bytes.len;
                };
            }

            pub fn onSend(self: *Delegate, bytes: []const u8) void {
                self.parent.ws_lib.onSend(bytes);
            }

            pub fn onError(self: *Delegate, err: anyerror) void {
                self.parent.upstream.onError(err);
            }

            pub fn onClose(self: *Delegate) void {
                self.parent.upstream.onClose();
            }
        };

        allocator: mem.Allocator,
        upstream: *Upstream,
        downstream: Downstream,
        tcp_delegate: Delegate,
        ws_lib: WsLib,

        pub fn connect(
            self: *Self,
            allocator: mem.Allocator,
            io_loop: *io.Loop,
            upstream: *Upstream,
            config: Config,
            // address: net.Address,
            // uri: []const u8,
            // opt: io.tls.config.Client,
        ) !void {
            self.* = .{
                .allocator = allocator,
                .upstream = upstream,
                .ws_lib = WsLib.init(allocator, upstream, &self.downstream, config.uri),
                .tcp_delegate = Delegate{ .parent = self },
                .downstream = undefined,
            };
            self.downstream = switch (config.scheme) {
                .wss => brk: {
                    const tls_cli = try allocator.create(Tls);
                    try tls_cli.init(allocator, io_loop, &self.tcp_delegate, config.addr, .{
                        .host = config.host,
                        .root_ca = config.root_ca.?,
                    });
                    break :brk .{ .tls = tls_cli };
                },
                .ws => brk: {
                    const tcp_cli = try allocator.create(Tcp);
                    tcp_cli.* = Tcp.init(allocator, io_loop, &self.tcp_delegate, config.addr);
                    break :brk .{ .tcp = tcp_cli };
                },
            };
            self.downstream.connect();
        }

        pub fn deinit(self: *Self) void {
            self.downstream.deinit();
            self.downstream.destroy(self.allocator);
            self.ws_lib.deinit();
        }

        pub fn send(self: *Self, bytes: []const u8) !void {
            try self.ws_lib.send(bytes);
        }

        pub fn sendMsg(self: *Self, msg: ws.Message) !void {
            try self.ws_lib.sendMsg(msg);
        }

        pub fn close(self: *Self) void {
            self.downstream.close();
        }
    };
}

test "sizes" {
    const T = struct {
        const Self = @This();
        pub fn onConnect(_: *Self) void {}
        pub fn onMessage(_: *Self, _: io.ws.Message) void {}
        pub fn onError(_: *Self, _: anyerror) void {}
        pub fn onClose(_: *Self) void {}
    };

    std.debug.print("size of: {}\n", .{@sizeOf(Client(T))});
}

const testing = std.testing;

test "parse uri" {
    const allocator = testing.allocator;
    {
        const url = "ws://supersport.hr";
        var config = try Config.fromUri(allocator, url);
        defer config.deinit(allocator);

        try testing.expectEqual(.ws, config.scheme);
        try testing.expectEqual(80, config.port);
        try testing.expectEqualStrings("supersport.hr", config.host);
    }
    {
        const url = "wss://ws.vi-server.org/mirror/";
        var config = try Config.fromUri(allocator, url);
        defer config.deinit(allocator);

        try testing.expectEqual(.wss, config.scheme);
        try testing.expectEqual(443, config.port);
        try testing.expectEqualStrings("ws.vi-server.org", config.host);
    }
}

pub const Config = struct {
    const Scheme = enum {
        ws,
        wss,
    };

    scheme: Scheme,
    uri: []const u8,
    host: []const u8,
    port: u16,
    addr: net.Address,
    root_ca: ?io.tls.config.CertBundle = null,

    pub fn deinit(self: *Config, allocator: mem.Allocator) void {
        if (self.root_ca) |*root_ca| root_ca.deinit(allocator);
        allocator.free(self.host);
        allocator.free(self.uri);
    }

    pub fn fromUri(allocator: mem.Allocator, text: []const u8) !Config {
        const parsed = try std.Uri.parse(text);
        const scheme: Scheme = if (mem.eql(u8, "ws", parsed.scheme))
            .ws
        else if (mem.eql(u8, "wss", parsed.scheme))
            .wss
        else
            return error.UnknownScheme;

        const uri_host = if (parsed.host) |host| switch (host) {
            .percent_encoded => |v| v,
            .raw => |v| v,
        } else return error.HostNotFound;
        const host = try allocator.dupe(u8, uri_host);
        errdefer allocator.free(host);

        const port: u16 = if (parsed.port) |port| port else switch (scheme) {
            .ws => 80,
            .wss => 443,
        };

        const addr = try getAddress(allocator, host, port);

        var root_ca = if (scheme == .wss)
            try io.tls.config.CertBundle.fromSystem(allocator)
        else
            null;
        errdefer if (root_ca) |*ca| ca.deinit(allocator);

        const uri = try allocator.dupe(u8, text);
        errdefer allocator.free(uri);

        return .{
            .uri = uri,
            .scheme = scheme,
            .host = host,
            .port = port,
            .root_ca = root_ca,
            .addr = addr,
        };
    }
};

fn getAddress(allocator: mem.Allocator, host: []const u8, port: u16) !net.Address {
    const list = try std.net.getAddressList(allocator, host, port);
    defer list.deinit();
    if (list.addrs.len == 0) return error.UnknownHostName;
    return list.addrs[0];
}
