const std = @import("std");
const ip = @import("ip");

const model = @import("model.zig");

const Allocator = std.mem.Allocator;

const PathAttributes = model.PathAttributes;
const ASNumber = model.ASNumber;
const ASPath = model.ASPath;
const Route = model.Route;


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

/// Lexicographical comparison of addresses
/// > 0 => a1 > a2
/// < 0 => a1 < a2
/// = 0 => Tie
fn compareAddresses(a1: ip.IpAddress, a2: ip.IpAddress) i32 { 
    // The AFIs should never be different, the program should never reach a
    // point where this happens. Right?!
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
        }
    }
    return 0;
}

pub const RoutePath = struct {
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

    pub fn neighboringAS(self: *const Self) ASNumber {
        std.debug.assert(self.attrs.asPath.value.segments.len > 0);
        const firstSegment = self.attrs.asPath.value.segments[0];

        std.debug.assert(firstSegment.segType == .AS_Sequence);
        return firstSegment.contents[0];
    }

    pub fn getMED(self: *const Self) u32 {
        const med = self.attrs.multiExitDiscriminator orelse return 0;
        return med.value;
    }

    /// > 0 => self is more prefered than other
    /// < 0 => self is less prefered than other
    /// = 0 => Tie
    pub fn cmp(self: *const Self, other: *const Self) i32 {
        const lPrefComp = @as(i32, @intCast(self.attrs.localPref.value)) - @as(i32, @intCast(other.attrs.localPref.value));
        if (lPrefComp != 0) {
            return lPrefComp;
        }

        const asPathComp: i32 = @as(i32, @intCast(other.attrs.asPath.value.len())) - @as(i32, @intCast(self.attrs.asPath.value.len()));
        if (asPathComp != 0) {
            return asPathComp;
        }

        const originComp = @intFromEnum(other.attrs.origin.value) - @intFromEnum(self.attrs.origin.value);
        if (originComp != 0) {
            return originComp;
        }

        if (self.attrs.sessionType == .EBGP and other.attrs.sessionType == .EBGP) {
            if (self.neighboringAS() == other.neighboringAS()) {
                const diff = @as(i64, @intCast(other.getMED())) - @as(i64, @intCast(self.getMED()));
                if (diff != 0) {
                    return @intCast(diff);
                }
            }
        }

        if (self.attrs.sessionType == .EBGP) {
            if (other.attrs.sessionType == .IBGP) {
                return 1;
            }
        } else {
            // self == IBGP
            if (other.attrs.sessionType == .EBGP) {
                return -1;
            }
        }

        // FIXME: Lowest peer ID wins

        // Lowest peer address wins
        switch (self.advertiser) {
            .self => {
                // There shouldn't be two originations of the same route
                std.debug.assert(std.meta.activeTag(other.advertiser) != .self);
                return 1;
            },
            .neighbor => {
                switch (other.advertiser) {
                    .self => {
                        return -1;
                    },
                    .neighbor => {
                        const diff = compareAddresses(other.advertiser.neighbor, self.advertiser.neighbor);
                        if (diff != 0) {
                            return diff;
                        }
                    }
                }
            }
        }

        // TODO: some vendor implementations tie break based on path age, should look into that
        return 0;
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

// Utility struct for rib managers to keep track of inflight tasks in the
// threadpool.
// Useful for preventing the cleaning up of resources while there are tasks in
// the queue yet to execute, which might cause use after free issues
pub const TaskCounter = struct {
    const Self = @This();

    taskCountMutex: std.Thread.Mutex,
    taskCountCond: std.Thread.Condition,
    inFlightTaskCount: u32,
    shutdown: bool,

    pub const default: Self = .{
        .taskCountMutex = .{},
        .taskCountCond = .{},
        .inFlightTaskCount = 0,
        .shutdown = false,
    };

    pub fn incrementTasks(self: *Self) void {
        self.taskCountMutex.lock();
        defer self.taskCountMutex.unlock();

        std.debug.assert(!self.shutdown);

        self.inFlightTaskCount += 1;
    }

    pub fn decrementTasks(self: *Self) void {
        self.taskCountMutex.lock();
        defer self.taskCountMutex.unlock();

        std.debug.assert(self.inFlightTaskCount > 0);

        self.inFlightTaskCount -= 1;

        self.taskCountCond.signal();
    }

    pub fn waitForDrainAndShutdown(self: *Self) void {
        self.taskCountMutex.lock();
        defer self.taskCountMutex.unlock();

        while (self.inFlightTaskCount > 0) {
            self.taskCountCond.wait(&self.taskCountMutex);
        }
        self.shutdown = true;
    }
};

const testing = std.testing;

test "RoutePath.cmp local preference" {
    const allocator = testing.allocator;

    const path1 = RoutePath{
        .advertiser = .self,
        .attrs = PathAttributes{
            .allocator = allocator,
            .sessionType = .IBGP,
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

    const path2 = RoutePath{
        .advertiser = .self,
        .attrs = PathAttributes{
            .allocator = allocator,
            .sessionType = .IBGP,
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

test "RoutePath.cmp AS path length" {
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

    const n1 = ip.IpAddress{ .V4 = ip.IpV4Address.parse("10.0.0.1") catch unreachable };

    const path_long = RoutePath{
        .advertiser = .{ .neighbor = n1 },
        .attrs = PathAttributes{
            .allocator = allocator,
            .sessionType = .IBGP,
            .origin = .init(.IGP),
            .asPath = .init(as_path_long),
            .nexthop = .init(.{ .Address = ip.IpV4Address.parse("1.1.1.1") catch unreachable }),
            .localPref = .init(100),
            .atomicAggregate = .init(false),
            .multiExitDiscriminator = null,
            .aggregator = null,
        },
    };

    const path_short = RoutePath{
        .advertiser = .{ .neighbor = n1 },
        .attrs = PathAttributes{
            .allocator = allocator,
            .sessionType = .IBGP,
            .origin = .init(.IGP),
            .asPath = .init(ASPath.createEmpty(allocator)),
            .nexthop = .init(.{ .Address = ip.IpV4Address.parse("1.1.1.1") catch unreachable }),
            .localPref = .init(100), // Equal localPref
            .atomicAggregate = .init(false),
            .multiExitDiscriminator = null,
            .aggregator = null,
        },
    };
    defer path_short.attrs.asPath.value.deinit();

    try testing.expect(path_short.cmp(&path_long) > 0);
    try testing.expect(path_long.cmp(&path_short) < 0);
}

test "RoutePath.cmp origin preference" {
    const allocator = testing.allocator;

    const n1 = ip.IpAddress{ .V4 = ip.IpV4Address.parse("10.0.0.1") catch unreachable };

    const path_igp = RoutePath{
        .advertiser = .{ .neighbor = n1 },
        .attrs = PathAttributes{
            .allocator = allocator,
            .sessionType = .IBGP,
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

    const path_egp = RoutePath{
        .advertiser = .{ .neighbor = n1 },
        .attrs = PathAttributes{
            .allocator = allocator,
            .sessionType = .IBGP,
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

    const path_inc = RoutePath{
        .advertiser = .{ .neighbor = n1 },
        .attrs = PathAttributes{
            .allocator = allocator,
            .sessionType = .IBGP,
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

    // IGP > EGP > INCOMPLETE
    try testing.expect(path_igp.cmp(&path_egp) > 0);
    try testing.expect(path_egp.cmp(&path_inc) > 0);
    try testing.expect(path_igp.cmp(&path_inc) > 0);
}

test "RoutePath.cmp tie" {
    const allocator = testing.allocator;

    const n1 = ip.IpAddress{ .V4 = ip.IpV4Address.parse("10.0.0.1") catch unreachable };

    const path1 = RoutePath{
        .advertiser = .{ .neighbor = n1 },
        .attrs = PathAttributes{
            .allocator = allocator,
            .sessionType = .IBGP,
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

    const path2 = RoutePath{
        .advertiser = .{ .neighbor = n1 },
        .attrs = PathAttributes{
            .allocator = allocator,
            .sessionType = .IBGP,
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

test "RoutePath.cmp MED" {
    const allocator = testing.allocator;

    const n1 = ip.IpAddress{ .V4 = ip.IpV4Address.parse("10.0.0.1") catch unreachable };

    var as_path = ASPath.createEmpty(allocator);
    defer as_path.deinit();
    try as_path.prependASN(65001);

    const path1 = RoutePath{
        .advertiser = .{ .neighbor = n1 },
        .attrs = PathAttributes{
            .allocator = allocator,
            .sessionType = .EBGP,
            .origin = .init(.IGP),
            .asPath = .init(try as_path.clone(allocator)),
            .nexthop = .init(.{ .Address = ip.IpV4Address.parse("1.1.1.1") catch unreachable }),
            .localPref = .init(100),
            .atomicAggregate = .init(false),
            .multiExitDiscriminator = .init(50),
            .aggregator = null,
        },
    };
    defer path1.attrs.asPath.value.deinit();

    const path2 = RoutePath{
        .advertiser = .{ .neighbor = n1 },
        .attrs = PathAttributes{
            .allocator = allocator,
            .sessionType = .EBGP,
            .origin = .init(.IGP),
            .asPath = .init(try as_path.clone(allocator)),
            .nexthop = .init(.{ .Address = ip.IpV4Address.parse("1.1.1.1") catch unreachable }),
            .localPref = .init(100),
            .atomicAggregate = .init(false),
            .multiExitDiscriminator = .init(100),
            .aggregator = null,
        },
    };
    defer path2.attrs.asPath.value.deinit();

    const path_missing_med = RoutePath{
        .advertiser = .{ .neighbor = n1 },
        .attrs = PathAttributes{
            .allocator = allocator,
            .sessionType = .EBGP,
            .origin = .init(.IGP),
            .asPath = .init(try as_path.clone(allocator)),
            .nexthop = .init(.{ .Address = ip.IpV4Address.parse("1.1.1.1") catch unreachable }),
            .localPref = .init(100),
            .atomicAggregate = .init(false),
            .multiExitDiscriminator = null,
            .aggregator = null,
        },
    };
    defer path_missing_med.attrs.asPath.value.deinit();

    // Smaller MED is better
    try testing.expect(path1.cmp(&path2) > 0);
    try testing.expect(path2.cmp(&path1) < 0);

    // Missing MED is treated as 0, which is better than any non-zero MED
    try testing.expect(path_missing_med.cmp(&path1) > 0);
    try testing.expect(path1.cmp(&path_missing_med) < 0);
}

test "RoutePath.cmp EBGP vs IBGP" {
    const allocator = testing.allocator;

    const n1 = ip.IpAddress{ .V4 = ip.IpV4Address.parse("10.0.0.1") catch unreachable };

    const ebgp_path = RoutePath{
        .advertiser = .{ .neighbor = n1 },
        .attrs = PathAttributes{
            .allocator = allocator,
            .sessionType = .EBGP,
            .origin = .init(.IGP),
            .asPath = .init(ASPath.createEmpty(allocator)),
            .nexthop = .init(.{ .Address = ip.IpV4Address.parse("1.1.1.1") catch unreachable }),
            .localPref = .init(100),
            .atomicAggregate = .init(false),
            .multiExitDiscriminator = null,
            .aggregator = null,
        },
    };
    defer ebgp_path.attrs.asPath.value.deinit();

    const ibgp_path = RoutePath{
        .advertiser = .{ .neighbor = n1 },
        .attrs = PathAttributes{
            .allocator = allocator,
            .sessionType = .IBGP,
            .origin = .init(.IGP),
            .asPath = .init(ASPath.createEmpty(allocator)),
            .nexthop = .init(.{ .Address = ip.IpV4Address.parse("1.1.1.1") catch unreachable }),
            .localPref = .init(100),
            .atomicAggregate = .init(false),
            .multiExitDiscriminator = null,
            .aggregator = null,
        },
    };
    defer ibgp_path.attrs.asPath.value.deinit();

    // EBGP is better than IBGP
    try testing.expect(ebgp_path.cmp(&ibgp_path) > 0);
    try testing.expect(ibgp_path.cmp(&ebgp_path) < 0);
}

test "RoutePath.cmp advertiser tie-break" {
    const allocator = testing.allocator;

    const n1 = ip.IpAddress{ .V4 = ip.IpV4Address.parse("10.0.0.1") catch unreachable };
    const n2 = ip.IpAddress{ .V4 = ip.IpV4Address.parse("10.0.0.2") catch unreachable };

    const path_self = RoutePath{
        .advertiser = .self,
        .attrs = PathAttributes{
            .allocator = allocator,
            .sessionType = .IBGP,
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

    const path_n1 = RoutePath{
        .advertiser = .{ .neighbor = n1 },
        .attrs = PathAttributes{
            .allocator = allocator,
            .sessionType = .IBGP,
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

    const path_n2 = RoutePath{
        .advertiser = .{ .neighbor = n2 },
        .attrs = PathAttributes{
            .allocator = allocator,
            .sessionType = .IBGP,
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

    // self is better than neighbor
    try testing.expect(path_self.cmp(&path_n1) > 0);
    try testing.expect(path_n1.cmp(&path_self) < 0);

    // lower neighbor address is better
    // compareAddresses(other.advertiser.neighbor, self.advertiser.neighbor)
    // if other > self, returns > 0.
    try testing.expect(path_n1.cmp(&path_n2) > 0);
    try testing.expect(path_n2.cmp(&path_n1) < 0);
}
