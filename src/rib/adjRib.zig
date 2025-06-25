const std = @import("std");
const ip = @import("ip");

const model = @import("../messaging/model.zig");

const common = @import("./common.zig");

const Allocator = std.mem.Allocator;

const RoutePath = common.RoutePath;

const Route = model.Route;
const PathAttributes = model.PathAttributes;

const RouteMapCtx = common.RouteHashFns;

const PrefixMap = std.HashMap(Route, RoutePath, RouteMapCtx, std.hash_map.default_max_load_percentage);

pub const AdjRib = struct {
    const Self = @This();

    prefixes: PrefixMap,
    advertiser: ip.IpAddress,

    allocator: Allocator,

    pub fn init(advertiser: ip.IpAddress, alloc: Allocator) Self {
        return Self{
            .prefixes = .init(alloc),
            .advertiser = advertiser,
            .allocator = alloc,
        };
    }

    pub fn deinit(self: *Self) void {
        var pathIterator = self.prefixes.valueIterator();
        while (pathIterator.next()) |path| {
            path.deinit();
        }
        self.prefixes.deinit();
    }

    pub fn setPath(self: *Self, route: Route, attrs: PathAttributes) !void {
        const routeRes = try self.prefixes.getOrPut(route);
        if (routeRes.found_existing) {
            routeRes.value_ptr.deinit();
        }
        routeRes.value_ptr.* = .{
            .advertiser = self.advertiser,
            .attrs = try attrs.clone(attrs.allocator)
        };
    }

    pub fn removePath(self: *Self, route: Route) void {
        const res = self.prefixes.remove(route);
        std.debug.assert(res);
    }
};

const testing = std.testing;

test "Add Route" {
    var adjRib: AdjRib = .init(.{ .V4 = .init(127, 0, 0, 1) }, testing.allocator);
    defer adjRib.deinit();

    const route: Route = .default;

    try adjRib.setPath(route, .{.allocator = testing.allocator, .origin = .EGP, .asPath = .createEmpty(testing.allocator), .nexthop = ip.IpV4Address.init(127, 0, 0, 1), .localPref = 100, .atomicAggregate = false, .multiExitDiscriminator = null, .aggregator = null});

    const path = adjRib.prefixes.getPtr(route) orelse return error.RouteNotPresent;

    const attrs: PathAttributes = path.attrs;

    try testing.expectEqual(model.Origin.EGP, attrs.origin);
    try testing.expectEqualSlices(model.ASPathSegment, &[_]model.ASPathSegment{}, attrs.asPath.segments);
    try testing.expectEqual(ip.IpV4Address.init(127, 0, 0, 1), attrs.nexthop);

    try testing.expectEqual(100, attrs.localPref);

    try testing.expectEqual(false, attrs.atomicAggregate);
    try testing.expectEqual(null, attrs.multiExitDiscriminator);
    try testing.expectEqual(null, attrs.aggregator);
}

test "Set Route" {
    var adjRib: AdjRib = .init(.{ .V4 = .init(127, 0, 0, 1) }, testing.allocator);
    defer adjRib.deinit();

    const route: Route = .default;

    const asPathSegments = seg: {
        const segments = try testing.allocator.alloc(model.ASPathSegment, 3);
        for (segments, 0..) |*s, i| {
            s.* = .{.allocator = testing.allocator, .segType = .AS_Set, .contents = try testing.allocator.dupe(u16, &[_]u16{@intCast(i)}) };
        }
        break :seg segments;
    };
    const asPath: model.ASPath = .{
        .allocator = testing.allocator,
        .segments = asPathSegments,
    };
    defer asPath.deinit();

    try adjRib.setPath(route, .{.allocator = testing.allocator, .origin = .EGP, .asPath = asPath, .nexthop = ip.IpV4Address.init(127, 0, 0, 1), .localPref = 100, .atomicAggregate = false, .multiExitDiscriminator = null, .aggregator = null});
    try adjRib.setPath(route, .{.allocator = testing.allocator, .origin = .EGP, .asPath = asPath, .nexthop = ip.IpV4Address.init(127, 0, 0, 2), .localPref = 200, .atomicAggregate = true, .multiExitDiscriminator = 69420, .aggregator = null});
    try adjRib.setPath(route, .{.allocator = testing.allocator, .origin = .EGP, .asPath = asPath, .nexthop = ip.IpV4Address.init(127, 0, 0, 3), .localPref = 142, .atomicAggregate = true, .multiExitDiscriminator = null, .aggregator = null});

    const path = adjRib.prefixes.getPtr(route) orelse return error.RouteNotPresent;

    const attrs: PathAttributes = path.attrs;

    try testing.expectEqual(model.Origin.EGP, attrs.origin);
    try testing.expect(asPath.equal(attrs.asPath));
    try testing.expectEqual(ip.IpV4Address.init(127, 0, 0, 3), attrs.nexthop);

    try testing.expectEqual(142, attrs.localPref);

    try testing.expectEqual(true, attrs.atomicAggregate);
    try testing.expectEqual(null, attrs.multiExitDiscriminator);
    try testing.expectEqual(null, attrs.aggregator);
}

test "Remove Path" {
    var adjRib: AdjRib = .init(.{ .V4 = .init(127, 0, 0, 1) }, testing.allocator);
    defer adjRib.deinit();

    const route: Route = .default;

    try adjRib.setPath(route, .{.allocator = testing.allocator, .origin = .EGP, .asPath = .createEmpty(testing.allocator), .nexthop = ip.IpV4Address.init(127, 0, 0, 1), .localPref = 100, .atomicAggregate = false, .multiExitDiscriminator = null, .aggregator = null});
    adjRib.removePath(route);

    try testing.expectEqual(null, adjRib.prefixes.getPtr(route));
}
