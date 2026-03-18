const std = @import("std");
const ip = @import("ip");

const model = @import("./model.zig");

const Allocator = std.mem.Allocator;

const Route = model.Route;
const PathAttributes = model.PathAttributes;
const ASNumber = model.ASNumber;
const ASPath = model.ASPath;

pub const SessionType = enum {
    EBGP,
    IBGP
};

pub const MainRibAdvertiser = union(enum) {
    self: struct {
        localAsn: model.ASNumber,
    },
    neighbor: struct {
        neighborIp: ip.IpAddress,
        peerId: u32,
        localAsn: model.ASNumber,
        sessionType: SessionType
    },

    pub fn equals(self: MainRibAdvertiser, other: MainRibAdvertiser) bool {
        switch (self) {
            .self => return other == .self,
            .neighbor => |n1| switch (other) {
                .self => return false,
                .neighbor => |n2| return n1.neighborIp.equals(n2.neighborIp),
            },
        }
    }
};

/// Lexicographical comparison of addresses
/// > 0 => a1 > a2
/// < 0 => a1 < a2
/// = 0 => Tie
fn compareAddresses(a1: ip.IpAddress, a2: ip.IpAddress) i32 {
    // The AFIs should never be different, the program should never reach a
    // point where this happens.
    std.debug.assert(std.meta.activeTag(a1) == std.meta.activeTag(a2));

    switch (a1) {
        .V4 => {
            for (0..a1.V4.address.len) |i| {
                const diff = @as(i32, @intCast(a1.V4.address[i])) - @as(i32, @intCast(a2.V4.address[i]));
                if (diff == 0) {
                    continue;
                }
                return diff;
            }
        },
        .V6 => {
            for (0..a1.V6.address.len) |i| {
                const diff = @as(i32, @intCast(a1.V6.address[i])) - @as(i32, @intCast(a2.V6.address[i]));
                if (diff == 0) {
                    continue;
                }
                return diff;
            }
        },
    }
    return 0;
}

pub const MainRibPath = struct {
    const Self = @This();

    advertiser: MainRibAdvertiser,
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

    pub fn neighboringAS(self: *const Self) ASNumber {
        const asPath = &self.attrs.asPath.value;
        switch (self.advertiser) {
            .self => |originationInfo| {
                return originationInfo.localAsn;
            },
            .neighbor => |neighbor| {
                switch (neighbor.sessionType) {
                    .EBGP => {
                        std.debug.assert(asPath.segments.len > 0);
                        const firstSegment = asPath.segments[0];

                        std.debug.assert(firstSegment.segType == .AS_Sequence);
                        return firstSegment.contents[0];
                    },
                    .IBGP => {
                        if (asPath.segments.len == 0) {
                            return neighbor.localAsn;
                        } else {
                            if (asPath.segments[0].segType == .AS_Set) {
                                return neighbor.localAsn;
                            }
                            return asPath.segments[0].contents[0];
                        }
                    },
                }
            },
        }
    }

    pub fn getMED(self: *const Self) u32 {
        const med = self.attrs.multiExitDiscriminator orelse return 0;
        return med.value;
    }

    /// > 0 => self is more prefered than other
    /// < 0 => self is less prefered than other
    /// = 0 => Tie
    pub fn cmp(self: *const Self, other: *const Self) i32 {
        // LPREF
        {
            const sLPref = self.attrs.localPref.value;
            const oLPref = other.attrs.localPref.value;

            if (sLPref > oLPref) {
                return 1;
            } else if (sLPref < oLPref) {
                return -1;
            }
        }

        {
            // AS Path
            const sLPathLen = self.attrs.asPath.value.len();
            const oLPathLen = other.attrs.asPath.value.len();
            if (sLPathLen < oLPathLen) {
                return 1;
            } else if (sLPathLen > oLPathLen) {
                return -1;
            }
        }

        // ORIGIN
        const originComp = @intFromEnum(other.attrs.origin.value) - @intFromEnum(self.attrs.origin.value);
        if (originComp != 0) {
            return originComp;
        }

        // Compare MEDs if neighbouring AS is the same
        // FIXME should handle IBGP
        if (self.neighboringAS() == other.neighboringAS()) {
            const sMed = self.getMED();
            const oMed = other.getMED();
            if (sMed < oMed) {
                return 1;
            } else if (sMed > oMed) {
                return -1;
            }
        }

        switch (self.advertiser) {
            .self => {
                // There shouldn't be two originations of the same route
                std.debug.assert(std.meta.activeTag(other.advertiser) != .self);
                return 1;
            },
            .neighbor => |n1| {
                switch (other.advertiser) {
                    .self => {
                        return -1;
                    },
                    .neighbor => |n2| {
                        // EBGP > IBGP
                        if (n1.sessionType == .EBGP) {
                            if (n2.sessionType == .IBGP) {
                                return 1;
                            }
                        } else {
                            if (n2.sessionType == .EBGP) {
                                return -1;
                            }
                        }

                        // Lowest peer id wins
                        if (n1.peerId < n2.peerId) {
                            return 1;
                        } else if (n1.peerId > n2.peerId) {
                            return -1;
                        }

                        // Lowest peer address wins
                        const diff = compareAddresses(n2.neighborIp, n1.neighborIp);
                        if (diff != 0) {
                            return diff;
                        }
                    },
                }
            },
        }

        // TODO: some vendor implementations tie break based on path age, should look into that
        return 0;
    }
};

const MainRibAdvertiserMapCtx = struct {
    const Self = @This();

    pub fn hash(_: Self, r: MainRibAdvertiser) u64 {
        switch (r) {
            .self => {
                return 0;
            },
            .neighbor => |neighbor| {
                switch (neighbor.neighborIp) {
                    .V4 => |v4| {
                        const hashFn = std.hash_map.getAutoHashFn(ip.IpV4Address, void);
                        return hashFn({}, v4);
                    },
                    .V6 => |v6| {
                        const hashFn = std.hash_map.getAutoHashFn(ip.IpV6Address, void);
                        return hashFn({}, v6);
                    },
                }
            },
        }
    }

    pub fn eql(_: Self, r1: MainRibAdvertiser, r2: MainRibAdvertiser) bool {
        return r1.equals(r2);
    }
};

const PathMap = std.HashMap(MainRibAdvertiser, MainRibPath, MainRibAdvertiserMapCtx, std.hash_map.default_max_load_percentage);

const RibEntry = struct {
    const Self = @This();

    allocator: Allocator,
    route: Route,

    bestPath: ?MainRibAdvertiser,
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

    pub fn addPath(self: *Self, advertiser: MainRibAdvertiser, attrs: PathAttributes) !void {
        if (self.paths.count() == 0) {
            std.debug.assert(self.bestPath == null);
            self.bestPath = advertiser;
        }

        const res = try self.paths.getOrPut(advertiser);
        if (res.found_existing) {
            res.value_ptr.attrs.deinit();
            res.value_ptr.attrs = try attrs.clone(self.allocator);
        } else {
            res.value_ptr.* = MainRibPath{
                .advertiser = advertiser,
                .attrs = try attrs.clone(self.allocator),
            };
        }
    }

    pub fn removePath(self: *Self, advertiser: MainRibAdvertiser) void {
        if (self.bestPath != null and self.bestPath.?.equals(advertiser)) {
            self.bestPath = null;
        }

        const path = self.paths.getPtr(advertiser) orelse return;
        path.deinit();

        _ = self.paths.remove(advertiser);
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

    pub fn setPath(self: *Self, route: Route, advertiser: MainRibAdvertiser, attrs: PathAttributes) !void {
        const routeRes = try self.prefixes.getOrPut(route);
        if (!routeRes.found_existing) {
            routeRes.value_ptr.* = .init(self.allocator, route);
        }
        const ribEntry = routeRes.value_ptr;

        try ribEntry.addPath(advertiser, attrs);
    }

    pub fn removePath(self: *Self, route: Route, advertiser: MainRibAdvertiser) bool {
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

    try rib.setPath(route, .{ .neighbor = .{ .neighborIp = .{ .V4 = .init(127, 0, 0, 1) }, .peerId = 1, .localAsn = 65001, .sessionType = .EBGP } }, .{ .allocator = t.allocator, .origin = .init(.EGP), .asPath = .init(.createEmpty(t.allocator)), .nexthop = .init(.{ .Address = ip.IpV4Address.init(127, 0, 0, 1) }), .localPref = .init(100), .atomicAggregate = .init(false), .multiExitDiscriminator = null, .aggregator = null });

    const ribEntry = rib.prefixes.getPtr(route) orelse return error.RouteNotPresent;
    try testing.expectEqual(ribEntry.route, Route.default);

    const routePath = ribEntry.paths.getPtr(.{ .neighbor = .{ .neighborIp = .{ .V4 = .init(127, 0, 0, 1) }, .peerId = 1, .localAsn = 65001, .sessionType = .EBGP } }) orelse return error.PathNotFound;
    try testing.expect(routePath.advertiser.equals(.{ .neighbor = .{ .neighborIp = .{ .V4 = .init(127, 0, 0, 1) }, .peerId = 1, .localAsn = 65001, .sessionType = .EBGP } }));

    const attrs: PathAttributes = routePath.attrs;

    try testing.expectEqual(model.Origin.EGP, attrs.origin.value);
    try testing.expectEqualSlices(model.ASPathSegment, &[_]model.ASPathSegment{}, attrs.asPath.value.segments);
    try testing.expectEqual(ip.IpV4Address.init(127, 0, 0, 1), attrs.nexthop.value.Address);

    try testing.expectEqual(100, attrs.localPref.value);

    try testing.expectEqual(false, attrs.atomicAggregate.?.value);
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

    try rib.setPath(route, .{ .neighbor = .{ .neighborIp = .{ .V4 = .init(127, 0, 0, 1) }, .peerId = 1, .localAsn = 65001, .sessionType = .EBGP } }, .{ .allocator = t.allocator, .origin = .init(.EGP), .asPath = .init(asPath), .nexthop = .init(.{ .Address = ip.IpV4Address.init(127, 0, 0, 1) }), .localPref = .init(100), .atomicAggregate = .init(false), .multiExitDiscriminator = null, .aggregator = null });
    try rib.setPath(route, .{ .neighbor = .{ .neighborIp = .{ .V4 = .init(127, 0, 0, 2) }, .peerId = 2, .localAsn = 65002, .sessionType = .EBGP } }, .{ .allocator = t.allocator, .origin = .init(.EGP), .asPath = .init(asPath), .nexthop = .init(.{ .Address = ip.IpV4Address.init(127, 0, 0, 2) }), .localPref = .init(200), .atomicAggregate = .init(true), .multiExitDiscriminator = .init(69420), .aggregator = null });
    try rib.setPath(route, .{ .neighbor = .{ .neighborIp = .{ .V4 = .init(127, 0, 0, 1) }, .peerId = 1, .localAsn = 65001, .sessionType = .EBGP } }, .{ .allocator = t.allocator, .origin = .init(.EGP), .asPath = .init(asPath), .nexthop = .init(.{ .Address = ip.IpV4Address.init(127, 0, 0, 1) }), .localPref = .init(142), .atomicAggregate = .init(true), .multiExitDiscriminator = null, .aggregator = null });

    const ribEntry = rib.prefixes.getPtr(route) orelse return error.RouteNotPresent;
    try testing.expectEqual(ribEntry.route, Route.default);
    {
        const routePath = ribEntry.paths.getPtr(.{ .neighbor = .{ .neighborIp = .{ .V4 = .init(127, 0, 0, 1) }, .peerId = 1, .localAsn = 65001, .sessionType = .EBGP } }) orelse return error.PathNotFound;
        try testing.expect(routePath.advertiser.equals(.{ .neighbor = .{ .neighborIp = .{ .V4 = .init(127, 0, 0, 1) }, .peerId = 1, .localAsn = 65001, .sessionType = .EBGP } }));

        const attrs: PathAttributes = routePath.attrs;

        try testing.expectEqual(model.Origin.EGP, attrs.origin.value);
        try testing.expect(asPath.equal(&attrs.asPath.value));
        try testing.expectEqual(ip.IpV4Address.init(127, 0, 0, 1), attrs.nexthop.value.Address);

        try testing.expectEqual(142, attrs.localPref.value);

        try testing.expectEqual(true, attrs.atomicAggregate.?.value);
        try testing.expectEqual(null, attrs.multiExitDiscriminator);
        try testing.expectEqual(null, attrs.aggregator);
    }

    {
        const routePath = ribEntry.paths.getPtr(.{ .neighbor = .{ .neighborIp = .{ .V4 = .init(127, 0, 0, 2) }, .peerId = 2, .localAsn = 65002, .sessionType = .EBGP } }) orelse return error.PathNotFound;
        try testing.expect(routePath.advertiser.equals(.{ .neighbor = .{ .neighborIp = .{ .V4 = .init(127, 0, 0, 2) }, .peerId = 2, .localAsn = 65002, .sessionType = .EBGP } }));

        const attrs: PathAttributes = routePath.attrs;

        try testing.expectEqual(model.Origin.EGP, attrs.origin.value);
        try testing.expect(asPath.equal(&attrs.asPath.value));
        try testing.expectEqual(ip.IpV4Address.init(127, 0, 0, 2), attrs.nexthop.value.Address);

        try testing.expectEqual(200, attrs.localPref.value);

        try testing.expectEqual(true, attrs.atomicAggregate.?.value);
        try testing.expectEqual(69420, attrs.multiExitDiscriminator.?.value);
        try testing.expectEqual(null, attrs.aggregator);
    }
}

test "Remove Path" {
    var rib: Rib = .init(testing.allocator);
    defer rib.deinit();

    const route: Route = .default;

    try rib.setPath(route, .{ .neighbor = .{ .neighborIp = .{ .V4 = .init(127, 0, 0, 1) }, .peerId = 1, .localAsn = 65001, .sessionType = .EBGP } }, .{ .allocator = t.allocator, .origin = .init(.EGP), .asPath = .init(.createEmpty(t.allocator)), .nexthop = .init(.{ .Address = ip.IpV4Address.init(0, 0, 0, 0) }), .localPref = .init(100), .atomicAggregate = null, .multiExitDiscriminator = null, .aggregator = null });
    try rib.setPath(route, .{ .neighbor = .{ .neighborIp = .{ .V4 = .init(127, 0, 0, 2) }, .peerId = 2, .localAsn = 65002, .sessionType = .EBGP } }, .{ .allocator = t.allocator, .origin = .init(.EGP), .asPath = .init(.createEmpty(t.allocator)), .nexthop = .init(.{ .Address = ip.IpV4Address.init(0, 0, 0, 0) }), .localPref = .init(100), .atomicAggregate = null, .multiExitDiscriminator = null, .aggregator = null });

    try testing.expectEqual(false, rib.removePath(route, .{ .neighbor = .{ .neighborIp = .{ .V4 = .init(127, 0, 0, 1) }, .peerId = 1, .localAsn = 65001, .sessionType = .EBGP } }));

    const ribEntry = rib.prefixes.getPtr(route) orelse return error.ExpectedNonNull;

    try testing.expectEqual(1, ribEntry.paths.count());

    const path = ribEntry.paths.getPtr(.{ .neighbor = .{ .neighborIp = .{ .V4 = .init(127, 0, 0, 2) }, .peerId = 2, .localAsn = 65002, .sessionType = .EBGP } }) orelse return error.ExpectedNonNull;

    try testing.expect(path.advertiser.equals(.{ .neighbor = .{ .neighborIp = .{ .V4 = .init(127, 0, 0, 2) }, .peerId = 2, .localAsn = 65002, .sessionType = .EBGP } }));

    try testing.expectEqual(true, rib.removePath(route, .{ .neighbor = .{ .neighborIp = .{ .V4 = .init(127, 0, 0, 2) }, .peerId = 2, .localAsn = 65002, .sessionType = .EBGP } }));

    try testing.expectEqual(null, rib.prefixes.getPtr(route));
}

test "Self Advertiser" {
    var rib: Rib = .init(testing.allocator);
    defer rib.deinit();

    const route: Route = .default;
    const attrs = model.PathAttributes{
        .allocator = testing.allocator,
        .origin = .init(.IGP),
        .asPath = .init(.createEmpty(testing.allocator)),
        .nexthop = .init(.{ .Address = ip.IpV4Address.init(127, 0, 0, 1) }),
        .localPref = .init(100),
        .atomicAggregate = .init(false),
        .multiExitDiscriminator = null,
        .aggregator = null,
    };

    try rib.setPath(route, .{ .self = .{ .localAsn = 65001 } }, attrs);

    const ribEntry = rib.prefixes.getPtr(route) orelse return error.RouteNotPresent;
    const routePath = ribEntry.paths.getPtr(.{ .self = .{ .localAsn = 65001 } }) orelse return error.PathNotFound;

    try testing.expect(routePath.advertiser == .self);
    try testing.expectEqual(model.Origin.IGP, routePath.attrs.origin.value);

    try testing.expectEqual(true, rib.removePath(route, .{ .self = .{ .localAsn = 65001 } }));
}

test "MainRibPath.cmp local preference" {
    const allocator = testing.allocator;

    const path1 = MainRibPath{
        .advertiser = .{ .self = .{ .localAsn = 65001 } },
        .attrs = PathAttributes{
            .allocator = allocator,
            .origin = .init(.IGP),
            .asPath = .init(ASPath.createEmpty(allocator)),
            .nexthop = .init(.{ .Address = ip.IpV4Address.parse("1.1.1.1") catch unreachable }),
            .localPref = .init(200),
            .atomicAggregate = .init(false),
            .multiExitDiscriminator = null,
            .aggregator = null,
        },
    };
    defer path1.attrs.asPath.value.deinit();

    const path2 = MainRibPath{
        .advertiser = .{ .self = .{ .localAsn = 65001 } },
        .attrs = PathAttributes{
            .allocator = allocator,
            .origin = .init(.IGP),
            .asPath = .init(ASPath.createEmpty(allocator)),
            .nexthop = .init(.{ .Address = ip.IpV4Address.parse("1.1.1.1") catch unreachable }),
            .localPref = .init(100),
            .atomicAggregate = .init(false),
            .multiExitDiscriminator = null,
            .aggregator = null,
        },
    };
    defer path2.attrs.asPath.value.deinit();

    try testing.expect(path1.cmp(&path2) > 0);
    try testing.expect(path2.cmp(&path1) < 0);
}

test "MainRibPath.cmp AS path length" {
    const allocator = testing.allocator;

    const as_path_seg = model.ASPathSegment{
        .allocator = allocator,
        .segType = .AS_Sequence,
        .contents = try allocator.dupe(u16, &[_]u16{ 1, 2, 3 }),
    };
    const as_path_long = model.ASPath{
        .allocator = allocator,
        .segments = try allocator.dupe(model.ASPathSegment, &[_]model.ASPathSegment{as_path_seg}),
    };
    defer as_path_long.deinit();

    const n1 = MainRibAdvertiser{ .neighbor = .{ .neighborIp = ip.IpAddress{ .V4 = ip.IpV4Address.parse("10.0.0.1") catch unreachable }, .peerId = 1, .localAsn = 65001, .sessionType = .IBGP } };

    const path_long = MainRibPath{
        .advertiser = n1,
        .attrs = PathAttributes{
            .allocator = allocator,
            .origin = .init(.IGP),
            .asPath = .init(as_path_long),
            .nexthop = .init(.{ .Address = ip.IpV4Address.parse("1.1.1.1") catch unreachable }),
            .localPref = .init(100),
            .atomicAggregate = .init(false),
            .multiExitDiscriminator = null,
            .aggregator = null,
        },
    };

    const path_short = MainRibPath{
        .advertiser = n1,
        .attrs = PathAttributes{
            .allocator = allocator,
            .origin = .init(.IGP),
            .asPath = .init(ASPath.createEmpty(allocator)),
            .nexthop = .init(.{ .Address = ip.IpV4Address.parse("1.1.1.1") catch unreachable }),
            .localPref = .init(100),
            .atomicAggregate = .init(false),
            .multiExitDiscriminator = null,
            .aggregator = null,
        },
    };
    defer path_short.attrs.asPath.value.deinit();

    try testing.expect(path_short.cmp(&path_long) > 0);
    try testing.expect(path_long.cmp(&path_short) < 0);
}

test "MainRibPath.cmp origin preference" {
    const allocator = testing.allocator;

    const n1 = MainRibAdvertiser{ .neighbor = .{ .neighborIp = ip.IpAddress{ .V4 = ip.IpV4Address.parse("10.0.0.1") catch unreachable }, .peerId = 1, .localAsn = 65001, .sessionType = .IBGP } };

    const path_igp = MainRibPath{
        .advertiser = n1,
        .attrs = PathAttributes{
            .allocator = allocator,
            .origin = .init(.IGP),
            .asPath = .init(ASPath.createEmpty(allocator)),
            .nexthop = .init(.{ .Address = ip.IpV4Address.parse("1.1.1.1") catch unreachable }),
            .localPref = .init(100),
            .atomicAggregate = .init(false),
            .multiExitDiscriminator = null,
            .aggregator = null,
        },
    };
    defer path_igp.attrs.asPath.value.deinit();

    const path_egp = MainRibPath{
        .advertiser = n1,
        .attrs = PathAttributes{
            .allocator = allocator,
            .origin = .init(.EGP),
            .asPath = .init(ASPath.createEmpty(allocator)),
            .nexthop = .init(.{ .Address = ip.IpV4Address.parse("1.1.1.1") catch unreachable }),
            .localPref = .init(100),
            .atomicAggregate = .init(false),
            .multiExitDiscriminator = null,
            .aggregator = null,
        },
    };
    defer path_egp.attrs.asPath.value.deinit();

    const path_inc = MainRibPath{
        .advertiser = n1,
        .attrs = PathAttributes{
            .allocator = allocator,
            .origin = .init(.INCOMPLETE),
            .asPath = .init(ASPath.createEmpty(allocator)),
            .nexthop = .init(.{ .Address = ip.IpV4Address.parse("1.1.1.1") catch unreachable }),
            .localPref = .init(100),
            .atomicAggregate = .init(false),
            .multiExitDiscriminator = null,
            .aggregator = null,
        },
    };
    defer path_inc.attrs.asPath.value.deinit();

    try testing.expect(path_igp.cmp(&path_egp) > 0);
    try testing.expect(path_egp.cmp(&path_inc) > 0);
    try testing.expect(path_igp.cmp(&path_inc) > 0);
}

test "MainRibPath.cmp tie" {
    const allocator = testing.allocator;

    const n1 = MainRibAdvertiser{ .neighbor = .{ .neighborIp = ip.IpAddress{ .V4 = ip.IpV4Address.parse("10.0.0.1") catch unreachable }, .peerId = 1, .localAsn = 65001, .sessionType = .IBGP } };

    const path1 = MainRibPath{
        .advertiser = n1,
        .attrs = PathAttributes{
            .allocator = allocator,
            .origin = .init(.IGP),
            .asPath = .init(ASPath.createEmpty(allocator)),
            .nexthop = .init(.{ .Address = ip.IpV4Address.parse("1.1.1.1") catch unreachable }),
            .localPref = .init(100),
            .atomicAggregate = .init(false),
            .multiExitDiscriminator = null,
            .aggregator = null,
        },
    };
    defer path1.attrs.asPath.value.deinit();

    const path2 = MainRibPath{
        .advertiser = n1,
        .attrs = PathAttributes{
            .allocator = allocator,
            .origin = .init(.IGP),
            .asPath = .init(ASPath.createEmpty(allocator)),
            .nexthop = .init(.{ .Address = ip.IpV4Address.parse("1.1.1.1") catch unreachable }),
            .localPref = .init(100),
            .atomicAggregate = .init(false),
            .multiExitDiscriminator = null,
            .aggregator = null,
        },
    };
    defer path2.attrs.asPath.value.deinit();

    try testing.expectEqual(@as(i32, 0), path1.cmp(&path2));
}

test "MainRibPath.cmp MED" {
    const allocator = testing.allocator;

    const n1 = MainRibAdvertiser{ .neighbor = .{ .neighborIp = ip.IpAddress{ .V4 = ip.IpV4Address.parse("10.0.0.1") catch unreachable }, .peerId = 1, .localAsn = 65001, .sessionType = .EBGP } };

    var asPath = ASPath.createEmpty(allocator);
    defer asPath.deinit();
    try asPath.prependASN(65001);

    const path1 = MainRibPath{
        .advertiser = n1,
        .attrs = PathAttributes{
            .allocator = allocator,
            .origin = .init(.IGP),
            .asPath = .init(try asPath.clone(allocator)),
            .nexthop = .init(.{ .Address = ip.IpV4Address.parse("1.1.1.1") catch unreachable }),
            .localPref = .init(100),
            .atomicAggregate = .init(false),
            .multiExitDiscriminator = .init(50),
            .aggregator = null,
        },
    };
    defer path1.attrs.asPath.value.deinit();

    const path2 = MainRibPath{
        .advertiser = n1,
        .attrs = PathAttributes{
            .allocator = allocator,
            .origin = .init(.IGP),
            .asPath = .init(try asPath.clone(allocator)),
            .nexthop = .init(.{ .Address = ip.IpV4Address.parse("1.1.1.1") catch unreachable }),
            .localPref = .init(100),
            .atomicAggregate = .init(false),
            .multiExitDiscriminator = .init(100),
            .aggregator = null,
        },
    };
    defer path2.attrs.asPath.value.deinit();

    const path_missing_med = MainRibPath{
        .advertiser = n1,
        .attrs = PathAttributes{
            .allocator = allocator,
            .origin = .init(.IGP),
            .asPath = .init(try asPath.clone(allocator)),
            .nexthop = .init(.{ .Address = ip.IpV4Address.parse("1.1.1.1") catch unreachable }),
            .localPref = .init(100),
            .atomicAggregate = .init(false),
            .multiExitDiscriminator = null,
            .aggregator = null,
        },
    };
    defer path_missing_med.attrs.asPath.value.deinit();

    try testing.expect(path1.cmp(&path2) > 0);
    try testing.expect(path2.cmp(&path1) < 0);

    try testing.expect(path_missing_med.cmp(&path1) > 0);
    try testing.expect(path1.cmp(&path_missing_med) < 0);
}

test "MainRibPath.cmp EBGP vs IBGP" {
    const allocator = testing.allocator;

    const n1_ebgp = MainRibAdvertiser{ .neighbor = .{ .neighborIp = ip.IpAddress{ .V4 = ip.IpV4Address.parse("10.0.0.1") catch unreachable }, .peerId = 1, .localAsn = 65001, .sessionType = .EBGP } };
    const n1_ibgp = MainRibAdvertiser{ .neighbor = .{ .neighborIp = ip.IpAddress{ .V4 = ip.IpV4Address.parse("10.0.0.1") catch unreachable }, .peerId = 1, .localAsn = 65001, .sessionType = .IBGP } };

    var asPath = ASPath.createEmpty(allocator);
    try asPath.prependASN(65002);
    defer asPath.deinit();

    const ebgp_path = MainRibPath{
        .advertiser = n1_ebgp,
        .attrs = PathAttributes{
            .allocator = allocator,
            .origin = .init(.IGP),
            .asPath = .init(try asPath.clone(allocator)),
            .nexthop = .init(.{ .Address = ip.IpV4Address.parse("1.1.1.1") catch unreachable }),
            .localPref = .init(100),
            .atomicAggregate = .init(false),
            .multiExitDiscriminator = null,
            .aggregator = null,
        },
    };
    defer ebgp_path.attrs.asPath.value.deinit();

    const ibgp_path = MainRibPath{
        .advertiser = n1_ibgp,
        .attrs = PathAttributes{
            .allocator = allocator,
            .origin = .init(.IGP),
            .asPath = .init(try asPath.clone(allocator)),
            .nexthop = .init(.{ .Address = ip.IpV4Address.parse("1.1.1.1") catch unreachable }),
            .localPref = .init(100),
            .atomicAggregate = .init(false),
            .multiExitDiscriminator = null,
            .aggregator = null,
        },
    };
    defer ibgp_path.attrs.asPath.value.deinit();

    try testing.expect(ebgp_path.cmp(&ibgp_path) > 0);
    try testing.expect(ibgp_path.cmp(&ebgp_path) < 0);
}

test "MainRibPath.cmp advertiser tie-break" {
    const allocator = testing.allocator;

    const n1 = MainRibAdvertiser{ .neighbor = .{ .neighborIp = ip.IpAddress{ .V4 = ip.IpV4Address.parse("10.0.0.1") catch unreachable }, .peerId = 1, .localAsn = 65001, .sessionType = .IBGP } };
    const n2 = MainRibAdvertiser{ .neighbor = .{ .neighborIp = ip.IpAddress{ .V4 = ip.IpV4Address.parse("10.0.0.2") catch unreachable }, .peerId = 2, .localAsn = 65002, .sessionType = .IBGP } };

    const path_self = MainRibPath{
        .advertiser = .{ .self = .{ .localAsn = 65001 } },
        .attrs = PathAttributes{
            .allocator = allocator,
            .origin = .init(.IGP),
            .asPath = .init(ASPath.createEmpty(allocator)),
            .nexthop = .init(.{ .Address = ip.IpV4Address.parse("1.1.1.1") catch unreachable }),
            .localPref = .init(100),
            .atomicAggregate = .init(false),
            .multiExitDiscriminator = null,
            .aggregator = null,
        },
    };
    defer path_self.attrs.asPath.value.deinit();

    const path_n1 = MainRibPath{
        .advertiser = n1,
        .attrs = PathAttributes{
            .allocator = allocator,
            .origin = .init(.IGP),
            .asPath = .init(ASPath.createEmpty(allocator)),
            .nexthop = .init(.{ .Address = ip.IpV4Address.parse("1.1.1.1") catch unreachable }),
            .localPref = .init(100),
            .atomicAggregate = .init(false),
            .multiExitDiscriminator = null,
            .aggregator = null,
        },
    };
    defer path_n1.attrs.asPath.value.deinit();

    const path_n2 = MainRibPath{
        .advertiser = n2,
        .attrs = PathAttributes{
            .allocator = allocator,
            .origin = .init(.IGP),
            .asPath = .init(ASPath.createEmpty(allocator)),
            .nexthop = .init(.{ .Address = ip.IpV4Address.parse("1.1.1.1") catch unreachable }),
            .localPref = .init(100),
            .atomicAggregate = .init(false),
            .multiExitDiscriminator = null,
            .aggregator = null,
        },
    };
    defer path_n2.attrs.asPath.value.deinit();

    try testing.expect(path_self.cmp(&path_n1) > 0);
    try testing.expect(path_n1.cmp(&path_self) < 0);

    try testing.expect(path_n1.cmp(&path_n2) > 0);
    try testing.expect(path_n2.cmp(&path_n1) < 0);
}
