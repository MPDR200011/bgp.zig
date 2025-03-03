const std = @import("std");

const TaskErrors = error {
    AlreadyRunning,
};

pub const ScheduledTask = struct {
    task: *const fn()void,
    delay_ms: u64,

    mutex: std.Thread.Mutex,
    waitCondition: std.Thread.Condition,

    shouldRun: bool,
    finishedRunning: bool,
    executorRunning: bool,

    executorThread: ?std.Thread = null,

    const Self = @This();

    pub fn init(delay_ms: u64, task: *const fn()void) Self {
        return .{
            .task=task,
            .delay_ms=delay_ms,
            .shouldRun=true,
            .finishedRunning=false,
            .executorRunning=false,
            .mutex=.{},
            .waitCondition=.{},
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
            self.task();
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
