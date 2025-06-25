const std = @import("std");
const ip = @import("ip");

const model = @import("../messaging/model.zig");

const Allocator = std.mem.Allocator;

const PathAttributes = model.PathAttributes;
const Route = model.Route;

pub const RoutePath = struct {
    const Self = @This();

    advertiser: ?ip.IpAddress,

    attrs: PathAttributes,

    pub fn deinit(self: Self) void {
        self.attrs.deinit();
    }
};

pub const RouteHashFns = struct {
    const Self = @This();

    pub fn hash(_: Self, r: Route) u64 {
        const hashFn = std.hash_map.getAutoHashFn(Route, void);
        return hashFn({}, r);
    }

    pub fn eql(_: Self, r1: Route, r2: Route) bool {
        return (r1.prefixLength == r2.prefixLength) and (std.mem.eql(u8, &r1.prefixData, &r2.prefixData));
    }
};


