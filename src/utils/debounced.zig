const std = @import("std");

const Thread = std.Thread;
const Allocator = std.mem.Allocator;

pub const Opts = struct {
    debounceDelay_ms: u64,
    maxTotalDebounceDelay_ms: ?u64 = null,
    initialCapacity: ?usize = null
};

// Debounces calls to the underlying task while accumulating the arguments.
// Once task is triggered it is called with all buffered tasks as a list.
// Each call further delays the execution, until a maximum time limit.
pub fn AccumulatingDebouncedTask(comptime Args: anytype) type {
    const CallQueue = std.ArrayList(Args);
    const Task = *const fn ([]Args) void;


    return struct {
        const Self = @This();
        const WAIT_VALUE: u8 = 1;
        const RUN_VALUE: u8 = 2;

        queue: CallQueue,
        task: Task,

        thread: Thread,

        mutex: Thread.Mutex,
        startFutexValue: std.atomic.Value(u32),

        waitCondition: std.Thread.Condition,

        debounceDelay_ms: u64,
        maxTotalDebounceDelay_ms: u64,
        totalTimeWaiting_ms: u64,
        shouldWait: bool,
        running: bool,

        pub fn init(allocator: Allocator, task: Task, opts: Opts) !*Self {
            var queue: CallQueue = .init(allocator);
            errdefer queue.deinit();
            if (opts.initialCapacity) |cap| {
                try queue.ensureTotalCapacity(cap);
            }

            const self = try allocator.create(Self);
            self.shouldWait = true;

            self.* = .{
                .queue = queue,
                .task = task,
                .thread = try std.Thread.spawn(.{}, Self.worker, .{self}),
                .mutex = .{},
                .startFutexValue = .init(Self.WAIT_VALUE),
                .waitCondition = .{},
                .debounceDelay_ms = opts.debounceDelay_ms,
                .maxTotalDebounceDelay_ms = opts.maxTotalDebounceDelay_ms orelse (opts.debounceDelay_ms * 5),
                .totalTimeWaiting_ms = 0,
                .shouldWait = false,
                .running = true
            };

            return self;
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            {
                self.mutex.lock();
                self.running = false;
                self.startFutexValue.store(Self.RUN_VALUE, .monotonic);
                std.Thread.Futex.wake(&self.startFutexValue, 1);
                self.mutex.unlock();

                self.thread.join();
                self.queue.deinit();

            }
            allocator.destroy(self);
        }

        pub fn call(self: *Self, args: Args) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            try self.queue.append(args);

            self.shouldWait = true;
            self.startFutexValue.store(Self.RUN_VALUE, .monotonic);
            std.Thread.Futex.wake(&self.startFutexValue, 1);

            self.waitCondition.signal();
        }

        fn worker(self: *Self) void {
            while (self.running) {
                std.Thread.Futex.wait(&self.startFutexValue, Self.WAIT_VALUE);

                self.mutex.lock();
                defer self.mutex.unlock();

                waitLoop: while (self.shouldWait) {
                    self.shouldWait = false;

                    const waitAmount = @min(self.debounceDelay_ms, self.maxTotalDebounceDelay_ms - self.totalTimeWaiting_ms) * std.time.ns_per_ms;

                    const start = std.time.milliTimestamp();
                    self.waitCondition.timedWait(&self.mutex, waitAmount) catch |err| {
                        std.debug.assert(err == error.Timeout);
                    };
                    const end = std.time.milliTimestamp();

                    self.totalTimeWaiting_ms += @intCast(end - start);

                    if (self.totalTimeWaiting_ms >= self.maxTotalDebounceDelay_ms) {
                        break :waitLoop;
                    }
                }

                @call(.auto, self.task, .{self.queue.items});

                self.startFutexValue.store(Self.WAIT_VALUE, .unordered);

                self.queue.clearRetainingCapacity();
                self.shouldWait = false;

                self.totalTimeWaiting_ms = 0;
                self.shouldWait = false;
            }
        }
    };
}

