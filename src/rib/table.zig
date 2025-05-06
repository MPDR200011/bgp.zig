const std = @import("std");
const ip = @import("ip");

const model = @import("../messaging/model.zig");

const Route = model.Route;
const PathAttributes = model.PathAttributes;

const RoutePath = struct {
    const Self = @This();

    advertiser: ?ip.IpAddress,

    attrs: PathAttributes,

    fn deinit(self: Self, allocator: std.mem.Allocator) void {
        self.attrs.deinit(allocator);
    }
};

pub const PathMapCtx = struct {
    const Self = @This();

    pub fn hash(_: Self, r: ip.IpAddress) u64 {
        switch (r) {
            .V4 => |v4Route| {
                const hashFn = std.hash_map.getAutoHashFn(ip.IpV4Address, void);
                return hashFn({}, v4Route);
            },
            .V6 => |v6Route| {
                const hashFn = std.hash_map.getAutoHashFn(ip.IpV6Address, void);
                return hashFn({}, v6Route);
            },
        }
    }

    pub fn eql(_: Self, r1: ip.IpAddress, r2: ip.IpAddress) bool {
        return r1.equals(r2);
    }
};

const PathMap = std.HashMap(ip.IpAddress, RoutePath, PathMapCtx, std.hash_map.default_max_load_percentage);

const RibEntry = struct {
    const Self = @This();

    route: Route,

    paths: PathMap,

    pub fn init(allocator: std.mem.Allocator, route: Route) Self {
        return Self{
            .route = route,
            .paths = .init(allocator),
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        var pathsIterator = self.paths.valueIterator();
        while (pathsIterator.next()) |path| {
            path.deinit(allocator);
        }
        self.paths.deinit();
    } 
};

pub const RouteMapCtx = struct {
    const Self = @This();

    pub fn hash(_: Self, r: Route) u64 {
        const hashFn = std.hash_map.getAutoHashFn(Route, void);
        return hashFn({}, r);
    }

    pub fn eql(_: Self, r1: Route, r2: Route) bool {
        return (r1.prefixLength == r2.prefixLength) and (std.mem.eql(u8, &r1.prefixData, &r2.prefixData));
    }
};

const PrefixMap = std.HashMap(Route, RibEntry, RouteMapCtx, std.hash_map.default_max_load_percentage);

pub const Rib = struct {
    const Self = @This();

    mutex: std.Thread.Mutex,
    prefixes: PrefixMap,

    allocator: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) Self {
        return Self{
            .mutex = .{},
            .prefixes = .init(alloc),
            .allocator = alloc,
        };
    }

    pub fn deinit(self: *Self) void {
        var prefixIterator = self.prefixes.valueIterator();
        while (prefixIterator.next()) |prefix| {
            prefix.deinit(self.allocator);
        }
        self.prefixes.deinit();
    }

    pub fn setPath(self: *Self, route: Route, advertiser: ip.IpAddress, attrs: PathAttributes) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const routeRes = try self.prefixes.getOrPut(route);
        if (!routeRes.found_existing) {
            routeRes.value_ptr.* = .init(self.allocator, route);
        }
        const ribEntry = routeRes.value_ptr;

        const res = try ribEntry.paths.getOrPut(advertiser);
        if (res.found_existing) {
            res.value_ptr.attrs.deinit(self.allocator);
            res.value_ptr.attrs = try attrs.clone(self.allocator);
        } else {
            res.value_ptr.* = RoutePath{
                .advertiser = advertiser,
                .attrs = try attrs.clone(self.allocator),
            };
        }
    }

    pub fn removeRoute(self: *Self, route: Route) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const ribEntry = self.prefixes.getPtr(route) orelse return;
        ribEntry.deinit(self.allocator);

        _ = self.prefixes.remove(route);
    }
};

const testing = std.testing;

test "Add Route" {
    var rib: Rib = .init(testing.allocator);
    defer rib.deinit();

    const route: Route = .default;

    try rib.setPath(route, .{ .V4 = .init(127, 0, 0, 1) }, .{.origin = .EGP, .asPath = &[_]model.ASPathSegment{}, .nexthop = ip.IpV4Address.init(127, 0, 0, 1), .localPref = 100, .atomicAggregate = false, .multiExitDiscriminator = null, .aggregator = null});

    const ribEntry = rib.prefixes.getPtr(route) orelse return error.RouteNotPresent;
    try testing.expectEqual(ribEntry.route, Route.default);

    const routePath = ribEntry.paths.getPtr(.{ .V4 = .init(127, 0, 0, 1) }) orelse return error.PathNotFound;
    try testing.expectEqual(routePath.advertiser, ip.IpAddress{ .V4 = .init(127, 0, 0, 1) });

    const attrs: PathAttributes = routePath.attrs;

    try testing.expectEqual(model.Origin.EGP, attrs.origin);
    try testing.expectEqualSlices(model.ASPathSegment, &[_]model.ASPathSegment{}, attrs.asPath);
    try testing.expectEqual(ip.IpV4Address.init(127, 0, 0, 1), attrs.nexthop);

    try testing.expectEqual(100, attrs.localPref);

    try testing.expectEqual(false, attrs.atomicAggregate);
    try testing.expectEqual(null, attrs.multiExitDiscriminator);
    try testing.expectEqual(null, attrs.aggregator);
}

test "Set Route" {
    var rib: Rib = .init(testing.allocator);
    defer rib.deinit();

    const route: Route = .default;

    try rib.setPath(route, .{ .V4 = .init(127, 0, 0, 1) }, .{.origin = .EGP, .asPath = &[_]model.ASPathSegment{}, .nexthop = ip.IpV4Address.init(127, 0, 0, 1), .localPref = 100, .atomicAggregate = false, .multiExitDiscriminator = null, .aggregator = null});
    try rib.setPath(route, .{ .V4 = .init(127, 0, 0, 2) }, .{.origin = .EGP, .asPath = &[_]model.ASPathSegment{}, .nexthop = ip.IpV4Address.init(127, 0, 0, 2), .localPref = 200, .atomicAggregate = true, .multiExitDiscriminator = 69420, .aggregator = null});
    try rib.setPath(route, .{ .V4 = .init(127, 0, 0, 1) }, .{.origin = .EGP, .asPath = &[_]model.ASPathSegment{}, .nexthop = ip.IpV4Address.init(127, 0, 0, 1), .localPref = 142, .atomicAggregate = true, .multiExitDiscriminator = null, .aggregator = null});

    const ribEntry = rib.prefixes.getPtr(route) orelse return error.RouteNotPresent;
    try testing.expectEqual(ribEntry.route, Route.default);
    {
        const routePath = ribEntry.paths.getPtr(.{ .V4 = .init(127, 0, 0, 1) }) orelse return error.PathNotFound;
        try testing.expectEqual(routePath.advertiser, ip.IpAddress{ .V4 = .init(127, 0, 0, 1) });

        const attrs: PathAttributes = routePath.attrs;

        try testing.expectEqual(model.Origin.EGP, attrs.origin);
        try testing.expectEqualSlices(model.ASPathSegment, &[_]model.ASPathSegment{}, attrs.asPath);
        try testing.expectEqual(ip.IpV4Address.init(127, 0, 0, 1), attrs.nexthop);

        try testing.expectEqual(142, attrs.localPref);

        try testing.expectEqual(true, attrs.atomicAggregate);
        try testing.expectEqual(null, attrs.multiExitDiscriminator);
        try testing.expectEqual(null, attrs.aggregator);
    }

    {
        const routePath = ribEntry.paths.getPtr(.{ .V4 = .init(127, 0, 0, 2) }) orelse return error.PathNotFound;
        try testing.expectEqual(routePath.advertiser, ip.IpAddress{ .V4 = .init(127, 0, 0, 2) });

        const attrs: PathAttributes = routePath.attrs;

        try testing.expectEqual(model.Origin.EGP, attrs.origin);
        try testing.expectEqualSlices(model.ASPathSegment, &[_]model.ASPathSegment{}, attrs.asPath);
        try testing.expectEqual(ip.IpV4Address.init(127, 0, 0, 2), attrs.nexthop);

        try testing.expectEqual(200, attrs.localPref);

        try testing.expectEqual(true, attrs.atomicAggregate);
        try testing.expectEqual(69420, attrs.multiExitDiscriminator);
        try testing.expectEqual(null, attrs.aggregator);
    }
}

test "Remove Route" {
    var rib: Rib = .init(testing.allocator);
    defer rib.deinit();

    const route: Route = .default;

    try rib.setPath(route, .{ .V4 = .init(127, 0, 0, 1) }, .{.origin = .EGP, .asPath = &[_]model.ASPathSegment{}, .nexthop = ip.IpV4Address.init(127, 0, 0, 1), .localPref = 100, .atomicAggregate = false, .multiExitDiscriminator = null, .aggregator = null});
    try rib.setPath(route, .{ .V4 = .init(127, 0, 0, 1) }, .{.origin = .EGP, .asPath = &[_]model.ASPathSegment{}, .nexthop = ip.IpV4Address.init(127, 0, 0, 1), .localPref = 142, .atomicAggregate = true, .multiExitDiscriminator = null, .aggregator = null});

    const ribEntry = rib.prefixes.getPtr(route) orelse return error.RouteNotPresent;
    try testing.expectEqual(ribEntry.route, Route.default);
    {
        const routePath = ribEntry.paths.getPtr(.{ .V4 = .init(127, 0, 0, 1) }) orelse return error.PathNotFound;
        try testing.expectEqual(routePath.advertiser, ip.IpAddress{ .V4 = .init(127, 0, 0, 1) });

        const attrs: PathAttributes = routePath.attrs;

        try testing.expectEqual(model.Origin.EGP, attrs.origin);
        try testing.expectEqualSlices(model.ASPathSegment, &[_]model.ASPathSegment{}, attrs.asPath);
        try testing.expectEqual(ip.IpV4Address.init(127, 0, 0, 1), attrs.nexthop);

        try testing.expectEqual(142, attrs.localPref);

        try testing.expectEqual(true, attrs.atomicAggregate);
        try testing.expectEqual(null, attrs.multiExitDiscriminator);
        try testing.expectEqual(null, attrs.aggregator);
    }

    rib.removeRoute(route);
    try testing.expectEqual(null, rib.prefixes.getPtr(route));
}
