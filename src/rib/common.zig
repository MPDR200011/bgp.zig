const std = @import("std");
const ip = @import("ip");

const model = @import("../messaging/model.zig");

const Allocator = std.mem.Allocator;

const PathAttributes = model.PathAttributes;
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

        // TODO: handle MED

        // TODO: external peer > internal peer

        // TODO: nexthop cost tie break

        // Lowest peer ID wins

        // Lowest peer address wins
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
            .origin = .init(.IGP),
            .asPath = .init(ASPath.createEmpty(allocator)),
            .nexthop = .init(ip.IpV4Address.parse("1.1.1.1") catch unreachable),
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
            .origin = .init(.IGP),
            .asPath = .init(ASPath.createEmpty(allocator)),
            .nexthop = .init(ip.IpV4Address.parse("1.1.1.1") catch unreachable),
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

    const path_long = RoutePath{
        .advertiser = .self,
        .attrs = PathAttributes{
            .allocator = allocator,
            .origin = .init(.IGP),
            .asPath = .init(as_path_long),
            .nexthop = .init(ip.IpV4Address.parse("1.1.1.1") catch unreachable),
            .localPref = .init(100),
            .atomicAggregate = .init(false),
            .multiExitDiscriminator = null,
            .aggregator = null,
        },
    };

    const path_short = RoutePath{
        .advertiser = .self,
        .attrs = PathAttributes{
            .allocator = allocator,
            .origin = .init(.IGP),
            .asPath = .init(ASPath.createEmpty(allocator)),
            .nexthop = .init(ip.IpV4Address.parse("1.1.1.1") catch unreachable),
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

    const path_igp = RoutePath{
        .advertiser = .self,
        .attrs = PathAttributes{
            .allocator = allocator,
            .origin = .init(.IGP),
            .asPath = .init(ASPath.createEmpty(allocator)),
            .nexthop = .init(ip.IpV4Address.parse("1.1.1.1") catch unreachable),
            .localPref = .init(100),
            .atomicAggregate = .init(false),
            .multiExitDiscriminator = null,
            .aggregator = null,
        },
    };
    defer path_igp.attrs.asPath.value.deinit();

    const path_egp = RoutePath{
        .advertiser = .self,
        .attrs = PathAttributes{
            .allocator = allocator,
            .origin = .init(.EGP),
            .asPath = .init(ASPath.createEmpty(allocator)),
            .nexthop = .init(ip.IpV4Address.parse("1.1.1.1") catch unreachable),
            .localPref = .init(100),
            .atomicAggregate = .init(false),
            .multiExitDiscriminator = null,
            .aggregator = null,
        },
    };
    defer path_egp.attrs.asPath.value.deinit();

    const path_inc = RoutePath{
        .advertiser = .self,
        .attrs = PathAttributes{
            .allocator = allocator,
            .origin = .init(.INCOMPLETE),
            .asPath = .init(ASPath.createEmpty(allocator)),
            .nexthop = .init(ip.IpV4Address.parse("1.1.1.1") catch unreachable),
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

    const path1 = RoutePath{
        .advertiser = .self,
        .attrs = PathAttributes{
            .allocator = allocator,
            .origin = .init(.IGP),
            .asPath = .init(ASPath.createEmpty(allocator)),
            .nexthop = .init(ip.IpV4Address.parse("1.1.1.1") catch unreachable),
            .localPref = .init(100),
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
            .origin = .init(.IGP),
            .asPath = .init(ASPath.createEmpty(allocator)),
            .nexthop = .init(ip.IpV4Address.parse("1.1.1.1") catch unreachable),
            .localPref = .init(100),
            .atomicAggregate = .init(false),
            .multiExitDiscriminator = null,
            .aggregator = null,
        },
    };
    defer path2.attrs.asPath.value.deinit();

    try testing.expectEqual(@as(i32, 0), path1.cmp(&path2));
}
