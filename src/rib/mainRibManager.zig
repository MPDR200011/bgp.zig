const std = @import("std");
const ip = @import("ip");

const rib = @import("mainRib.zig");
const debounced = @import("../utils/debounced.zig");
const model = @import("../messaging/model.zig");

const Allocator = std.mem.Allocator;

const Rib = rib.Rib;

const Route = model.Route;
const PathAttributes = model.PathAttributes;

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

        try self.rib.setPath(route, advertiser, try attrs.clone(attrs.allocator));
    }

    pub fn removePath(self: *Self, route: Route, advertiser: ip.IpAddress) !void {
        self.ribMutex.lock();
        defer self.ribMutex.unlock();

        _ = self.rib.removePath(route, advertiser);
    }
};
