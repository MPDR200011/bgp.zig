const std = @import("std");
const ip = @import("ip");

const rib = @import("table.zig");
const debounced = @import("../utils/debounced.zig");
const model = @import("../messaging/model.zig");

const Allocator = std.mem.Allocator;

const Rib = rib.Rib;

const Route = model.Route;
const PathAttributes = model.PathAttributes;

const Operation = union(enum) {
    add: std.meta.Tuple(&[_]type{*Rib, Route, ip.IpAddress, PathAttributes}),
    remove: std.meta.Tuple(&[_]type{*Rib, Route, ip.IpAddress})
};

const TaskArgs = std.meta.Tuple(&[_]type{*RibManager, Operation});

const RibUpdateTask = debounced.AccumulatingDebouncedTask(TaskArgs);

pub const RibManager = struct {
    const Self = @This();

    allocator: Allocator,

    ribMutex: std.Thread.Mutex,
    rib: Rib,

    // subcribers (sessions that need to announce updates)
    // worker (processing updates should be async)

    pub fn init(alloc: Allocator) !Self {
        return Self{
            .allocator = alloc,
            .ribMutex = .{},
            .rib = .init(alloc),
        };
    }

    pub fn deinit(self: Self) Self {
        self.rib.deinit();
    }

    pub fn setPath(self: *Self, route: Route, advertiser: ip.IpAddress, attrs: PathAttributes) !void {
        self.ribMutex.lock();
        defer self.ribMutex.unlock();

        try self.rib.setPath(route, advertiser, try attrs.clone(self.allocator));
    }

    pub fn removePath(self: *Self, route: Route, advertiser: ip.IpAddress) !void {
        self.ribMutex.lock();
        defer self.ribMutex.unlock();

        _ = self.rib.removePath(route, advertiser);
    }
};
