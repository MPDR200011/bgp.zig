const std = @import("std");
const ip = @import("ip");
const xev = @import("xev");

const rib = @import("main_rib.zig");
const debounced = @import("../utils/debounced.zig");
const model = @import("../messaging/model.zig");
const common = @import("common.zig");

const DoublyLinkedList = std.DoublyLinkedList;
const Allocator = std.mem.Allocator;

const Rib = rib.Rib;

const Route = model.Route;
const PathAttributes = model.PathAttributes;

const TaskCounter = common.TaskCounter;

pub const Operation = union(enum) {
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

pub const OutAdjRibCallback = struct {
    peerId: ip.IpAddress,
    callback: *const fn(*OutAdjRibCallback, *const Operation) void,

    // Leave this alone, it's only set and used by the RibManager
    callbackHandle: ?RibManager.CallbackHandle = null,
};


const RibTask = struct {
    self: *RibManager,
    operation: Operation,
    task: xev.ThreadPool.Task,
};


pub const RibManager = struct {
    const Self = @This();
    const OutAdjRibCbList = DoublyLinkedList(*OutAdjRibCallback);
    pub const CallbackHandle = *OutAdjRibCbList.Node;

    allocator: Allocator,

    ribMutex: std.Thread.Mutex,
    rib: Rib,

    threadPool: *xev.ThreadPool,

    cbMutex: std.Thread.Mutex,
    outAdjRibCbList: OutAdjRibCbList,

    taskCounter: TaskCounter,

    pub fn init(alloc: Allocator, threadPool: *xev.ThreadPool) !Self {
        return Self{
            .allocator = alloc,
            .ribMutex = .{},
            .rib = .init(alloc),
            .threadPool = threadPool,
            .cbMutex = .{},
            .outAdjRibCbList = .{},
            .taskCounter = .default,
        };
    }

    pub fn deinit(self: *Self) Self {
        self.taskCounter.waitForDrainAndShutdown();

        self.rib.deinit();

        // Main rib manager is only deinited during process shutdown.
        // At that point, peer sessions have already gone through the shutdown
        // process, during which time the subscription is deleted.
        std.debug.assert(self.outAdjRibCbList.len() == 0);
    }

    pub fn addUpdatesCallback(self: *Self, callback: *OutAdjRibCallback) Allocator.Error!void {
        self.cbMutex.lock();
        defer self.cbMutex.unlock();

        const node: CallbackHandle = try self.allocator.create(OutAdjRibCbList.Node);
        node.data = callback;

        self.outAdjRibCbList.append(node);

        callback.callbackHandle = node;
    }

    pub fn removeUpdatesCallback(self: *Self, callback: *OutAdjRibCallback) void {
        self.cbMutex.lock();
        defer self.cbMutex.unlock();

        std.debug.assert(callback.callbackHandle != null);

        self.outAdjRibCbList.remove(callback.callbackHandle.?);

        self.allocator.destroy(callback.callbackHandle.?);
        callback.callbackHandle = null;
    }

    fn threadPoolCallback(task: *xev.ThreadPool.Task) void {
        const ribTask: *RibTask = @fieldParentPtr("task", task);
        const self = ribTask.self;

        defer self.taskCounter.decrementTasks();

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
            self.cbMutex.lock();
            defer self.cbMutex.unlock();

            var it = self.outAdjRibCbList.first;
            while (it) |subNode| : (it = subNode.next) {
                const sub = subNode.data;
                const peerAddress: ip.IpAddress = peerId: switch (ribTask.operation) {
                    .set => |addParams| {
                        break :peerId addParams[2];
                    },
                    .remove => |removeParams| {
                        break :peerId removeParams[2];
                    }
                };

                if (peerAddress.equals(sub.peerId)) {
                    // Don't advertise stuff back to the peer we learned it from
                    continue;
                }

                @call(.auto, subNode.data.callback, .{sub, &ribTask.operation});
            }
        }

        ribTask.operation.deinit();
        self.allocator.destroy(ribTask);
    }

    fn scheduleTask(self: *Self, task: *RibTask) void {
        self.taskCounter.incrementTasks();
        self.threadPool.schedule(xev.ThreadPool.Batch.from(&task.task));
    }

    pub fn setPath(self: *Self, route: Route, advertiserAddress: ip.IpAddress, attrs: PathAttributes) !void {
        const task = try self.allocator.create(RibTask);
        task.* = .{
            .self = self,
            .operation = .{ .set = .{&self.rib, route, advertiserAddress, try attrs.clone(attrs.allocator)} },
            .task = .{ .callback = Self.threadPoolCallback }
        };

        self.scheduleTask(task);
    }

    pub fn removePath(self: *Self, route: Route, advertiserAddress: ip.IpAddress) !void {
        const task = try self.allocator.create(RibTask);
        task.* = .{
            .self = self,
            .operation = .{ .remove = .{&self.rib, route, advertiserAddress} },
            .task = .{ .callback = Self.threadPoolCallback }
        };

        self.scheduleTask(task);
    }
};
