const std = @import("std");
const scheduled_task = @import("scheduled_task");

fn sayHello() void {
    std.debug.print("Hello World!\n", .{});
}

pub fn main() !void {
    var task = scheduled_task.ScheduledTask.init(
        10000,
        sayHello,
    );
    defer task.deinit();

    // Normal operation
    var start = std.time.milliTimestamp();
    std.debug.print("Starting the task!\n", .{});
    try task.start();

    std.debug.print("Waiting for completion\n", .{});
    task.join();

    var currentT = std.time.milliTimestamp();
    std.debug.print("{} - Task finished\n", .{currentT - start});


    // Canceled
    start = std.time.milliTimestamp();
    std.debug.print("Starting the task!\n", .{});
    try task.start();

    std.time.sleep(5 * std.time.ns_per_s);
    currentT = std.time.milliTimestamp();
    std.debug.print("{} - Cancelling and waiting for the task\n", .{currentT - start});
    task.cancel();
    std.debug.print("{} - Task finished\n", .{currentT - start});

    // Rescheduling
    start = std.time.milliTimestamp();
    std.debug.print("Starting the task!\n", .{});
    try task.start();

    std.time.sleep(5 * std.time.ns_per_s);
    currentT = std.time.milliTimestamp();
    std.debug.print("{} - Rescheduling and waiting for the task\n", .{currentT - start});
    try task.reschedule();
    task.join();
    currentT = std.time.milliTimestamp();
    std.debug.print("{} - Task finished\n", .{currentT - start});

}
