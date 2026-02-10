const std = @import("std");
const ip = @import("ip");

const model = @import("../messaging/model.zig");

const common = @import("./common.zig");

const Allocator = std.mem.Allocator;

const Route = model.Route;
const PathAttributes = model.PathAttributes;

const RoutePath = common.RoutePath;
const Advertiser = common.Advertiser;
const RouteMapCtx = common.RouteHashFns;

pub const PathMapCtx = struct {
    const Self = @This();

    pub fn hash(_: Self, r: Advertiser) u64 {
        switch (r) {
            .self => {
                return 0; // Or some other constant hash for self
            },
            .neighbor => |neighbor| {
                switch (neighbor) {
                    .V4 => |v4Route| {
                        const hashFn = std.hash_map.getAutoHashFn(ip.IpV4Address, void);
                        return hashFn({}, v4Route);
                    },
                    .V6 => |v6Route| {
                        const hashFn = std.hash_map.getAutoHashFn(ip.IpV6Address, void);
                        return hashFn({}, v6Route);
                    },
                }
            },
        }
    }

    pub fn eql(_: Self, r1: Advertiser, r2: Advertiser) bool {
        return r1.equals(r2);
    }
};

const PathMap = std.HashMap(Advertiser, RoutePath, PathMapCtx, std.hash_map.default_max_load_percentage);

const RibEntry = struct {
    const Self = @This();

    allocator: Allocator,
    route: Route,

    bestPath: ?Advertiser,
    paths: PathMap,

    pub fn init(allocator: Allocator, route: Route) Self {
        return Self{
            .allocator = allocator,
            .route = route,
            .bestPath = null,
            .paths = .init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var pathsIterator = self.paths.valueIterator();
        while (pathsIterator.next()) |path| {
            path.deinit();
        }
        self.paths.deinit();
    }

    pub fn addPath(self: *Self, advertiser: Advertiser, attrs: PathAttributes) !void {
        if (self.paths.count() == 0) {
            std.debug.assert(self.bestPath == null);
            self.bestPath = advertiser;
        }

        const res = try self.paths.getOrPut(advertiser);
        if (res.found_existing) {
            res.value_ptr.attrs.deinit();
            res.value_ptr.attrs = try attrs.clone(self.allocator);
        } else {
            res.value_ptr.* = RoutePath{
                .advertiser = advertiser,
                .attrs = try attrs.clone(self.allocator),
            };
        }
    }

    pub fn removePath(self: *Self, advertiser: Advertiser) void {
        if (self.bestPath != null and self.bestPath.?.equals(advertiser)) {
            // FIXME: this might be dangerous... be it'll happen when the main
            // rib is locked by the time the lock is lifted this best path
            // should be pointing to the correct thing
            self.bestPath = null;
        }

        const path = self.paths.getPtr(advertiser) orelse return;

        path.deinit();
        _ = self.paths.remove(advertiser);
    }
};

const PrefixMap = std.HashMap(Route, RibEntry, RouteMapCtx, std.hash_map.default_max_load_percentage);

pub const Rib = struct {
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
        var prefixIterator = self.prefixes.valueIterator();
        while (prefixIterator.next()) |prefix| {
            prefix.deinit();
        }
        self.prefixes.deinit();
    }

    pub fn setPath(self: *Self, route: Route, advertiser: Advertiser, attrs: PathAttributes) !void {
        const routeRes = try self.prefixes.getOrPut(route);
        if (!routeRes.found_existing) {
            routeRes.value_ptr.* = .init(self.allocator, route);
        }
        const ribEntry = routeRes.value_ptr;

        try ribEntry.addPath(advertiser, attrs);
    }

    pub fn removePath(self: *Self, route: Route, advertiser: Advertiser) bool {
        const ribEntry = self.prefixes.getPtr(route) orelse return false;
        ribEntry.removePath(advertiser);

        if (ribEntry.paths.count() == 0) {
            ribEntry.deinit();
            _ = self.prefixes.remove(route);

            return true;
        } else {
            return false;
        }
    }
};

const testing = std.testing;
const t = testing;

test "Add Route" {
    var rib: Rib = .init(testing.allocator);
    defer rib.deinit();

    const route: Route = .default;

    try rib.setPath(route, .{ .neighbor = .{ .V4 = .init(127, 0, 0, 1) } }, .{ .allocator = t.allocator, .origin = .init(.EGP), .asPath = .init(.createEmpty(t.allocator)), .nexthop = .init(ip.IpV4Address.init(127, 0, 0, 1)), .localPref = .init(100), .atomicAggregate = null, .multiExitDiscriminator = null, .aggregator = null });

    const ribEntry = rib.prefixes.getPtr(route) orelse return error.RouteNotPresent;
    try testing.expectEqual(ribEntry.route, Route.default);

    const routePath = ribEntry.paths.getPtr(.{ .neighbor = .{ .V4 = .init(127, 0, 0, 1) } }) orelse return error.PathNotFound;
    try testing.expect(routePath.advertiser.equals(.{ .neighbor = .{ .V4 = .init(127, 0, 0, 1) } }));

    const attrs: PathAttributes = routePath.attrs;

    try testing.expectEqual(model.Origin.EGP, attrs.origin);
    try testing.expectEqualSlices(model.ASPathSegment, &[_]model.ASPathSegment{}, attrs.asPath.segments);
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

    try rib.setPath(route, .{ .neighbor = .{ .V4 = .init(127, 0, 0, 1) } }, .{ .allocator = t.allocator, .origin = .init(.EGP), .asPath = .init(asPath), .nexthop = .init(ip.IpV4Address.init(127, 0, 0, 1)), .localPref = .init(100), .atomicAggregate = null, .multiExitDiscriminator = null, .aggregator = null });
    try rib.setPath(route, .{ .neighbor = .{ .V4 = .init(127, 0, 0, 2) } }, .{ .allocator = t.allocator, .origin = .init(.EGP), .asPath = .init(asPath), .nexthop = .init(ip.IpV4Address.init(127, 0, 0, 2)), .localPref = .init(200), .atomicAggregate = null, .multiExitDiscriminator = .init(69420), .aggregator = null });
    try rib.setPath(route, .{ .neighbor = .{ .V4 = .init(127, 0, 0, 1) } }, .{ .allocator = t.allocator, .origin = .init(.EGP), .asPath = .init(asPath), .nexthop = .init(ip.IpV4Address.init(127, 0, 0, 1)), .localPref = .init(142), .atomicAggregate = null, .multiExitDiscriminator = null, .aggregator = null });

    const ribEntry = rib.prefixes.getPtr(route) orelse return error.RouteNotPresent;
    try testing.expectEqual(ribEntry.route, Route.default);
    {
        const routePath = ribEntry.paths.getPtr(.{ .neighbor = .{ .V4 = .init(127, 0, 0, 1) } }) orelse return error.PathNotFound;
        try testing.expect(routePath.advertiser.equals(.{ .neighbor = .{ .V4 = .init(127, 0, 0, 1) } }));

        const attrs: PathAttributes = routePath.attrs;

        try testing.expectEqual(model.Origin.EGP, attrs.origin);
        try testing.expect(asPath.equal(&attrs.asPath));
        try testing.expectEqual(ip.IpV4Address.init(127, 0, 0, 1), attrs.nexthop);

        try testing.expectEqual(142, attrs.localPref);

        try testing.expectEqual(true, attrs.atomicAggregate);
        try testing.expectEqual(null, attrs.multiExitDiscriminator);
        try testing.expectEqual(null, attrs.aggregator);
    }

    {
        const routePath = ribEntry.paths.getPtr(.{ .neighbor = .{ .V4 = .init(127, 0, 0, 2) } }) orelse return error.PathNotFound;
        try testing.expect(routePath.advertiser.equals(.{ .neighbor = .{ .V4 = .init(127, 0, 0, 2) } }));

        const attrs: PathAttributes = routePath.attrs;

        try testing.expectEqual(model.Origin.EGP, attrs.origin);
        try testing.expect(asPath.equal(&attrs.asPath));
        try testing.expectEqual(ip.IpV4Address.init(127, 0, 0, 2), attrs.nexthop);

        try testing.expectEqual(200, attrs.localPref);

        try testing.expectEqual(true, attrs.atomicAggregate);
        try testing.expectEqual(69420, attrs.multiExitDiscriminator);
        try testing.expectEqual(null, attrs.aggregator);
    }
}

test "Remove Path" {
    var rib: Rib = .init(testing.allocator);
    defer rib.deinit();

    const route: Route = .default;

    try rib.setPath(route, .{ .neighbor = .{ .V4 = .init(127, 0, 0, 1) } }, .{ .allocator = t.allocator, .origin = .init(.EGP), .asPath = .init(.createEmpty(t.allocator)), .nexthop = .init(ip.IpV4Address.init(0, 0, 0, 0)), .localPref = .init(100), .atomicAggregate = null, .multiExitDiscriminator = null, .aggregator = null });
    try rib.setPath(route, .{ .neighbor = .{ .V4 = .init(127, 0, 0, 2) } }, .{ .allocator = t.allocator, .origin = .init(.EGP), .asPath = .init(.createEmpty(t.allocator)), .nexthop = .init(ip.IpV4Address.init(0, 0, 0, 0)), .localPref = .init(100), .atomicAggregate = null, .multiExitDiscriminator = null, .aggregator = null });

    try testing.expectEqual(false, rib.removePath(route, .{ .neighbor = .{ .V4 = .init(127, 0, 0, 1) } }));

    const ribEntry = rib.prefixes.getPtr(route) orelse return error.ExpectedNonNull;

    try testing.expectEqual(1, ribEntry.paths.count());

    const path = ribEntry.paths.getPtr(.{ .neighbor = .{ .V4 = .init(127, 0, 0, 2) } }) orelse return error.ExpectedNonNull;

    try testing.expect(path.advertiser.equals(.{ .neighbor = .{ .V4 = .init(127, 0, 0, 2) } }));

    try testing.expectEqual(true, rib.removePath(route, .{ .neighbor = .{ .V4 = .init(127, 0, 0, 2) } }));

    try testing.expectEqual(null, rib.prefixes.getPtr(route));
}

test "Self Advertiser" {
    var rib: Rib = .init(testing.allocator);
    defer rib.deinit();

    const route: Route = .default;
    const attrs = model.PathAttributes{
        .allocator = testing.allocator,
        .origin = .IGP,
        .asPath = .createEmpty(testing.allocator),
        .nexthop = ip.IpV4Address.init(127, 0, 0, 1),
        .localPref = 100,
        .atomicAggregate = false,
        .multiExitDiscriminator = null,
        .aggregator = null,
    };

    try rib.setPath(route, .self, attrs);

    const ribEntry = rib.prefixes.getPtr(route) orelse return error.RouteNotPresent;
    const routePath = ribEntry.paths.getPtr(.self) orelse return error.PathNotFound;

    try testing.expect(routePath.advertiser == .self);
    try testing.expectEqual(model.Origin.IGP, routePath.attrs.origin);

    try testing.expectEqual(true, rib.removePath(route, .self));
}
