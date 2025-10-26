const std = @import("std");

const TaskErrors = error{ AlreadyRunning, InvalidDelay };

pub fn Timer(Context: type) type {
    return struct {
        const Self = @This();
        const Callback = *const fn (Context) void;

        cb: Callback,
        ctx: Context,

        delay_ms: u64,

        runMutex: std.Thread.Mutex,
        waitCondition: std.Thread.Condition,

        shouldRun: bool,
        finishedRunning: bool,
        executorRunning: bool,

        threadMutex: std.Thread.Mutex,
        executorThread: ?std.Thread = null,

        pub fn init(cb: Callback, ctx: Context) Self {
            return .{
                .cb = cb,
                .ctx = ctx,
                .delay_ms = 0,
                .shouldRun = true,
                .finishedRunning = false,
                .executorRunning = false,
                .runMutex = .{},
                .waitCondition = .{},
                .threadMutex = .{},
            };
        }

        pub fn deinit(self: *Self) void {
            self.join();
        }

        fn executorFunction(self: *Self) void {
            self.runMutex.lock();
            defer self.runMutex.unlock();

            self.waitCondition.timedWait(&self.runMutex, self.delay_ms * std.time.ns_per_ms) catch |err| {
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
                self.runMutex.lock();
                defer self.runMutex.unlock();

                if (delay_ms == 0) {
                    return TaskErrors.InvalidDelay;
                }

                self.delay_ms = delay_ms;

                if (self.executorRunning) {
                    return TaskErrors.AlreadyRunning;
                }

                // If this has previously run, we want to join that thread
                // before replacing it, otherwise we leak threads
                self.join();

                self.executorRunning = true;
                self.shouldRun = true;
                self.finishedRunning = false;
            }

            {
                self.threadMutex.lock();
                defer self.threadMutex.unlock();
                self.executorThread = try std.Thread.spawn(.{}, Self.executorFunction, .{self});
            }
        }

        pub fn cancel(self: *Self) void {
            defer self.join();

            {
                self.runMutex.lock();
                defer self.runMutex.unlock();

                if (self.finishedRunning or !self.executorRunning) {
                    return;
                }

                self.shouldRun = false;
            }

            self.waitCondition.signal();
        }

        pub fn join(self: *Self) void {
            self.threadMutex.lock();
            defer self.threadMutex.unlock();

            if (self.executorThread) |t| {
                t.join();
            }

            self.executorThread = null;
        }

        pub fn reschedule(self: *Self) !void {
            self.cancel();
            try self.start(self.delay_ms);
        }
    };
}
