const std = @import("std");
const ip = @import("ip");
const xev = @import("xev");

const rib = @import("main_rib.zig");
const debounced = @import("../utils/debounced.zig");
const model = @import("../messaging/model.zig");

const DoublyLinkedList = std.DoublyLinkedList;
const Allocator = std.mem.Allocator;

const Rib = rib.Rib;

const Route = model.Route;
const PathAttributes = model.PathAttributes;

const Operation = union(enum) {
    const Self = @This();

    set: std.meta.ArgsTuple(@TypeOf(Rib.setPath)),
    remove: std.meta.ArgsTuple(@TypeOf(Rib.removePath)),

    pub fn deinit(self: *Self) void {
        switch (self.*) {
            .set => |setOp| {
                const attrs: PathAttributes = setOp[3];
                attrs.deinit();
            },
            else => {}
        }
    }
};

pub const Subscription = struct {
    callback: *const fn(*Subscription, *const Operation) void,
};


const RibTask = struct {
    self: *RibManager,
    operation: Operation,
    task: xev.ThreadPool.Task,
};


pub const RibManager = struct {
    const Self = @This();
    const SubscriberList = DoublyLinkedList(*Subscription);
    const SubscriberHandle = *SubscriberHandle.Node;

    allocator: Allocator,

    ribMutex: std.Thread.Mutex,
    rib: Rib,

    threadPool: *xev.ThreadPool,

    subMutex: std.Thread.Mutex,
    subscribers: SubscriberList,


    taskCountMutex: std.Thread.Mutex,
    taskCountCond: std.Thread.Condition,
    inFlightTaskCount: u32,
    shutdown: bool = false,

    pub fn init(alloc: Allocator, threadPool: *xev.ThreadPool) !Self {
        return Self{
            .allocator = alloc,
            .ribMutex = .{},
            .rib = .init(alloc),
            .threadPool = threadPool,
            .subMutex = .{},
            .subscribers = .{},
            .taskCountMutex = .{},
            .taskCountCond = .{},
            .inFlightTaskCount = 0,
        };
    }

    pub fn deinit(self: *Self) Self {
        self.waitForTaskDrain();

        self.rib.deinit();

        // Main rib manager is only deinited during process shutdown.
        // At that point, peer sessions have already gone through the shutdown
        // process, during which time the subscription is deleted.
        std.debug.assert(self.subscribers.len() == 0);
    }

    fn waitForTaskDrain(self: *Self) void {
        self.taskCountMutex.lock();
        defer self.taskCountMutex.unlock();

        while (self.inFlightTaskCount > 0) {
            self.taskCountCond.wait(&self.taskCountMutex);
        }
        self.shutdown = true;
    }

    fn addUpdatesSubscription(self: *Self, subscription: *Subscription) Allocator.Error!SubscriberHandle {
        self.subMutex.lock();
        defer self.subMutex.unlock();

        const node: SubscriberHandle = try self.allocator.create(SubscriberList.Node);
        node.data = subscription;

        try self.subscribers.append(node);

        return node;
    }

    fn removeUpdatesSubscription(self: *Self, handle: *SubscriberHandle) void {
        self.subMutex.lock();
        defer self.subMutex.unlock();

        self.subscribers.remove(handle);

        self.allocator.destroy(handle);
    }

    fn threadPoolCallback(task: *xev.ThreadPool.Task) void {
        const ribTask: *RibTask = @fieldParentPtr("task", task);
        const self = ribTask.self;
        {
            self.ribMutex.lock();
            defer self.ribMutex.unlock();

            switch (ribTask.operation) {
                .set => |addParams| {
                    @call(.always_inline, Rib.setPath, addParams) catch |err| {
                        std.debug.print("Fatal: Error while adding path to Rib: {}", .{err});
                        std.process.abort();
                    };
                },
                .remove => |removeParams| {
                    // FIXME this result is important for updates
                    _ = @call(.always_inline, Rib.removePath, removeParams);
                }
            }
        }

        {
            self.subMutex.lock();
            defer self.subMutex.unlock();

            var it = self.subscribers.first;
            while (it) |subNode| : (it = subNode.next) {
                @call(.auto, subNode.data.callback, .{subNode.data, &ribTask.operation});
                
            }
        }

        self.taskCountMutex.lock();
        defer self.taskCountMutex.unlock();
        self.inFlightTaskCount -= 1;
        self.taskCountCond.signal();

        ribTask.operation.deinit();
        self.allocator.destroy(ribTask);
    }

    fn scheduleTask(self: *Self, task: *RibTask) void {
        self.taskCountMutex.lock();
        defer self.taskCountMutex.unlock();

        std.debug.assert(!self.shutdown);

        self.inFlightTaskCount += 1;

        self.threadPool.schedule(xev.ThreadPool.Batch.from(&task.task));
    }

    pub fn setPath(self: *Self, route: Route, advertiser: ip.IpAddress, attrs: PathAttributes) !void {
        const task = try self.allocator.create(RibTask);
        task.* = .{
            .self = self,
            .operation = .{ .set = .{&self.rib, route, advertiser, try attrs.clone(attrs.allocator)} },
            .task = .{ .callback = Self.threadPoolCallback }
        };

        self.scheduleTask(task);
    }

    pub fn removePath(self: *Self, route: Route, advertiser: ip.IpAddress) !void {
        const task = try self.allocator.create(RibTask);
        task.* = .{
            .self = self,
            .operation = .{ .remove = .{&self.rib, route, advertiser} },
            .task = .{ .callback = Self.threadPoolCallback }
        };

        self.scheduleTask(task);
    }
};
