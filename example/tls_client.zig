const std = @import("std");
const io = @import("iox");
const mem = std.mem;
const net = std.net;
const posix = std.posix;

const log = std.log.scoped(.main);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // domain from command line argument
    var args_iter = try std.process.argsWithAllocator(allocator);
    defer args_iter.deinit();
    _ = args_iter.next();
    const host_arg = args_iter.next() orelse {
        log.debug("missing domain name", .{});
        return;
    };
    const host = try allocator.dupe(u8, host_arg);
    defer allocator.free(host);
    const port = 443;

    // tls config
    var root_ca = try io.tls.config.CertBundle.fromSystem(allocator);
    defer root_ca.deinit(allocator);
    var diagnostic: io.tls.config.Client.Diagnostic = .{};
    const config: io.tls.config.Client = .{
        .host = host,
        .root_ca = root_ca,
        .diagnostic = &diagnostic,
    };
    const addr = try getAddress(allocator, host_arg, port);

    var io_loop: io.Loop = undefined;
    try io_loop.init(allocator, .{
        .connect_timeout = .{ .sec = 1, .nsec = 0 },
    });
    defer io_loop.deinit();

    var factory = Factory.init(allocator, config);
    defer factory.deinit();

    var connector = io.tls.Connector(Factory).init(allocator, &io_loop, &factory, addr);
    connector.connect();

    _ = try io_loop.run();

    showDiagnostic(&diagnostic, host_arg);
}

const Factory = struct {
    const Self = @This();

    allocator: mem.Allocator,
    config: io.tls.config.Client,
    handler: ?*Https = null,

    fn init(
        allocator: mem.Allocator,
        config: io.tls.config.Client,
    ) Self {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    fn deinit(self: *Self) void {
        if (self.handler) |handler| {
            handler.deinit();
            self.allocator.destroy(handler);
        }
    }

    pub fn create(self: *Self) !struct { *Https, *Https.Tls } {
        const handler = try self.allocator.create(Https);
        errdefer self.allocator.destroy(handler);
        handler.* = .{
            .allocator = self.allocator,
            .host = self.config.host,
            .tls = undefined,
        };
        self.handler = handler;
        return .{ handler, &handler.tls };
    }

    pub fn onError(_: *Self, err: anyerror) void {
        log.err("connect error {}", .{err});
    }

    pub fn onClose(_: *Self) void {
        log.debug("connector closed ", .{});
        posix.raise(posix.SIG.USR1) catch {};
    }
};

const Https = struct {
    const Self = @This();
    const Tls = io.tls.Conn(Self, io.tls.config.Client);

    allocator: mem.Allocator,
    host: []const u8,
    tls: Tls,

    fn deinit(self: *Self) void {
        self.tls.deinit();
    }

    pub fn onConnect(self: *Self) void {
        self.get() catch |err| {
            self.onError(err);
            self.tls.close();
        };
    }

    fn get(self: *Self) !void {
        const request = try std.fmt.allocPrint(self.allocator, "GET / HTTP/1.1\r\nHost: {s}\r\n\r\n", .{self.host});
        try self.tls.send(request);
    }

    pub fn onRecv(self: *Self, bytes: []const u8) usize {
        //log.debug("recv {} bytes: {s}", .{ bytes.len, bytes }); //bytes[0..@min(128, bytes.len)] });
        std.debug.print("{s}", .{bytes});

        if (std.ascii.endsWithIgnoreCase(
            std.mem.trimRight(u8, bytes, "\r\n"),
            "</html>",
        ) or std.ascii.endsWithIgnoreCase(bytes, "\r\n0\r\n\r\n"))
            self.tls.close();

        return bytes.len;
    }

    pub fn onClose(self: *Self) void {
        //log.debug("onClose", .{});
        _ = self;
        posix.raise(posix.SIG.USR1) catch {};
    }

    pub fn onError(self: *Self, err: anyerror) void {
        log.err("{*} {}", .{ self, err });
    }
};

fn getAddress(allocator: mem.Allocator, host: []const u8, port: u16) !net.Address {
    const list = try std.net.getAddressList(allocator, host, port);
    defer list.deinit();
    if (list.addrs.len == 0) return error.UnknownHostName;
    return list.addrs[0];
}

pub fn showDiagnostic(stats: *io.tls.config.Client.Diagnostic, domain: []const u8) void {
    std.debug.print(
        "\n{s}\n\t tls version: {s}\n\t cipher: {s}\n\t named group: {s}\n\t signature scheme: {s}\n",
        .{
            domain,
            if (@intFromEnum(stats.tls_version) == 0) "none" else @tagName(stats.tls_version),
            if (@intFromEnum(stats.cipher_suite_tag) == 0) "none" else @tagName(stats.cipher_suite_tag),
            if (@intFromEnum(stats.named_group) == 0) "none" else @tagName(stats.named_group),
            if (@intFromEnum(stats.signature_scheme) == 0) "none" else @tagName(stats.signature_scheme),
        },
    );
    if (@intFromEnum(stats.client_signature_scheme) != 0) {
        std.debug.print("\t client signature scheme: {s}\n", .{@tagName(stats.client_signature_scheme)});
    }
}
