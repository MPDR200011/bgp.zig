const std = @import("std");
const debounce = @import("debounce");

var start: i64 = 0;

const Args = std.meta.Tuple(&[_]type{u32, u32});

fn sayHello(values: []Args) void {
    std.debug.print("T = {} --- values: {any}\n", .{std.time.milliTimestamp() - start, values});
}

pub fn main() !void {
    var alloc: std.heap.DebugAllocator(.{}) = .init;
    var task: *debounce.AccumulatingDebouncedTask(Args) = try .init(alloc.allocator(), sayHello, .{
        .debounceDelay_ms = 200,
        .maxTotalDebounceDelay_ms = 1500,
    });
    defer task.deinit(alloc.allocator());

    start = std.time.milliTimestamp();
    std.debug.print("Invoking!\n", .{});
    try task.call(.{1, 2});

    std.Thread.sleep(500 * std.time.ns_per_ms);
    std.debug.print("Invoking!\n", .{});
    try task.call(.{3, 4});

    std.Thread.sleep(100 * std.time.ns_per_ms);
    std.debug.print("Invoking!\n", .{});
    try task.call(.{5, 6});

    std.Thread.sleep(1100 * std.time.ns_per_ms);
    std.debug.print("Invoking!\n", .{});
    try task.call(.{7 ,8});

    std.Thread.sleep(150 * std.time.ns_per_ms);
    std.debug.print("Invoking!\n", .{});
    try task.call(.{9, 10});
}
