const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const math = std.math;
const testing = std.testing;
const log = std.log.scoped(.timer);

pub const infinite: u64 = math.maxInt(u64);

pub const Op = struct {
    const Self = @This();

    ctx: *anyopaque,
    callback: *const fn (*Op, u64) anyerror!u64,
    ts: u64 = infinite,
    queue: *Queue,

    pub fn init(
        self: *Op,
        queue: *Queue,
        ctx: anytype,
        comptime onTimer: fn (@TypeOf(ctx), u64) anyerror!u64,
    ) void {
        const Context = @TypeOf(ctx);
        const wrapper = struct {
            fn callback(op: *Op, now: u64) anyerror!u64 {
                const ptr: Context = @ptrCast(@alignCast(op.ctx));
                return onTimer(ptr, now);
            }
        };
        self.* = .{
            .queue = queue,
            .ctx = ctx,
            .callback = wrapper.callback,
            .ts = infinite,
        };
    }

    pub fn update(self: *Self, ts: u64) !void {
        self.ts = ts;
        try self.queue.update(self);
    }

    pub fn deinit(self: *Self) void {
        self.queue.remove(self);
    }

    fn less(_: void, a: *Op, b: *Op) math.Order {
        return math.order(a.ts, b.ts);
    }
};

pub const Queue = struct {
    const PQ = std.PriorityQueue(*Op, void, Op.less);
    const Self = @This();

    pq: PQ,

    pub fn init(allocator: mem.Allocator) Self {
        return .{ .pq = PQ.init(allocator, {}) };
    }

    pub fn deinit(self: *Self) void {
        self.pq.deinit();
    }

    pub fn add(
        self: *Self,
        op: *Op,
        context: anytype,
        comptime onTimer: fn (@TypeOf(context), u64) anyerror!u64,
    ) void {
        op.init(self, context, onTimer);
    }

    fn remove(self: *Self, op: *Op) void {
        const idx = blk: {
            var idx: usize = 0;
            while (idx < self.pq.items.len) : (idx += 1) {
                const item = self.pq.items[idx];
                if (item == op) break :blk idx;
            }
            return;
        };
        _ = self.pq.removeIndex(idx);
    }

    fn update(self: *Self, op: *Op) !void {
        self.remove(op);
        if (op.ts == infinite) return;
        try self.pq.add(op);
    }

    // Fire all due operations. Return next timestamp.
    pub fn tick(self: *Self, ts: u64) u64 {
        var next_ts = infinite;
        while (self.pq.peek()) |op| {
            if (op.ts > ts) {
                next_ts = @min(next_ts, op.ts);
                break;
            }
            op.ts = op.callback(op, ts) catch |err| {
                log.err("timer callback failed {}", .{err});
                next_ts = @min(next_ts, op.ts);
                continue;
            };
            self.update(op) catch {}; // element is just removed
        }
        return next_ts;
    }

    // Smallest timestamp of scheduled operations.
    pub fn next(self: *Self) u64 {
        if (self.pq.peek()) |op| return op.ts;
        return infinite;
    }
};

test Op {
    const allocator = testing.allocator;

    const S1 = struct {
        const Self = @This();

        count: usize = 0,
        op: Op = undefined,

        pub fn onTimer(self: *Self, _: u64) !u64 {
            self.count += 1;
            return infinite;
        }
    };

    const S2 = struct {
        const Self = @This();

        count: usize = 0,
        op: Op = undefined,

        pub fn onTimer(self: *Self, _: u64) !u64 {
            self.count += 1;
            return infinite;
        }
    };

    var pq = Queue.init(allocator);
    defer pq.deinit();

    var c1 = S1{};
    c1.op.init(&pq, &c1, S1.onTimer);
    try c1.op.update(5);
    try testing.expectEqual(5, pq.next());

    var c2 = S2{};
    pq.add(&c2.op, &c2, S2.onTimer);
    try c2.op.update(3);
    try testing.expectEqual(3, pq.next());

    try testing.expectEqual(2, pq.pq.count());
    try testing.expectEqual(3, pq.tick(2));
    try testing.expectEqual(2, pq.pq.count());

    try testing.expectEqual(2, pq.pq.count());
    try testing.expectEqual(5, pq.tick(3));
    try testing.expectEqual(1, pq.pq.count());
    try testing.expectEqual(1, c2.count);
    try testing.expectEqual(0, c1.count);

    try c2.op.update(4);
    try testing.expectEqual(2, pq.pq.count());
    try testing.expectEqual(4, pq.next());

    try c2.op.update(10);
    try testing.expectEqual(2, pq.pq.count());
    try testing.expectEqual(5, pq.next());

    try c1.op.update(20);
    try testing.expectEqual(10, pq.next());
    c2.op.deinit();

    try testing.expectEqual(20, pq.next());
    try testing.expectEqual(1, pq.pq.count());

    try testing.expectEqual(20, pq.tick(11));
    try testing.expectEqual(1, pq.pq.count());

    c1.op.deinit();
    try testing.expectEqual(infinite, pq.tick(20));
}
