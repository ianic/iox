const std = @import("std");
const io = @import("iox");

pub fn main() !void {
    std.debug.print("Hello World, {}\n", .{io.timer.infinite});
}
