const std = @import("std");
const net = std.net;
const mem = std.mem;
const posix = std.posix;
const testing = std.testing;

const io = @import("root.zig");
const ws = @import("ws");

pub fn Client(comptime Handler: type) type {
    return Conn(Handler, .client);
}

/// Handler: upstream application handler, required event handler methods
/// defined above.
pub fn Conn(comptime Handler: type, comptime handshake: io.HandshakeKind) type {
    const Config = switch (handshake) {
        .client => config.Client,
        .server => config.Server,
    };
    return struct {
        const ConnT = @This();

        const Tcp = io.tcp.BufferedConn(TransportFacade);
        const Tls = io.tls.Conn(TransportFacade, handshake);
        const Lib = switch (handshake) {
            .client => ws.asyn.Client(LibFacade),
            .server => ws.asyn.Server(LibFacade),
        };

        // Downstream transport protocol interface
        const Transport = union(enum) {
            tcp: *Tcp,
            tls: *Tls,

            pub fn sendZc(self: Transport, data: []const u8) !void {
                switch (self) {
                    inline else => |cli| try cli.sendZc(data),
                }
            }
            pub fn close(self: Transport) void {
                switch (self) {
                    inline else => |cli| cli.close(),
                }
            }
            pub fn connect(self: Transport, addr: net.Address) void {
                switch (self) {
                    inline else => |cli| cli.connect(addr),
                }
            }
            pub fn accept(self: Transport, socket: posix.socket_t) void {
                switch (self) {
                    inline else => |cli| cli.accept(socket),
                }
            }
            pub fn deinit(self: Transport) void {
                switch (self) {
                    inline else => |cli| cli.deinit(),
                }
            }
            fn destroy(self: Transport, allocator: mem.Allocator) void {
                switch (self) {
                    inline else => |cli| allocator.destroy(cli),
                }
            }
        };

        // Methods exposed to the downstream transport protocol.
        // Hides these from public (handler's) interface.
        const TransportFacade = struct {
            inline fn parent(tf: *TransportFacade) *ConnT {
                return @alignCast(@fieldParentPtr("transport_facade", tf));
            }

            pub fn onConnect(tf: *TransportFacade) void {
                const conn = tf.parent();
                conn.lib.connect() catch |err| {
                    conn.handler.onError(err);
                    conn.close();
                };
            }

            pub fn onRecv(tf: *TransportFacade, bytes: []u8) usize {
                const conn = tf.parent();
                return conn.lib.recv(bytes) catch |err| {
                    if (err != error.EndOfStream)
                        conn.handler.onError(err);
                    conn.close();
                    return bytes.len;
                };
            }

            pub fn onSend(tf: *TransportFacade, bytes: []const u8) void {
                tf.parent().lib.onSend(bytes);
            }

            pub fn onError(tf: *TransportFacade, err: anyerror) void {
                tf.parent().handler.onError(err);
            }

            pub fn onClose(tf: *TransportFacade) void {
                tf.parent().handler.onClose();
            }
        };

        // Methods exposed to websocket library
        const LibFacade = struct {
            inline fn parent(lf: *LibFacade) *ConnT {
                return @alignCast(@fieldParentPtr("lib_facade", lf));
            }

            // Event fired when websocket handshake is finished
            pub fn onConnect(lf: *LibFacade) void {
                lf.parent().handler.onConnect();
            }

            // Event fired when message is received
            pub fn onRecv(lf: *LibFacade, msg: io.ws.Msg) void {
                lf.parent().handler.onRecv(msg);
            }

            // Method called when there is something to send downstream
            pub fn sendZc(lf: *LibFacade, bytes: []const u8) !void {
                try lf.parent().transport.sendZc(bytes);
            }
        };

        allocator: mem.Allocator,
        handler: *Handler,
        transport: Transport,
        transport_facade: TransportFacade,
        lib: Lib,
        lib_facade: LibFacade,

        pub fn init(
            self: *ConnT,
            allocator: mem.Allocator,
            io_loop: *io.Loop,
            handler: *Handler,
            conf: Config,
        ) !void {
            self.* = .{
                .allocator = allocator,
                .handler = handler,
                .lib_facade = .{},
                .transport_facade = .{},
                .lib = Lib.init(allocator, &self.lib_facade, conf.uri),
                .transport = undefined,
            };
            switch (conf.scheme) {
                .wss => {
                    const tls_conn = try allocator.create(Tls);
                    self.transport = .{ .tls = tls_conn };
                    try tls_conn.init(allocator, io_loop, &self.transport_facade, conf.tls.?);
                },
                .ws => {
                    const tcp_conn = try allocator.create(Tcp);
                    self.transport = .{ .tcp = tcp_conn };
                    tcp_conn.init(allocator, io_loop, &self.transport_facade, .{});
                },
            }
        }

        pub fn connect(self: *ConnT, addr: net.Address) void {
            self.transport.connect(addr);
        }

        pub fn accept(self: *ConnT, socket: posix.socket_t) void {
            self.transport.accept(socket);
        }

        pub fn deinit(self: *ConnT) void {
            self.transport.deinit();
            self.transport.destroy(self.allocator);
            self.lib.deinit();
        }

        pub fn send(self: *ConnT, msg: io.ws.Msg) !void {
            try self.lib.send(msg);
        }

        pub fn close(self: *ConnT) void {
            self.transport.close();
        }
    };
}

pub const config = struct {
    pub const Scheme = enum {
        ws,
        wss,
    };
    pub const Client = struct {
        const Self = @This();

        scheme: Scheme,
        uri: []const u8,
        host: []const u8,
        port: u16,
        addr: net.Address,
        tls: ?io.tls.config.Client = null,

        pub fn deinit(self: *Self, allocator: mem.Allocator) void {
            allocator.free(self.host);
            allocator.free(self.uri);
        }

        pub fn fromUri(allocator: mem.Allocator, text: []const u8) !Self {
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

            const uri = try allocator.dupe(u8, text);
            errdefer allocator.free(uri);

            return .{
                .uri = uri,
                .scheme = scheme,
                .host = host,
                .port = port,
                .addr = addr,
            };
        }

        const empty = Self{
            .scheme = .ws,
            .host = &.{},
            .uri = &.{},
            .port = 0,
            .addr = net.Address.initIp4([4]u8{ 0, 0, 0, 0 }, 0),
        };
    };

    pub const Server = struct {
        scheme: Scheme,
        uri: []const u8,
        tls: ?io.tls.config.Server = null,

        pub fn fromUri(uri: []const u8) !Server {
            const parsed = try std.Uri.parse(uri);
            const scheme: Scheme = if (mem.eql(u8, "ws", parsed.scheme))
                .ws
            else if (mem.eql(u8, "wss", parsed.scheme))
                .wss
            else
                return error.UnknownScheme;
            return .{
                .scheme = scheme,
                .uri = uri,
                .tls = null,
            };
        }
    };
};

fn getAddress(allocator: mem.Allocator, host: []const u8, port: u16) !net.Address {
    const list = try std.net.getAddressList(allocator, host, port);
    defer list.deinit();
    if (list.addrs.len == 0) return error.UnknownHostName;
    return list.addrs[0];
}

// Definition of Handler interface
test {
    const Handler = struct {
        const Self = @This();
        pub fn onConnect(_: *Self) void {}
        pub fn onRecv(_: *Self, _: io.ws.Msg) void {}
        pub fn onError(_: *Self, _: anyerror) void {}
        pub fn onClose(_: *Self) void {}
    };
    { // ensure it compiles
        var io_loop: io.Loop = undefined;
        try io_loop.init(testing.allocator, .{});
        defer io_loop.deinit();

        var handler: Handler = .{};
        var ws_cli: Conn(Handler, .client) = undefined;
        try ws_cli.init(testing.allocator, &io_loop, &handler, config.Client.empty);
        defer ws_cli.deinit();
    }
    { // note about type sizes
        try testing.expectEqual(208, @sizeOf(Conn(Handler, .client)));
        try testing.expectEqual(168, @sizeOf(Conn(Handler, .client).Lib));
        try testing.expectEqual(672, @sizeOf(Conn(Handler, .client).Tcp));
        try testing.expectEqual(960, @sizeOf(Conn(Handler, .client).Tls));
        try testing.expectEqual(288, @sizeOf(config.Client));
        try testing.expectEqual(104, @sizeOf(config.Server));
        try testing.expectEqual(16, @sizeOf(Conn(Handler, .client).Transport));
    }
}

test "parse uri" {
    const allocator = testing.allocator;
    {
        const url = "ws://supersport.hr";
        var conf = try config.Client.fromUri(allocator, url);
        defer conf.deinit(allocator);

        try testing.expectEqual(.ws, conf.scheme);
        try testing.expectEqual(80, conf.port);
        try testing.expectEqualStrings("supersport.hr", conf.host);
    }
    {
        const url = "wss://ws.vi-server.org/mirror/";
        var conf = try config.Client.fromUri(allocator, url);
        defer conf.deinit(allocator);

        try testing.expectEqual(.wss, conf.scheme);
        try testing.expectEqual(443, conf.port);
        try testing.expectEqualStrings("ws.vi-server.org", conf.host);
    }
    {
        const url = "wss://localhost:9003";
        var conf = try config.Client.fromUri(allocator, url);
        defer conf.deinit(allocator);

        try testing.expectEqual(.wss, conf.scheme);
        try testing.expectEqual(9003, conf.port);
        try testing.expectEqualStrings("localhost", conf.host);
    }
}
