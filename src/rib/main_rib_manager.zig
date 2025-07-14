const std = @import("std");
const ip = @import("ip");
const xev = @import("xev");

const rib = @import("main_rib.zig");
const debounced = @import("../utils/debounced.zig");
const model = @import("../messaging/model.zig");

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

const RibTask = struct {
    allocator: Allocator,
    mutex: *std.Thread.Mutex,
    operation: Operation,
    task: xev.ThreadPool.Task,
};

pub const RibManager = struct {
    const Self = @This();

    allocator: Allocator,

    ribMutex: std.Thread.Mutex,
    rib: Rib,

    threadPool: *xev.ThreadPool,

    // subcribers (sessions that need to announce updates)
    // worker (processing updates should be async)

    pub fn init(alloc: Allocator, threadPool: *xev.ThreadPool) !Self {
        return Self{
            .allocator = alloc,
            .ribMutex = .{},
            .rib = .init(alloc),
            .threadPool = threadPool,
        };
    }

    pub fn deinit(self: Self) Self {
        self.rib.deinit();
    }

    fn threadPoolCallback(task: *xev.ThreadPool.Task) void {
        const ribTask: *RibTask = @fieldParentPtr("task", task);
        ribTask.mutex.lock();
        ribTask.mutex.unlock();

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

        ribTask.operation.deinit();
        ribTask.allocator.destroy(ribTask);
    }

    pub fn setPath(self: *Self, route: Route, advertiser: ip.IpAddress, attrs: PathAttributes) !void {
        const task = try self.allocator.create(RibTask);
        task.* = .{
            .allocator = self.allocator,
            .mutex = &self.ribMutex,
            .operation = .{ .set = .{&self.rib, route, advertiser, try attrs.clone(attrs.allocator)} },
            .task = .{ .callback = Self.threadPoolCallback }
        };

        self.threadPool.schedule(xev.ThreadPool.Batch.from(&task.task));
    }

    pub fn removePath(self: *Self, route: Route, advertiser: ip.IpAddress) !void {
        const task = try self.allocator.create(RibTask);
        task.* = .{
            .allocator = self.allocator,
            .mutex = &self.ribMutex,
            .operation = .{ .remove = .{&self.rib, route, advertiser} },
            .task = .{ .callback = Self.threadPoolCallback }
        };

        self.threadPool.schedule(xev.ThreadPool.Batch.from(&task.task));
    }
};
