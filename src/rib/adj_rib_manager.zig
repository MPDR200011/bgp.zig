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
    allocator: Allocator,
    mutex: *std.Thread.Mutex,
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

    // subcribers (sessions that need to announce updates)
    // worker (processing updates should be async)

    pub fn init(alloc: Allocator, neighbor: ip.IpAddress, subscription: *Subscription, threadPool: *xev.ThreadPool) !Self {
        return Self{
            .allocator = alloc,
            .ribMutex = .{},
            .neighbor = neighbor,
            .adjRib = .init(neighbor, alloc),
            .subscription = subscription,
            .threadPool = threadPool,
        };
    }

    pub fn deinit(self: *Self) void {
        // FIXME: Handle in-flight operation, a.k.a tasks in the threadpool
        self.clearAdjRib();
        self.adjRib.deinit();
    }

    pub fn clearAdjRib(self: *Self) void {
        var iter = self.adjRib.prefixes.keyIterator();
        while (iter.next()) |route| {
            @call(.auto, self.subscription.callback, .{self.subscription, &Operation{.remove = .{&self.adjRib, route.*}}});
        }
    }

    fn threadPoolCallback(task: *xev.ThreadPool.Task) void {
        const adjRibTask: *AdjRibTask = @fieldParentPtr("task", task);
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

        @call(.auto, adjRibTask.subscription.callback, .{adjRibTask.subscription, &adjRibTask.operation});
        
        adjRibTask.operation.deinit();
        adjRibTask.allocator.destroy(adjRibTask);
    }

    pub fn setPath(self: *Self, route: Route, attrs: PathAttributes) !void {
        const task = self.allocator.create(AdjRibTask);
        task.* = .{
            .allocator = self.allocator,
            .mutex = &self.ribMutex,
            .operation = .{ .set = .{&self.rib, route, try attrs.clone(attrs.allocator)} },
            .subscription = self.subscription,
            .task = .{ .callback = Self.threadPoolCallback }
        };

        self.threadPool.schedule(xev.ThreadPool.Batch.from(&task.task));
    }

    pub fn removePath(self: *Self, route: Route) !void {
        const task = self.allocator.create(AdjRibTask);
        task.* = .{
            .allocator = self.allocator,
            .mutex = &self.ribMutex,
            .operation = .{ .set = .{&self.rib, route} },
            .subscription = self.subscription,
            .task = .{ .callback = Self.threadPoolCallback }
        };

        self.threadPool.schedule(xev.ThreadPool.Batch.from(&task.task));
    }
};
