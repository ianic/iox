const std = @import("std");
const net = std.net;
const mem = std.mem;
const io = @import("root.zig");
const ws = @import("ws");
const testing = std.testing;

// Definition of Handler interface
test {
    const Handler = struct {
        const Self = @This();
        pub fn onConnect(_: *Self) void {}
        pub fn onMessage(_: *Self, _: io.ws.Msg) void {}
        pub fn onError(_: *Self, _: anyerror) void {}
        pub fn onClose(_: *Self) void {}
    };
    { // ensure it compiles
        var handler: Handler = .{};
        var ws_cli: Client(Handler) = undefined;
        try ws_cli.init(testing.allocator, undefined, &handler, Config.empty);
        defer ws_cli.deinit();
    }
    { // note about type sizes
        try testing.expectEqual(216, @sizeOf(Client(Handler)));
        try testing.expectEqual(168, @sizeOf(Client(Handler).Lib));
        try testing.expectEqual(640, @sizeOf(Client(Handler).Tcp));
        try testing.expectEqual(928, @sizeOf(Client(Handler).Tls));
        try testing.expectEqual(208, @sizeOf(Config));
        try testing.expectEqual(16, @sizeOf(Client(Handler).Transport));
    }
}

/// Handler: upstream application handler, required event handler methods
/// defined above.
pub fn Client(comptime Handler: type) type {
    return struct {
        const Self = @This();

        const Tcp = io.tcp.Client(TransportFacade);
        const Tls = io.tls.Client(TransportFacade);
        const Lib = ws.asyn.Client(LibFacade);

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
        transport_facade: TransportFacade,
        lib_facade: LibFacade,
        transport: Transport,
        lib: Lib,

        fn init(
            self: *Self,
            allocator: mem.Allocator,
            io_loop: *io.Loop,
            handler: *Handler,
            config: Config,
        ) !void {
            self.* = .{
                .allocator = allocator,
                .handler = handler,
                .lib_facade = .{ .parent = self },
                .transport_facade = .{ .parent = self },
                .lib = Lib.init(allocator, &self.lib_facade, config.uri),
                .transport = switch (config.scheme) {
                    .wss => brk: {
                        const tls_cli = try allocator.create(Tls);
                        try tls_cli.init(allocator, io_loop, &self.transport_facade, config.addr, .{
                            .host = config.host,
                            .root_ca = config.root_ca.?,
                        });
                        break :brk .{ .tls = tls_cli };
                    },
                    .ws => brk: {
                        const tcp_cli = try allocator.create(Tcp);
                        tcp_cli.* = Tcp.init(allocator, io_loop, &self.transport_facade, config.addr);
                        break :brk .{ .tcp = tcp_cli };
                    },
                },
            };
        }

        pub fn deinit(self: *Self) void {
            self.transport.deinit();
            self.transport.destroy(self.allocator);
            self.lib.deinit();
        }

        pub fn connect(
            self: *Self,
            allocator: mem.Allocator,
            io_loop: *io.Loop,
            handler: *Handler,
            config: Config,
        ) !void {
            try self.init(allocator, io_loop, handler, config);
            self.transport.connect();
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

    const empty = Config{
        .scheme = .ws,
        .host = &.{},
        .uri = &.{},
        .port = 0,
        .addr = net.Address.initIp4([4]u8{ 0, 0, 0, 0 }, 0),
    };
};

fn getAddress(allocator: mem.Allocator, host: []const u8, port: u16) !net.Address {
    const list = try std.net.getAddressList(allocator, host, port);
    defer list.deinit();
    if (list.addrs.len == 0) return error.UnknownHostName;
    return list.addrs[0];
}
