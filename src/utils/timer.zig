const std = @import("std");

const TaskErrors = error{
    AlreadyRunning,
};

pub fn Timer(Context: type) type {
    return struct {
        const Self = @This();
        const Callback = *const fn (Context) void;

        cb: Callback,
        ctx: Context,

        delay_ms: u64,

        mutex: std.Thread.Mutex,
        waitCondition: std.Thread.Condition,

        shouldRun: bool,
        finishedRunning: bool,
        executorRunning: bool,

        executorThread: ?std.Thread = null,

        pub fn init(delay_ms: u64, cb: Callback, ctx: Context) Self {
            return .{
                .cb = cb,
                .ctx = ctx,
                .delay_ms = delay_ms,
                .shouldRun = true,
                .finishedRunning = false,
                .executorRunning = false,
                .mutex = .{},
                .waitCondition = .{},
            };
        }

        pub fn deinit(_: *Self) void {}

        fn executorFunction(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.waitCondition.timedWait(&self.mutex, self.delay_ms * std.time.ns_per_ms) catch |err| {
                std.debug.assert(err == error.Timeout);
            };

            if (self.shouldRun) {
                @call(.always_inline, self.cp, .{self.ctx});
                self.cp();
            }

            self.finishedRunning = true;
            self.executorRunning = false;
        }

        pub fn start(self: *Self) !void {
            {
                self.mutex.lock();
                defer self.mutex.unlock();

                if (self.executorRunning) {
                    return TaskErrors.AlreadyRunning;
                }

                self.executorRunning = true;
                self.shouldRun = true;
                self.finishedRunning = false;
            }

            self.executorThread = try std.Thread.spawn(.{}, Self.executorFunction, .{self});
        }

        pub fn cancel(self: *Self) void {
            {
                self.mutex.lock();
                defer self.mutex.unlock();

                if (self.finishedRunning) {
                    return;
                }

                self.shouldRun = false;
            }

            self.waitCondition.signal();
            self.executorThread.?.join();
        }

        pub fn join(self: *Self) void {
            self.executorThread.?.join();
        }

        pub fn reschedule(self: *Self) !void {
            self.cancel();
            try self.start();
        }
    };
}
