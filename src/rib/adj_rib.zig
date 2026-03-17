const std = @import("std");
const ip = @import("ip");

const model = @import("./model.zig");

const Allocator = std.mem.Allocator;

const Route = model.Route;
const PathAttributes = model.PathAttributes;

pub const Advertiser = union(enum) {
    self,
    neighbor: ip.IpAddress,

    pub fn equals(self: Advertiser, other: Advertiser) bool {
        switch (self) {
            .self => return other == .self,
            .neighbor => |ip1| switch (other) {
                .self => return false,
                .neighbor => |ip2| return ip1.equals(ip2),
            },
        }
    }
};

pub const AdjRibPath = struct {
    const Self = @This();

    advertiser: Advertiser,
    attrs: PathAttributes,

    pub fn deinit(self: *Self) void {
        self.attrs.deinit();
    }

    pub fn clone(self: *const Self, alloc: Allocator) !Self {
        return .{
            .advertiser = self.advertiser,
            .attrs = try self.attrs.clone(alloc),
        };
    }
};

const RouteMapCtx = struct {
    const Self = @This();

    pub fn hash(_: Self, r: Route) u64 {
        const hashFn = std.hash_map.getAutoHashFn(Route, void);
        return hashFn({}, r);
    }

    pub fn eql(_: Self, r1: Route, r2: Route) bool {
        return (r1.prefixLength == r2.prefixLength) and (std.mem.eql(u8, &r1.prefixData, &r2.prefixData));
    }
};

const PrefixMap = std.HashMap(Route, AdjRibPath, RouteMapCtx, std.hash_map.default_max_load_percentage);

pub const AdjRib = struct {
    const Self = @This();

    prefixes: PrefixMap,
    allocator: Allocator,

    pub fn init(alloc: Allocator) Self {
        return Self{
            .prefixes = .init(alloc),
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

    pub fn setPath(self: *Self, route: Route, advertiser: Advertiser, attrs: PathAttributes) !void {
        const routeRes = try self.prefixes.getOrPut(route);
        if (routeRes.found_existing) {
            routeRes.value_ptr.deinit();
        }
        routeRes.value_ptr.* = .{ .advertiser = advertiser, .attrs = try attrs.clone(attrs.allocator) };
    }

    pub fn removePath(self: *Self, route: Route) void {
        const routeRes = self.prefixes.getPtr(route);
        routeRes.?.deinit();
        const res = self.prefixes.remove(route);
        std.debug.assert(res);
    }
};

const testing = std.testing;

test "Add Route" {
    var adjRib: AdjRib = .init(testing.allocator);
    defer adjRib.deinit();

    const route: Route = .default;

    try adjRib.setPath(route, .{ .neighbor = .{ .V4 = .init(127, 0, 0, 1) } }, .{ .allocator = testing.allocator, .origin = .init(.EGP), .asPath = .init(.createEmpty(testing.allocator)), .nexthop = .init(.{ .Address = ip.IpV4Address.init(127, 0, 0, 1) }), .localPref = .init(100), .atomicAggregate = .init(false), .multiExitDiscriminator = null, .aggregator = null });

    const path = adjRib.prefixes.getPtr(route) orelse return error.RouteNotPresent;

    const attrs: PathAttributes = path.attrs;

    try testing.expectEqual(model.Origin.EGP, attrs.origin.value);
    try testing.expectEqualSlices(model.ASPathSegment, &[_]model.ASPathSegment{}, attrs.asPath.value.segments);
    try testing.expectEqual(ip.IpV4Address.init(127, 0, 0, 1), attrs.nexthop.value.Address);

    try testing.expectEqual(100, attrs.localPref.value);

    try testing.expectEqual(false, attrs.atomicAggregate.?.value);
    try testing.expectEqual(null, attrs.multiExitDiscriminator);
    try testing.expectEqual(null, attrs.aggregator);
}

test "Set Route" {
    var adjRib: AdjRib = .init(testing.allocator);
    defer adjRib.deinit();

    const route: Route = .default;

    const asPathSegments = seg: {
        const segments = try testing.allocator.alloc(model.ASPathSegment, 3);
        for (segments, 0..) |*s, i| {
            s.* = .{ .allocator = testing.allocator, .segType = .AS_Set, .contents = try testing.allocator.dupe(u16, &[_]u16{@intCast(i)}) };
        }
        break :seg segments;
    };
    const asPath: model.ASPath = .{
        .allocator = testing.allocator,
        .segments = asPathSegments,
    };
    defer asPath.deinit();

    try adjRib.setPath(route, .{ .neighbor = .{ .V4 = .init(127, 0, 0, 1) } }, .{ .allocator = testing.allocator, .origin = .init(.EGP), .asPath = .init(asPath), .nexthop = .init(.{ .Address = ip.IpV4Address.init(127, 0, 0, 1) }), .localPref = .init(100), .atomicAggregate = .init(false), .multiExitDiscriminator = null, .aggregator = null });
    try adjRib.setPath(route, .{ .neighbor = .{ .V4 = .init(127, 0, 0, 1) } }, .{ .allocator = testing.allocator, .origin = .init(.EGP), .asPath = .init(asPath), .nexthop = .init(.{ .Address = ip.IpV4Address.init(127, 0, 0, 2) }), .localPref = .init(200), .atomicAggregate = .init(true), .multiExitDiscriminator = .init(69420), .aggregator = null });
    try adjRib.setPath(route, .{ .neighbor = .{ .V4 = .init(127, 0, 0, 1) } }, .{ .allocator = testing.allocator, .origin = .init(.EGP), .asPath = .init(asPath), .nexthop = .init(.{ .Address = ip.IpV4Address.init(127, 0, 0, 3) }), .localPref = .init(142), .atomicAggregate = .init(true), .multiExitDiscriminator = null, .aggregator = null });

    const path = adjRib.prefixes.getPtr(route) orelse return error.RouteNotPresent;

    const attrs: PathAttributes = path.attrs;

    try testing.expectEqual(model.Origin.EGP, attrs.origin.value);
    try testing.expect(asPath.equal(&attrs.asPath.value));
    try testing.expectEqual(ip.IpV4Address.init(127, 0, 0, 3), attrs.nexthop.value.Address);

    try testing.expectEqual(142, attrs.localPref.value);

    try testing.expectEqual(true, attrs.atomicAggregate.?.value);
    try testing.expectEqual(null, attrs.multiExitDiscriminator);
    try testing.expectEqual(null, attrs.aggregator);
}

test "Remove Path" {
    var adjRib: AdjRib = .init(testing.allocator);
    defer adjRib.deinit();

    const route: Route = .default;

    try adjRib.setPath(route, .{ .neighbor = .{ .V4 = .init(127, 0, 0, 1) } }, .{ .allocator = testing.allocator, .origin = .init(.EGP), .asPath = .init(.createEmpty(testing.allocator)), .nexthop = .init(.{ .Address = ip.IpV4Address.init(127, 0, 0, 1) }), .localPref = .init(100), .atomicAggregate = null, .multiExitDiscriminator = null, .aggregator = null });
    adjRib.removePath(route);

    try testing.expectEqual(null, adjRib.prefixes.getPtr(route));
}
