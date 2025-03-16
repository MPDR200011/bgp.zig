const std = @import("std");

const TaskErrors = error{ AlreadyRunning, InvalidDelay };

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

        pub fn init(cb: Callback, ctx: Context) Self {
            return .{
                .cb = cb,
                .ctx = ctx,
                .delay_ms = 0,
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
                @call(.auto, self.cb, .{self.ctx});
            }

            self.finishedRunning = true;
            self.executorRunning = false;
        }

        pub fn isActive(self: *Self) bool {
            return self.executorRunning;
        }

        pub fn start(self: *Self, delay_ms: u64) !void {
            {
                self.mutex.lock();
                defer self.mutex.unlock();

                if (delay_ms == 0) {
                    return TaskErrors.InvalidDelay;
                }

                self.delay_ms = delay_ms;

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

                if (self.finishedRunning or !self.executorRunning) {
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
            try self.start(self.delay_ms);
        }
    };
}
