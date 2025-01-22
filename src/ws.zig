const std = @import("std");
const net = std.net;
const mem = std.mem;
const posix = std.posix;
const testing = std.testing;

const io = @import("root.zig");
const ws = @import("ws");

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
        try ws_cli.init(testing.allocator, &io_loop, &handler, 0, config.Client.empty);
        defer ws_cli.deinit();
    }
    { // note about type sizes
        try testing.expectEqual(224, @sizeOf(Conn(Handler, .client)));
        try testing.expectEqual(168, @sizeOf(Conn(Handler, .client).Lib));
        try testing.expectEqual(376, @sizeOf(Conn(Handler, .client).Tcp));
        try testing.expectEqual(680, @sizeOf(Conn(Handler, .client).Tls));
        try testing.expectEqual(288, @sizeOf(config.Client));
        try testing.expectEqual(104, @sizeOf(config.Server));
        try testing.expectEqual(16, @sizeOf(Conn(Handler, .client).Transport));
    }
}

/// Handler: upstream application handler, required event handler methods
/// defined above.
pub fn Conn(comptime Handler: type, comptime handshake: io.HandshakeKind) type {
    const Config = switch (handshake) {
        .client => config.Client,
        .server => config.Server,
    };
    return struct {
        const Self = @This();

        const Tcp = io.tcp.Conn(TransportFacade);
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
            pub fn connect(self: Transport) void {
                switch (self) {
                    inline else => |cli| cli.connect(),
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
            parent: *Self,

            pub fn onConnect(self: *TransportFacade) void {
                self.parent.lib.connect() catch |err| {
                    self.parent.handler.onError(err);
                    self.parent.close();
                };
            }

            pub fn onRecv(self: *TransportFacade, bytes: []u8) usize {
                return self.parent.lib.recv(bytes) catch |err| {
                    if (err != error.EndOfStream)
                        self.parent.handler.onError(err);
                    self.parent.close();
                    return bytes.len;
                };
            }

            pub fn onSend(self: *TransportFacade, bytes: []const u8) void {
                self.parent.lib.onSend(bytes);
            }

            pub fn onError(self: *TransportFacade, err: anyerror) void {
                self.parent.handler.onError(err);
            }

            pub fn onClose(self: *TransportFacade) void {
                self.parent.handler.onClose();
            }
        };

        // Methods exposed to websocket library
        const LibFacade = struct {
            parent: *Self,

            // Event fired when websocket handshake is finished
            pub fn onConnect(self: *LibFacade) void {
                self.parent.handler.onConnect();
            }

            // Event fired when message is received
            pub fn onRecv(self: *LibFacade, msg: io.ws.Msg) void {
                self.parent.handler.onRecv(msg);
            }

            // Method called when there is something to send downstream
            pub fn sendZc(self: *LibFacade, bytes: []const u8) !void {
                try self.parent.transport.sendZc(bytes);
            }
        };

        allocator: mem.Allocator,
        handler: *Handler,
        transport: Transport,
        transport_facade: TransportFacade,
        lib: Lib,
        lib_facade: LibFacade,

        fn init(
            self: *Self,
            allocator: mem.Allocator,
            io_loop: *io.Loop,
            handler: *Handler,
            socket: posix.socket_t,
            conf: Config,
        ) !void {
            self.* = .{
                .allocator = allocator,
                .handler = handler,
                .lib_facade = .{ .parent = self },
                .transport_facade = .{ .parent = self },
                .lib = Lib.init(allocator, &self.lib_facade, conf.uri),
                .transport = undefined,
            };
            switch (conf.scheme) {
                .wss => {
                    const tls_cli = try allocator.create(Tls);
                    self.transport = .{ .tls = tls_cli };
                    try tls_cli.init(allocator, io_loop, &self.transport_facade, socket, conf.tls.?);
                },
                .ws => {
                    const tcp_cli = try allocator.create(Tcp);
                    self.transport = .{ .tcp = tcp_cli };
                    tcp_cli.init(allocator, io_loop, &self.transport_facade, socket);
                },
            }
        }

        pub fn deinit(self: *Self) void {
            self.transport.deinit();
            self.transport.destroy(self.allocator);
            self.lib.deinit();
        }

        pub fn send(self: *Self, msg: io.ws.Msg) !void {
            try self.lib.send(msg);
        }

        pub fn close(self: *Self) void {
            self.transport.close();
        }
    };
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

pub fn Client(Handler: type) type {
    return struct {
        const Self = @This();

        config: config.Client,
        handler: *Handler,
        conn: *?Conn(Handler, .client),
        connector: Connector(Self),

        pub fn connect(
            self: *Self,
            allocator: mem.Allocator,
            io_loop: *io.Loop,
            handler: *Handler,
            conn: *?Conn(Handler, .client),
            conf: config.Client,
        ) void {
            self.* = .{
                .config = conf,
                .connector = Connector(Self).init(allocator, io_loop, self, conf.addr),
                .handler = handler,
                .conn = conn,
            };
            self.conn.* = null;
            self.connector.connect();
        }

        pub fn create(self: *Self) !struct { *Handler, *Conn(Handler, .client) } {
            self.conn.* = undefined;
            return .{ self.handler, &self.conn.*.? };
        }

        pub fn onError(self: *Self, err: anyerror) void {
            self.handler.onError(err);
        }

        pub fn onClose(self: *Self) void {
            self.handler.onClose();
        }
    };
}
