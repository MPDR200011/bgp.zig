const std = @import("std");
const ip = @import("ip");

const adjRib = @import("adjRib.zig");
const debounced = @import("../utils/debounced.zig");
const model = @import("../messaging/model.zig");

const Allocator = std.mem.Allocator;

const AdjRib = adjRib.AdjRib;

const Route = model.Route;
const PathAttributes = model.PathAttributes;

pub const Subscription = struct {
    callback: *const fn(*Subscription, *Update) void,
};
pub const Update = struct {
    // adds, removes, attrs
};

pub const AdjRibManager = struct {
    const Self = @This();

    allocator: Allocator,

    ribMutex: std.Thread.Mutex,

    neighbor: ip.IpAddress,
    adjRib: AdjRib,

    subscription: *Subscription,

    // subcribers (sessions that need to announce updates)
    // worker (processing updates should be async)

    pub fn init(alloc: Allocator, neighbor: ip.IpAddress, subscription: *Subscription) !Self {
        return Self{
            .allocator = alloc,
            .ribMutex = .{},
            .neighbor = neighbor,
            .adjRib = .init(neighbor, alloc),
            .subscription = subscription
        };
    }

    pub fn deinit(self: Self) Self {
        self.adjRib.deinit();
    }

    pub fn setPath(self: *Self, route: Route, attrs: PathAttributes) !void {
        self.ribMutex.lock();
        defer self.ribMutex.unlock();

        try self.adjRib.setPath(route, attrs);
    }

    pub fn removePath(self: *Self, route: Route) !void {
        self.ribMutex.lock();
        defer self.ribMutex.unlock();

        self.adjRib.removePath(route);
    }
};
