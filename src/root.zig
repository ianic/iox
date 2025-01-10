const io = @import("io.zig");

pub const Loop = io.Loop;
pub const Op = io.Op;
pub const Error = io.Error;
pub const Options = io.Options;

pub const tcp = struct {
    const _tcp = @import("tcp.zig");
    pub const Conn = _tcp.Conn;
    pub const Listener = _tcp.Listener;
};

pub const udp = struct {
    pub const Sender = @import("udp.zig").Sender;
};

pub const tls = struct {
    const _lib = @import("tls");
    const _tls = @import("tls.zig");

    pub const CipherSuite = _lib.CipherSuite;
    pub const cipher_suites = _lib.cipher_suites;
    pub const PrivateKey = _lib.PrivateKey;
    pub const ClientOptions = _lib.ClientOptions;
    pub const ServerOptions = _lib.ServerOptions;
    pub const CertBundle = _lib.CertBundle;
    pub const CertKeyPair = _lib.CertKeyPair;
    pub const key_log = _lib.key_log;

    pub fn Conn(T: type) type {
        return _tls.Conn(T, .client);
    }
    pub fn Server(T: type) type {
        return _tls.Conn(T, .server);
    }
};

pub const timer = @import("timer.zig");

test {
    _ = @import("io.zig");
    _ = @import("tcp.zig");
    _ = @import("udp.zig");
    _ = @import("fifo.zig");
    _ = @import("errno.zig");
    _ = @import("timer.zig");
}
