const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const net = std.net;
const posix = std.posix;
const linux = std.os.linux;
const IoUring = linux.IoUring;
const socket_t = std.posix.socket_t;

const errFromErrno = @import("errno.zig").toError;
const Fifo = @import("fifo.zig").Fifo;
const timer = @import("timer.zig");

const ns_per_ms = std.time.ns_per_ms;
const ns_per_s = std.time.ns_per_s;

const log = std.log.scoped(.io);

pub const Error = error{OutOfMemory};

pub const RunError = error{
    OutOfMemory,
    // Next tick will ring.submit at start
    SubmissionQueueFull,

    // io_uring enter errors
    // ref: https://manpages.debian.org/unstable/liburing-dev/io_uring_enter.2.en.html#RETURN_VALUE
    SignalInterrupt,
    // hopefully transient errors
    SystemResources,
    CompletionQueueOvercommitted,
    // fatal errors
    FileDescriptorInvalid,
    FileDescriptorInBadState,
    SubmissionQueueEntryInvalid,
    BufferInvalid,
    RingShuttingDown,
    OpcodeNotSupported,
    Unexpected,
};

pub fn isTransientError(err: RunError) bool {
    return switch (err) {
        error.OutOfMemory,
        // Next tick will ring.submit at start
        error.SubmissionQueueFull,

        error.SignalInterrupt,
        // hopefully transient errors
        error.SystemResources,
        error.CompletionQueueOvercommitted,
        => true,
        else => false,
    };
}

pub const Options = struct {
    /// Number of io_uring sqe entries
    entries: u16 = 16 * 1024,
    /// Number of receive buffers
    recv_buffers: u16 = 1024,
    /// Length of each receive buffer in bytes
    recv_buffer_len: u32 = 64 * 1024,

    /// Default timeout for connect operations
    connect_timeout: linux.kernel_timespec = .{ .sec = 10, .nsec = 0 },
};

pub const Loop = struct {
    allocator: mem.Allocator,
    ring: IoUring = undefined,
    timestamp: u64 = 0,
    recv_buf_grp: IoUring.BufferGroup = undefined,
    metric: Metric = .{},
    cqe_buf: [256]linux.io_uring_cqe = undefined,
    cqe_buf_head: usize = 0,
    cqe_buf_tail: usize = 0,
    pending: Fifo(Op) = .{},
    loop_timer: LoopTimer,
    timer_queue: timer.Queue,
    options: Options,

    pub fn init(self: *Loop, allocator: mem.Allocator, options: Options) !void {
        // Flags reference: https://nick-black.com/dankwiki/index.php/Io_uring
        const flags =
            // Create a kernel thread to poll on the submission queue. If the
            // submission queue is kept busy, this thread will reap SQEs without
            // the need for a system call.
            linux.IORING_SETUP_SQPOLL |
            // Hint to the kernel that only a single thread will submit
            // requests, allowing for optimizations.
            linux.IORING_SETUP_SINGLE_ISSUER;
        var ring = try IoUring.init(options.entries, flags);
        errdefer ring.deinit();
        self.* = .{
            .allocator = allocator,
            .ring = ring,
            .timestamp = timestamp(),
            .loop_timer = .{ .loop = self },
            .timer_queue = timer.Queue.init(allocator),
            .options = options,
        };
        if (options.recv_buffers > 0) {
            self.recv_buf_grp = try self.initBufferGroup(1, options.recv_buffers, options.recv_buffer_len);
        } else {
            self.recv_buf_grp.buffers_count = 0;
        }
        self.setTimestamp();
    }

    fn initBufferGroup(self: *Loop, id: u16, count: u16, size: u32) !IoUring.BufferGroup {
        const buffers = try self.allocator.alloc(u8, count * size);
        errdefer self.allocator.free(buffers);
        return try IoUring.BufferGroup.init(&self.ring, id, buffers, size, count);
    }

    pub fn deinit(self: *Loop) void {
        if (self.recv_buf_grp.buffers_count > 0) {
            self.allocator.free(self.recv_buf_grp.buffers);
            self.recv_buf_grp.deinit();
        }
        self.timer_queue.deinit();
        self.ring.deinit();
    }

    pub fn drain(self: *Loop) !void {
        while (self.metric.all.active() > 0) {
            // log.debug("draining active operations: {}", .{self.metric.all.active()});
            try self.tick();
        }
    }

    pub fn tickTs(self: *Loop, ts: u64) !void {
        self.loop_timer.set(ts);
        try self.tick();
    }

    /// Run the loop once.
    pub fn tick(self: *Loop) !void {
        self.metric.loops.inc(1);

        const next_ts = self.timer_queue.next();
        if (next_ts != timer.infinite) self.loop_timer.set(next_ts);

        // Submit prepared sqe-s to the kernel.
        _ = try self.ring.submit();
        // Prepare pending operations
        while (self.pending.peek()) |op| {
            try op.prep(self);
            _ = self.pending.pop();
        }

        if (self.cqe_buf_head >= self.cqe_buf_tail) {
            // Get completions.
            self.cqe_buf_head = 0;
            self.cqe_buf_tail = 0;
            const n = try self.ring.copy_cqes(&self.cqe_buf, 1);
            self.cqe_buf_tail = n;
            self.metric.cqes.inc(n);
        }
        self.setTimestamp();
        // fire timers
        _ = self.timer_queue.tick(self.timestamp);
        // Process completions.
        if (self.cqe_buf_head < self.cqe_buf_tail)
            try self.flushCompletions();
    }

    /// Run the loop until signal or error.
    pub fn run(self: *Loop) RunError!c_int {
        setSignalHandler();
        while (true) {
            if (getSignal()) |sig| return sig;
            self.tick() catch |err| switch (err) {
                error.SignalInterrupt => continue,
                else => return err,
            };
        }
    }

    fn setTimestamp(self: *Loop) void {
        const new_timestamp = timestamp();
        self.timestamp = if (new_timestamp <= self.timestamp) self.timestamp + 1 else new_timestamp;
    }

    fn flushCompletions(self: *Loop) Error!void {
        while (self.cqe_buf_head < self.cqe_buf_tail) : (self.cqe_buf_head += 1) {
            const cqe = self.cqe_buf[self.cqe_buf_head];
            if (cqe.user_data == 0) continue;
            const has_more = flagMore(cqe);
            const op: *Op = @ptrFromInt(@as(usize, @intCast(cqe.user_data)));
            const op_kind: Op.Kind = op.args;
            // Set op flags
            if (has_more) op.flags |= Op.flag_has_more else op.flags &= ~Op.flag_has_more;
            op.flags &= ~Op.flag_submitted;
            // Do operation callback
            try op.callback(op, self, cqe);
            // NOTE: op can be already deallocated here don't use it after callback
            if (!has_more) self.metric.complete(op_kind);
        }
    }

    fn restart(self: *Loop, op: *Op) void {
        self.metric.restart(op.args);
        self.submit(op);
    }

    pub fn submit(self: *Loop, op: *Op) void {
        assert(op.flags & Op.flag_submitted == 0);
        op.flags |= Op.flag_submitted;
        op.prep(self) catch |err| {
            log.debug("fail to submit operation {}", .{err});
            self.pending.push(op);
        };
    }

    pub fn now(self: *Loop) u64 {
        return self.timestamp;
    }

    pub fn tsFromDelay(self: *Loop, delay_ms: u32) u64 {
        return self.timestamp + @as(u64, @intCast(delay_ms)) * std.time.ns_per_ms;
    }

    const LoopTimer = struct {
        loop: *Loop,
        timer_op: Op = .{},
        cancel_op: Op = .{},
        args: Op.TimerArgs = .{},

        const Self = @This();

        pub fn set(self: *Self, ts: u64) void {
            if (self.timer_op.active()) {
                if (self.args.value() <= ts) return;
                return self.cancel();
            }
            self.args.abs(ts);
            self.timer_op = Op.timer(self.args, self, onTimer, onTimerFail);
            self.loop.submit(&self.timer_op);
        }

        fn cancel(self: *Self) void {
            if (!self.timer_op.active()) return;
            if (self.cancel_op.active()) return;
            self.cancel_op = Op.cancel(&self.timer_op, self, onCancel);
            self.loop.submit(&self.cancel_op);
        }

        fn onCancel(_: *Self, _: ?anyerror) void {}
        fn onTimer(_: *Self) Error!void {}
        fn onTimerFail(_: *Self, _: anyerror) Error!void {}
    };
};

fn flagMore(cqe: linux.io_uring_cqe) bool {
    return cqe.flags & linux.IORING_CQE_F_MORE > 0;
}

pub const Op = struct {
    context: u64 = 0,
    callback: *const fn (*Op, *Loop, linux.io_uring_cqe) Error!void = undefined,
    args: Args = undefined,
    next: ?*Op = null,
    flags: u8 = 0,

    const flag_submitted: u8 = 1 << 0;
    const flag_has_more: u8 = 1 << 1;

    const Args = union(Kind) {
        accept: struct {
            socket: socket_t,
            addr: posix.sockaddr align(4) = undefined,
            addr_size: posix.socklen_t = @sizeOf(posix.sockaddr),
        },
        connect: SocketArgs,
        close: struct {
            socket: socket_t,
            err: ?anyerror,
        },
        recv: socket_t,
        sendv: struct {
            socket: socket_t,
            msghdr: *posix.msghdr_const,
            zero_copy: bool,
        },
        send: struct {
            socket: socket_t,
            buf: []const u8,
        },
        timer: TimerArgs,
        socket: SocketArgs,
        shutdown: socket_t,
        cancel: *Op,
    };

    const SocketArgs = struct {
        addr: *std.net.Address,
        socket_type: u32 = posix.SOCK.STREAM | posix.SOCK.CLOEXEC,
        protocol: u32 = 0,
        domain: u32 = 0,
        socket: socket_t = 0,
    };
    const TimerArgs = struct {
        ts: linux.kernel_timespec = .{ .sec = 0, .nsec = 0 },
        count: u32 = 0,
        flags: u32 = 0,

        const IORING_TIMEOUT_MULTISHOT = 1 << 6; // TODO: missing in linux. package

        fn prep(self: *TimerArgs, delay_ns: u64) void {
            const sec = delay_ns / ns_per_s;
            const nsec = (delay_ns - sec * ns_per_s);
            self.ts = .{ .sec = @intCast(sec), .nsec = @intCast(nsec) };
            self.count = 0;
            self.flags = 0;
        }

        fn ticker(self: *TimerArgs, interval_ms: u32) void {
            const sec = interval_ms / std.time.ms_per_s;
            const nsec = (interval_ms - sec * std.time.ms_per_s) * std.time.ns_per_ms;
            self.ts = .{ .sec = @intCast(sec), .nsec = @intCast(nsec) };
            self.count = 0;
            self.flags = IORING_TIMEOUT_MULTISHOT;
        }

        fn abs(self: *TimerArgs, ts_ns: u64) void {
            const sec = ts_ns / ns_per_s;
            const nsec = (ts_ns - sec * ns_per_s);
            self.ts = .{ .sec = @intCast(sec), .nsec = @intCast(nsec) };
            self.count = 0;
            self.flags = linux.IORING_TIMEOUT_ABS | linux.IORING_TIMEOUT_REALTIME;
        }

        fn value(self: TimerArgs) u64 {
            return @as(u64, @intCast(self.ts.sec)) * ns_per_s + @as(u64, @intCast(self.ts.nsec));
        }
    };

    const Kind = enum {
        accept,
        connect,
        close,
        recv,
        sendv,
        send,
        timer,
        socket,
        shutdown,
        cancel,
    };

    pub fn active(op: Op) bool {
        return op.flags & flag_submitted > 0 or
            op.flags & flag_has_more > 0;
    }

    pub fn hasMore(op: Op) bool {
        return op.flags & flag_has_more > 0;
    }

    fn prep(op: *Op, loop: *Loop) !void {
        switch (op.args) {
            .accept => |*arg| _ = try loop.ring.accept_multishot(@intFromPtr(op), arg.socket, &arg.addr, &arg.addr_size, 0),
            .connect => |*arg| {
                // connect and linked timeout operation
                // if timeout is reached connect will get error.OperationCanceled
                var sqe = try loop.ring.connect(@intFromPtr(op), arg.socket, &arg.addr.any, arg.addr.getOsSockLen());
                sqe.flags |= linux.IOSQE_IO_LINK;
                _ = try loop.ring.link_timeout(0, &loop.options.connect_timeout, 0);
            },
            .close => |*arg| _ = try loop.ring.close(@intFromPtr(op), arg.socket),
            .recv => |socket| _ = try loop.recv_buf_grp.recv_multishot(@intFromPtr(op), socket, 0),
            .sendv => |*arg| _ = if (arg.zero_copy)
                try loop.ring.sendmsg_zc(@intFromPtr(op), arg.socket, arg.msghdr, linux.MSG.WAITALL | linux.MSG.NOSIGNAL)
            else
                try loop.ring.sendmsg(@intFromPtr(op), arg.socket, arg.msghdr, linux.MSG.WAITALL | linux.MSG.NOSIGNAL),
            .send => |*arg| _ = try loop.ring.send(@intFromPtr(op), arg.socket, arg.buf, linux.MSG.WAITALL | linux.MSG.NOSIGNAL),
            .timer => |*arg| _ = try loop.ring.timeout(@intFromPtr(op), &arg.ts, arg.count, arg.flags),
            .socket => |*arg| _ = try loop.ring.socket(
                @intFromPtr(op),
                if (arg.domain == 0) arg.addr.any.family else arg.domain,
                arg.socket_type,
                arg.protocol,
                0,
            ),
            .shutdown => |socket| _ = try loop.ring.shutdown(@intFromPtr(op), socket, posix.SHUT.RDWR),
            .cancel => |op_to_cancel| switch (op_to_cancel.args) {
                .timer => _ = try loop.ring.timeout_remove(@intFromPtr(op), @intFromPtr(op_to_cancel), 0),
                else => _ = try loop.ring.cancel(@intFromPtr(op), @intFromPtr(op_to_cancel), 0),
            },
        }
        loop.metric.submit(op.args);
    }

    // Multishot operations -----------------

    pub fn accept(
        socket: socket_t,
        context: anytype,
        comptime success: fn (@TypeOf(context), socket_t, net.Address) Error!void,
        comptime fail: fn (@TypeOf(context), anyerror) Error!void,
    ) Op {
        const Context = @TypeOf(context);
        const wrapper = struct {
            fn complete(op: *Op, loop: *Loop, cqe: linux.io_uring_cqe) Error!void {
                const ctx: Context = @ptrFromInt(op.context);
                switch (cqe.err()) {
                    .SUCCESS => {
                        // Note that for the multishot variants, setting addr and
                        // addrlen may not make a lot of sense, as the same value would
                        // be used for every accepted connection. This means that the
                        // data written to addr may be overwritten by a new connection
                        // before the application has had time to process a past
                        // connection.
                        // Ref: https://man7.org/linux/man-pages/man3/io_uring_prep_multishot_accept.3.html

                        const addr = net.Address.initPosix(&op.args.accept.addr);
                        try success(ctx, @intCast(cqe.res), addr);
                    },
                    .CONNABORTED, .INTR => {}, // continue
                    else => |errno| return try fail(ctx, errFromErrno(errno)),
                }
                if (!flagMore(cqe)) loop.restart(op);
            }
        };
        return .{
            .context = @intFromPtr(context),
            .callback = wrapper.complete,
            .args = .{ .accept = .{ .socket = socket } },
        };
    }

    pub fn recv(
        socket: socket_t,
        context: anytype,
        comptime success: fn (@TypeOf(context), []u8) Error!void,
        comptime fail: fn (@TypeOf(context), anyerror) Error!void,
    ) Op {
        const Context = @TypeOf(context);
        const wrapper = struct {
            fn complete(op: *Op, loop: *Loop, cqe: linux.io_uring_cqe) Error!void {
                const ctx: Context = @ptrFromInt(op.context);
                switch (cqe.err()) {
                    .SUCCESS => {
                        const n: usize = @intCast(cqe.res);
                        if (n == 0)
                            return try fail(ctx, error.EndOfFile);

                        const buffer_id = cqe.buffer_id() catch unreachable;
                        const bytes = loop.recv_buf_grp.get(buffer_id)[0..n];
                        try success(ctx, bytes);
                        loop.recv_buf_grp.put(buffer_id);
                        loop.metric.recv_bytes.inc(n);
                        loop.metric.recv_buf_grp.success.inc(1);

                        // NOTE: recv is not restarted if there is no more
                        // multishot cqe's (like accept). Check op.hasMore
                        // in callback and submit if needed.
                        return;
                    },
                    .NOBUFS => {
                        loop.metric.recv_buf_grp.no_bufs.inc(1);
                    },
                    .INTR => {},
                    else => |errno| return try fail(ctx, errFromErrno(errno)),
                }
                if (!flagMore(cqe)) return loop.restart(op);
            }
        };
        return .{
            .context = @intFromPtr(context),
            .callback = wrapper.complete,
            .args = .{ .recv = socket },
        };
    }

    // Single shot operations -----------------

    pub fn sendv(
        socket: socket_t,
        msghdr: *posix.msghdr_const,
        context: anytype,
        comptime success: fn (@TypeOf(context)) Error!void,
        comptime fail: fn (@TypeOf(context), anyerror) Error!void,
    ) Op {
        return sendv_(socket, msghdr, context, success, fail, false);
    }

    pub fn sendv_zc(
        socket: socket_t,
        msghdr: *posix.msghdr_const,
        context: anytype,
        comptime success: fn (@TypeOf(context)) Error!void,
        comptime fail: fn (@TypeOf(context), anyerror) Error!void,
    ) Op {
        return sendv_(socket, msghdr, context, success, fail, true);
    }

    fn sendv_(
        socket: socket_t,
        msghdr: *posix.msghdr_const,
        context: anytype,
        comptime success: fn (@TypeOf(context)) Error!void,
        comptime fail: fn (@TypeOf(context), anyerror) Error!void,
        zero_copy: bool,
    ) Op {
        const Context = @TypeOf(context);
        const wrapper = struct {
            fn complete(op: *Op, loop: *Loop, cqe: linux.io_uring_cqe) Error!void {
                const ctx: Context = @ptrFromInt(op.context);
                switch (cqe.err()) {
                    .SUCCESS => {
                        const sent_bytes: usize = @intCast(cqe.res);
                        loop.metric.send_bytes.inc(sent_bytes);

                        var data_len: usize = 0;
                        const mh = op.args.sendv.msghdr;
                        for (0..@intCast(mh.iovlen)) |i| data_len += mh.iov[i].len;

                        if (op.args.sendv.zero_copy) {
                            if (cqe.flags & linux.IORING_CQE_F_NOTIF > 0) {
                                return try success(ctx);
                            } else if (cqe.flags & linux.IORING_CQE_F_MORE > 0) {
                                if (sent_bytes < data_len) {
                                    log.err("{} unexpected short send data: {} sent: {}", .{ op.args.sendv.socket, data_len, sent_bytes });
                                    return fail(ctx, error.ShortSend);
                                }
                                return; // wait for second call with f_notif flag set
                            }
                            unreachable;
                        }

                        // While sending with MSG_WAITALL we don't expect to get short send
                        if (sent_bytes < data_len) {
                            log.warn("{} unexpected short send data: {} sent: {}", .{ op.args.sendv.socket, data_len, sent_bytes });
                            return fail(ctx, error.ShortSend);
                        }

                        try success(ctx);
                    },
                    else => |errno| try fail(ctx, errFromErrno(errno)),
                }
            }
        };
        return .{
            .context = @intFromPtr(context),
            .callback = wrapper.complete,
            .args = .{
                .sendv = .{ .socket = socket, .msghdr = msghdr, .zero_copy = zero_copy },
            },
        };
    }

    pub fn send(
        socket: socket_t,
        buf: []const u8,
        context: anytype,
        comptime success: fn (@TypeOf(context)) Error!void,
        comptime fail: fn (@TypeOf(context), anyerror) Error!void,
    ) Op {
        const Context = @TypeOf(context);
        const wrapper = struct {
            fn complete(op: *Op, loop: *Loop, cqe: linux.io_uring_cqe) Error!void {
                const ctx: Context = @ptrFromInt(op.context);
                switch (cqe.err()) {
                    .SUCCESS => {
                        const n: usize = @intCast(cqe.res);
                        loop.metric.send_bytes.inc(n);
                        const send_buf = op.args.send.buf;
                        if (n < send_buf.len) {
                            op.args.send.buf = send_buf[n..];
                            return loop.restart(op);
                        }
                        try success(ctx);
                    },
                    else => |errno| try fail(ctx, errFromErrno(errno)),
                }
            }
        };
        return .{
            .context = @intFromPtr(context),
            .callback = wrapper.complete,
            .args = .{
                .send = .{ .socket = socket, .buf = buf },
            },
        };
    }

    fn timer(
        args: TimerArgs,
        context: anytype,
        comptime success: fn (@TypeOf(context)) Error!void,
        comptime fail: fn (@TypeOf(context), anyerror) Error!void,
    ) Op {
        const Context = @TypeOf(context);
        const wrapper = struct {
            fn complete(op: *Op, _: *Loop, cqe: linux.io_uring_cqe) Error!void {
                const ctx: Context = @ptrFromInt(op.context);
                switch (cqe.err()) {
                    .SUCCESS, .TIME => try success(ctx),
                    else => |errno| try fail(ctx, errFromErrno(errno)),
                }
            }
        };
        return .{
            .context = @intFromPtr(context),
            .callback = wrapper.complete,
            .args = .{ .timer = args },
        };
    }

    pub fn ticker(
        interval_ms: u32,
        context: anytype,
        comptime success: fn (@TypeOf(context)) void,
    ) Op {
        const Context = @TypeOf(context);
        const wrapper = struct {
            fn complete(op: *Op, loop: *Loop, cqe: linux.io_uring_cqe) Error!void {
                const ctx: Context = @ptrFromInt(op.context);
                switch (cqe.err()) {
                    .SUCCESS, .TIME => success(ctx),
                    .CANCELED => return, // don't restart
                    else => {},
                }
                if (!flagMore(cqe)) return loop.restart(op);
            }
        };
        var args: TimerArgs = .{};
        args.ticker(interval_ms);
        return .{
            .context = @intFromPtr(context),
            .callback = wrapper.complete,
            .args = .{ .timer = args },
        };
    }

    // Create socket and connect.
    pub fn connect(
        args: SocketArgs,
        context: anytype,
        comptime success: fn (@TypeOf(context), socket_t) Error!void,
        comptime fail: fn (@TypeOf(context), ?anyerror) void,
    ) Op {
        const Context = @TypeOf(context);
        const wrapper = struct {
            fn complete(op: *Op, loop: *Loop, cqe: linux.io_uring_cqe) Error!void {
                const ctx: Context = @ptrFromInt(op.context);
                switch (cqe.err()) {
                    .SUCCESS => {
                        const socket: socket_t = @intCast(cqe.res);
                        var a = op.args.socket;
                        a.socket = socket;
                        op.* = Op.connectSocket(a, ctx, success, fail);
                        loop.submit(op);
                    },
                    else => |errno| {
                        fail(ctx, errFromErrno(errno));
                    },
                }
            }
        };
        return .{
            .context = @intFromPtr(context),
            .callback = wrapper.complete,
            .args = .{ .socket = args },
        };
    }

    fn connectSocket(
        args: SocketArgs,
        context: anytype,
        comptime success: fn (@TypeOf(context), socket_t) Error!void,
        comptime fail: fn (@TypeOf(context), ?anyerror) void,
    ) Op {
        const Context = @TypeOf(context);
        const wrapper = struct {
            fn complete(op: *Op, loop: *Loop, cqe: linux.io_uring_cqe) Error!void {
                const ctx: Context = @ptrFromInt(op.context);
                switch (cqe.err()) {
                    .SUCCESS => return try success(ctx, op.args.connect.socket),
                    else => |errno| {
                        const err = errFromErrno(errno);
                        op.* = Op.close(op.args.connect.socket, err, ctx, fail);
                        loop.submit(op);
                    },
                }
            }
        };
        return .{
            .context = @intFromPtr(context),
            .callback = wrapper.complete,
            .args = .{ .connect = args },
        };
    }

    // Shutdown and close socket
    pub fn shutdown(
        socket: socket_t,
        context: anytype,
        comptime done: fn (@TypeOf(context), ?anyerror) void,
    ) Op {
        const Context = @TypeOf(context);
        const wrapper = struct {
            fn complete(op: *Op, loop: *Loop, cqe: linux.io_uring_cqe) Error!void {
                const err: ?anyerror = switch (cqe.err()) {
                    .SUCCESS => null,
                    else => |errno| errFromErrno(errno),
                };
                const ctx: Context = @ptrFromInt(op.context);
                op.* = Op.close(op.args.shutdown, err, ctx, done);
                loop.submit(op);
            }
        };
        return .{
            .context = @intFromPtr(context),
            .callback = wrapper.complete,
            .args = .{ .shutdown = socket },
        };
    }

    fn close(
        socket: socket_t,
        err: ?anyerror,
        context: anytype,
        comptime done: fn (@TypeOf(context), ?anyerror) void,
    ) Op {
        const Context = @TypeOf(context);
        const wrapper = struct {
            fn complete(op: *Op, _: *Loop, cqe: linux.io_uring_cqe) Error!void {
                _ = cqe;
                const ctx: Context = @ptrFromInt(op.context);
                done(ctx, op.args.close.err);
            }
        };
        return .{
            .context = @intFromPtr(context),
            .callback = wrapper.complete,
            .args = .{ .close = .{ .socket = socket, .err = err } },
        };
    }

    pub fn cancel(
        op_to_cancel: *Op,
        context: anytype,
        comptime done: fn (@TypeOf(context), ?anyerror) void,
    ) Op {
        const Context = @TypeOf(context);
        const wrapper = struct {
            fn complete(op: *Op, _: *Loop, cqe: linux.io_uring_cqe) Error!void {
                const err: ?anyerror = switch (cqe.err()) {
                    .SUCCESS => null,
                    else => |errno| errFromErrno(errno),
                };
                const ctx: Context = @ptrFromInt(op.context);
                done(ctx, err);
            }
        };
        return .{
            .context = @intFromPtr(context),
            .callback = wrapper.complete,
            .args = .{ .cancel = op_to_cancel },
        };
    }
};

const testing = std.testing;

test "loop timer" {
    if (true) return error.SkipZigTest;

    const allocator = testing.allocator;
    var loop: Loop = undefined;
    try loop.init(allocator, .{ .entries = 4, .recv_buffers = 0, .recv_buffer_len = 0 });
    defer loop.deinit();

    const start = loop.timestamp;
    try loop.tickTs(loop.timestamp + 100 * std.time.ns_per_ms);
    std.debug.print("1: {}\n", .{(loop.timestamp - start) / std.time.ns_per_ms});
    try loop.tickTs(loop.timestamp + 200 * std.time.ns_per_ms);
    std.debug.print("2: {}\n", .{(loop.timestamp - start) / std.time.ns_per_ms});
    loop.loop_timer.set(loop.timestamp + 200 * std.time.ns_per_ms);
    try loop.tickTs(loop.timestamp + 199 * std.time.ns_per_ms);
    std.debug.print("3: {}\n", .{(loop.timestamp - start) / std.time.ns_per_ms});
    try loop.tickTs(loop.timestamp + 100 * std.time.ns_per_ms);
    std.debug.print("4: {}\n", .{(loop.timestamp - start) / std.time.ns_per_ms});
}

fn timestamp() u64 {
    const ts: posix.timespec = posix.clock_gettime(.REALTIME) catch |err| switch (err) {
        error.UnsupportedClock, error.Unexpected => return 0, // "Precision of timing depends on hardware and OS".
    };
    return @as(u64, @intCast(ts.sec)) * ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn unixMilli() i64 {
    var ts: posix.timespec = undefined;
    posix.clock_gettime(.REALTIME, &ts) catch |err| switch (err) {
        error.UnsupportedClock, error.Unexpected => return 0, // "Precision of timing depends on hardware and OS".
    };
    return ts.sec * 1000 + @divTrunc(ts.nsec, ns_per_ms);
}

test "size" {
    const Accept = struct {
        socket: socket_t,
        addr: posix.sockaddr align(4) = undefined,
        addr_size: posix.socklen_t = @sizeOf(posix.sockaddr),
    };
    const Connect = struct {
        socket: socket_t,
        addr: *net.Address,
    };
    const Writev = struct {
        socket: socket_t,
        vec: []posix.iovec_const,
    };
    const Sendv = struct {
        socket: socket_t,
        msghdr: *posix.msghdr_const,
    };
    const Send = struct {
        socket: socket_t,
        buf: []const u8,
    };

    try testing.expectEqual(24, @sizeOf(Op.SocketArgs));

    try testing.expectEqual(64, @sizeOf(Op));
    try testing.expectEqual(32, @sizeOf(Op.Args));
    try testing.expectEqual(24, @sizeOf(Op.TimerArgs));
    try testing.expectEqual(24, @sizeOf(Accept));
    try testing.expectEqual(24, @sizeOf(Writev));
    try testing.expectEqual(24, @sizeOf(Send));

    try testing.expectEqual(16, @sizeOf(Connect));
    try testing.expectEqual(16, @sizeOf(Sendv));
    try testing.expectEqual(112, @sizeOf(net.Address));
    try testing.expectEqual(16, @sizeOf(linux.kernel_timespec));
    try testing.expectEqual(8, @sizeOf(?*Op));
}

const Metric = struct {
    loops: Counter = .{},
    cqes: Counter = .{},
    send_bytes: Counter = .{},
    recv_bytes: Counter = .{},

    recv_buf_grp: struct {
        success: Counter = .{},
        no_bufs: Counter = .{},

        pub fn noBufsPercent(self: @This()) f64 {
            const total = self.success.value + self.no_bufs.value;
            if (total == 0) return 0;
            return @as(f64, @floatFromInt(self.no_bufs.value)) / @as(f64, @floatFromInt(total)) * 100;
        }
    } = .{},

    all: OpCounter = .{},
    accept: OpCounter = .{},
    connect: OpCounter = .{},
    close: OpCounter = .{},
    recv: OpCounter = .{},
    writev: OpCounter = .{},
    sendv: OpCounter = .{},
    timer: OpCounter = .{},

    pub fn write(self: *Metric, writer: anytype) !void {
        {
            try self.all.write("io.op.all", writer);
            try self.sendv.write("io.op.send", writer);
            try self.recv.write("io.op.recv", writer);
            try self.accept.write("io.op.accept", writer);
            try self.connect.write("io.op.connect", writer);
            try self.timer.write("io.op.timer", writer);
        }
        {
            try writer.counter("io", "loops", self.loops.diff());
            try writer.counter("io", "cqes", self.cqes.diff());
            try writer.counter("io", "send_bytes", self.send_bytes.diff());
            try writer.counter("io", "recv_bytes", self.recv_bytes.diff());
        }
        {
            try writer.counter("io.recv_buf_grp", "success", self.recv_buf_grp.success.diff());
            try writer.counter("io.recv_buf_grp", "no_bufs", self.recv_buf_grp.no_bufs.diff());
        }
    }

    const Counter = struct {
        const Self = @This();

        const initial = std.math.maxInt(usize);
        value: usize = 0,
        prev: usize = initial,

        pub fn inc(self: *Self, v: usize) void {
            self.value +%= v;
        }

        pub fn diff(self: *Self) usize {
            if (self.prev == initial) return self.value;
            defer self.reset();
            return self.value -% self.prev;
        }

        fn reset(self: *Self) void {
            self.prev = self.value;
        }

        pub fn jsonStringify(self: *const Self, jws: anytype) !void {
            try jws.write(self.value);
        }
    };

    // Counter of submitted/completed operations
    const OpCounter = struct {
        submitted: Counter = .{},
        completed: Counter = .{},
        restarted: Counter = .{},

        // Current number of active operations
        pub fn active(self: OpCounter) usize {
            return self.submitted.value - self.completed.value;
        }
        fn submit(self: *OpCounter) void {
            self.submitted.inc(1);
        }
        fn complete(self: *OpCounter) void {
            self.completed.inc(1);
        }
        fn restart(self: *OpCounter) void {
            self.restarted.inc(1);
        }

        fn write(self: *OpCounter, prefix: []const u8, stats: anytype) !void {
            try stats.counter(prefix, "submitted", self.submitted.diff());
            try stats.counter(prefix, "completed", self.completed.diff());
            try stats.counter(prefix, "restarted", self.restarted.diff());
            try stats.gauge(prefix, "active", self.active());
        }

        pub fn jsonStringify(self: *const OpCounter, jws: anytype) !void {
            try jws.beginObject();
            try jws.objectField("active");
            try jws.write(self.active());
            try jws.objectField("submit");
            try jws.write(self.submitted);
            try jws.objectField("complete");
            try jws.write(self.completed);
            if (self.restarted.value > 0) {
                try jws.objectField("restart");
                try jws.write(self.restarted);
            }
            try jws.endObject();
        }
    };

    fn submit(self: *Metric, kind: Op.Kind) void {
        self.all.submit();
        switch (kind) {
            .accept => self.accept.submit(),
            .connect => self.connect.submit(),
            .close => self.close.submit(),
            .recv => self.recv.submit(),
            .send, .sendv => self.sendv.submit(),
            .timer => self.timer.submit(),
            .cancel, .socket, .shutdown => {},
        }
    }

    fn complete(self: *Metric, kind: Op.Kind) void {
        self.all.complete();
        switch (kind) {
            .accept => self.accept.complete(),
            .connect => self.connect.complete(),
            .close => self.close.complete(),
            .recv => self.recv.complete(),
            .send, .sendv => self.sendv.complete(),
            .timer => self.timer.complete(),
            .cancel, .socket, .shutdown => {},
        }
    }

    fn restart(self: *Metric, kind: Op.Kind) void {
        self.all.restart();
        switch (kind) {
            .accept => self.accept.restart(),
            .connect => self.connect.restart(),
            .close => self.close.restart(),
            .recv => self.recv.restart(),
            .send, .sendv => self.sendv.restart(),
            .timer => self.timer.restart(),
            .cancel, .socket, .shutdown => {},
        }
    }
};

fn getSignal() ?c_int {
    const sig = signal.load(.monotonic);
    if (sig == posix.SIG.UNUSED)
        return null;
    signal.store(posix.SIG.UNUSED, .release);
    return sig;
}

var signal = std.atomic.Value(c_int).init(posix.SIG.UNUSED);

fn setSignalHandler() void {
    var act = posix.Sigaction{
        .handler = .{
            .handler = struct {
                fn wrapper(sig: c_int) callconv(.C) void {
                    signal.store(sig, .release);
                }
            }.wrapper,
        },
        .mask = posix.empty_sigset,
        .flags = 0,
    };
    posix.sigaction(posix.SIG.TERM, &act, null);
    posix.sigaction(posix.SIG.INT, &act, null);
    posix.sigaction(posix.SIG.USR1, &act, null);
    posix.sigaction(posix.SIG.USR2, &act, null);
    posix.sigaction(posix.SIG.PIPE, &act, null);
}
