const std = @import("std");
const ip = @import("ip");
const xev = @import("xev");

const adjRib = @import("adj_rib.zig");
const debounced = @import("../utils/debounced.zig");
const model = @import("../messaging/model.zig");

const Allocator = std.mem.Allocator;

const AdjRib = adjRib.AdjRib;

const Route = model.Route;
const PathAttributes = model.PathAttributes;

pub const Operation = union(enum) {
    const Self = @This();

    set: std.meta.ArgsTuple(@TypeOf(AdjRib.setPath)),
    remove: std.meta.ArgsTuple(@TypeOf(AdjRib.removePath)),

    pub fn deinit(self: *Self) void {
        switch (self) {
            .set => |setOp| {
                const attrs: PathAttributes = setOp[2];
                attrs.deinit();
            },
            else => {}
        }
    }
};

pub const Subscription = struct {
    callback: *const fn(*Subscription, *const Operation) void,
};

const AdjRibTask = struct {
    self: *AdjRibManager,
    operation: Operation,
    subscription: *Subscription,
    task: xev.ThreadPool.Task,
};


pub const AdjRibManager = struct {
    const Self = @This();

    allocator: Allocator,

    ribMutex: std.Thread.Mutex,

    neighbor: ip.IpAddress,
    adjRib: AdjRib,

    threadPool: *xev.ThreadPool,

    subscription: *Subscription,

    taskCountMutex: std.Thread.Mutex,
    taskCountCond: std.Thread.Condition,
    inFlightTaskCount: u32,
    shutdown: bool = false,

    pub fn init(alloc: Allocator, neighbor: ip.IpAddress, subscription: *Subscription, threadPool: *xev.ThreadPool) !Self {
        return Self{
            .allocator = alloc,
            .ribMutex = .{},
            .neighbor = neighbor,
            .adjRib = .init(neighbor, alloc),
            .subscription = subscription,
            .threadPool = threadPool,
            .taskCountMutex = .{},
            .taskCountCond = .{},
            .inFlightTaskCount = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.waitForTaskDrain();

        self.clearAdjRib();
        self.adjRib.deinit();
    }

    fn waitForTaskDrain(self: *Self) void {
        self.taskCountMutex.lock();
        defer self.taskCountMutex.unlock();

        while (self.inFlightTaskCount > 0) {
            self.taskCountCond.wait(&self.taskCountMutex);
        }

        self.shutdown = true;
    }

    pub fn clearAdjRib(self: *Self) void {
        var iter = self.adjRib.prefixes.keyIterator();
        while (iter.next()) |route| {
            @call(.auto, self.subscription.callback, .{self.subscription, &Operation{.remove = .{&self.adjRib, route.*}}});
        }
    }

    fn threadPoolCallback(task: *xev.ThreadPool.Task) void {
        const adjRibTask: *AdjRibTask = @fieldParentPtr("task", task);
        const self = adjRibTask.self;

        {
            adjRibTask.mutex.lock();
            defer adjRibTask.mutex.unlock();

            switch (adjRibTask.operation) {
                .set => |addParams| {
                    @call(.auto, AdjRib.setPath, addParams) catch |err| {
                        std.debug.print("Fatal: Error while adding path to Rib: {}", .{err});
                        std.process.abort();
                    };
                },
                .remove => |removeParams| {
                    @call(.auto, AdjRib.removePath, removeParams);
                }
            }
        }

        @call(.auto, adjRibTask.subscription.callback, .{adjRibTask.subscription, &adjRibTask.operation});

        self.taskCountMutex.lock();
        defer self.taskCountMutex.unlock();
        self.inFlightTaskCount -= 1;
        self.taskCountCond.signal();
        
        adjRibTask.operation.deinit();
        adjRibTask.allocator.destroy(adjRibTask);
    }

    fn scheduleTask(self: *Self, task: *AdjRibTask) void {
        self.taskCountMutex.lock();
        defer self.taskCountMutex.unlock();

        std.debug.assert(!self.shutdown);

        self.inFlightTaskCount += 1;

        self.threadPool.schedule(xev.ThreadPool.Batch.from(&task.task));
    }

    pub fn setPath(self: *Self, route: Route, attrs: PathAttributes) !void {
        const task = self.allocator.create(AdjRibTask);
        task.* = .{
            .self = self,
            .operation = .{ .set = .{&self.rib, route, try attrs.clone(attrs.allocator)} },
            .subscription = self.subscription,
            .task = .{ .callback = Self.threadPoolCallback }
        };

        self.scheduleTask(task);
    }

    pub fn removePath(self: *Self, route: Route) !void {
        const task = self.allocator.create(AdjRibTask);
        task.* = .{
            .self = self,
            .operation = .{ .set = .{&self.rib, route} },
            .subscription = self.subscription,
            .task = .{ .callback = Self.threadPoolCallback }
        };

        self.scheduleTask(task);
    }
};
