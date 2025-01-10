const std = @import("std");
const io = @import("iox");
const mem = std.mem;
const net = std.net;
const posix = std.posix;

const log = std.log.scoped(.main);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

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

    var io_loop: io.Loop = undefined;
    try io_loop.init(allocator, .{
        .connect_timeout = .{ .sec = 1, .nsec = 0 },
    });
    defer io_loop.deinit();

    var root_ca = try io.tls.CertBundle.fromSystem(allocator);
    defer root_ca.deinit(allocator);
    const addr = try getAddress(allocator, host_arg, port);

    var diagnostic: io.tls.ClientOptions.Diagnostic = .{};
    const opt: io.tls.ClientOptions = .{
        .host = host_arg,
        .root_ca = root_ca,
        .cipher_suites = io.tls.cipher_suites.all,
        .key_log_callback = io.tls.key_log.callback,
        .diagnostic = &diagnostic,
    };
    var https: Https = undefined;
    try https.init(allocator, &io_loop, addr, opt);
    defer https.deinit();

    _ = try io_loop.run();

    showDiagnostic(&diagnostic, host_arg);
}

const Https = struct {
    const Self = @This();
    allocator: mem.Allocator,
    host: []const u8,
    conn: io.tls.Conn(*Https),

    fn init(
        self: *Self,
        allocator: mem.Allocator,
        ev: *io.Loop,
        address: std.net.Address,
        opt: io.tls.ClientOptions,
    ) !void {
        self.* = .{
            .allocator = allocator,
            .host = opt.host,
            .conn = undefined,
        };
        self.conn.init(allocator, ev, self);
        errdefer self.conn.deinit();
        try self.conn.connect(address, opt);
    }

    fn deinit(self: *Self) void {
        self.conn.deinit();
    }

    pub fn onConnect(self: *Self) !void {
        const request = try std.fmt.allocPrint(self.allocator, "GET / HTTP/1.1\r\nHost: {s}\r\n\r\n", .{self.host});
        try self.conn.send(request);
    }

    pub fn onRecv(self: *Self, bytes: []const u8) !void {
        //log.debug("recv {} bytes: {s}", .{ bytes.len, bytes }); //bytes[0..@min(128, bytes.len)] });
        std.debug.print("{s}", .{bytes});

        if (std.ascii.endsWithIgnoreCase(
            std.mem.trimRight(u8, bytes, "\r\n"),
            "</html>",
        ) or std.ascii.endsWithIgnoreCase(bytes, "\r\n0\r\n\r\n"))
            self.conn.close();
    }

    pub fn onClose(self: *Self) void {
        //log.debug("onClose", .{});
        _ = self;
        posix.raise(posix.SIG.USR1) catch |err| {
            log.err("raise {}", .{err});
        };
    }
};

fn getAddress(allocator: mem.Allocator, host: []const u8, port: u16) !net.Address {
    const list = try std.net.getAddressList(allocator, host, port);
    defer list.deinit();
    if (list.addrs.len == 0) return error.UnknownHostName;
    // if (list.addrs.len > 0)
    //     std.debug.print("list.addrs: {any}\n", .{list.addrs});
    return list.addrs[0];
}

pub fn showDiagnostic(stats: *io.tls.ClientOptions.Diagnostic, domain: []const u8) void {
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