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
const Advertiser = common.Advertiser;

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
            else => {},
        }
    }
};

pub const OutAdjRibCallback = struct {
    peerId: ip.IpAddress,
    callback: *const fn (*OutAdjRibCallback, *const Operation) void,

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

    pub fn init(alloc: Allocator) !Self {
        return Self{
            .allocator = alloc,
            .ribMutex = .{},
            .rib = .init(alloc),
        };
    }

    pub fn deinit(self: *Self) void {
        self.ribMutex.lock();
        defer self.ribMutex.unlock();

        self.rib.deinit();
    }

    pub fn setPath(self: *Self, route: Route, advertiserAddress: Advertiser, attrs: PathAttributes) !void {
        self.ribMutex.lock();
        defer self.ribMutex.unlock();

        try self.rib.setPath(route, advertiserAddress, attrs);
    }

    pub fn removePath(self: *Self, route: Route, advertiserAddress: Advertiser) !bool {
        self.ribMutex.lock();
        defer self.ribMutex.unlock();

        return self.rib.removePath(route, advertiserAddress);
    }
};
