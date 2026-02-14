const std = @import("std");
const zul = @import("zul");
const ip = @import("ip");
const adjRibManager = @import("adj_rib_manager.zig");
const mainRibManager = @import("main_rib_manager.zig");
const model = @import("../messaging/model.zig");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;

const PeerMap = @import("../peer_map.zig").PeerMap;
const AdjRibInManager = adjRibManager.AdjRibInManager;
const AdjRibOutManager = adjRibManager.AdjRibOutManager;
const RibManager = mainRibManager.RibManager;

const RouteUpdate = std.meta.Tuple(&.{ model.Route, common.RoutePath });

const RouteList = std.ArrayList(model.Route);
const UpdatesList = std.ArrayList(RouteUpdate);

fn filterSplitHorizon(alloc: Allocator, neighbor: ip.IpAddress, updates: UpdatesList) !UpdatesList {
    var filtered = UpdatesList{};
    errdefer {
        for (filtered.items) |*update| {
            update.@"1".deinit();
        }
        filtered.deinit(alloc);
    }

    const neighbor_advertiser: common.Advertiser = .{ .neighbor = neighbor };
    for (updates.items) |update| {
        if (!update.@"1".advertiser.equals(neighbor_advertiser)) {
            try filtered.append(alloc, .{ update.@"0", try update.@"1".clone(alloc) });
        }
    }
    return filtered;
}

const SyncResult = struct {
    deletedRoutes: RouteList,
    updatedRoutes: UpdatesList,

    const init: @This() = .{ .deletedRoutes = .{}, .updatedRoutes = .{} };

    pub fn deinit(self: *@This(), alloc: Allocator) void {
        self.deletedRoutes.deinit(alloc);
        for (self.updatedRoutes.items) |*update| {
            update.@"1".deinit();
        }
        self.updatedRoutes.deinit(alloc);
    }
};

const PathAttributesContext = struct {
    pub fn hash(_: @This(), attrs: model.PathAttributes) u64 {
        var hasher = std.hash.Wyhash.init(0);
        attrs.hash(&hasher);
        return hasher.final();
    }
    pub fn eql(_: @This(), a: model.PathAttributes, b: model.PathAttributes) bool {
        return a.equal(&b);
    }
};
const RouteGroups = std.HashMap(model.PathAttributes, std.ArrayList(model.Route), PathAttributesContext, std.hash_map.default_max_load_percentage);

const AggregatedRoutes = struct {
    allocator: Allocator,
    groups: RouteGroups,

    fn deinit(self: *@This()) void {
        var it = self.groups.iterator();
        while (it.next()) |entry| {
            entry.key_ptr.deinit();
            entry.value_ptr.deinit(self.allocator);
        }
        self.groups.deinit();
    }
};

fn aggregateRouteUpdates(alloc: Allocator, updates: *UpdatesList) !AggregatedRoutes {
    var aggregate: AggregatedRoutes = .{
        .allocator = alloc,
        .groups = .init(alloc),
    };
    errdefer aggregate.deinit();

    for (updates.items) |update| {
        const res = try aggregate.groups.getOrPut(update.@"1".attrs);
        if (!res.found_existing) {
            res.key_ptr.* = try update.@"1".attrs.clone(alloc);
            res.value_ptr.* = .{};
        }

        try res.value_ptr.append(alloc, update.@"0");
    }

    return aggregate;
}

fn syncFromAdjInToMain(alloc: Allocator, adjRib: *const AdjRibInManager, mainRib: *RibManager) !SyncResult {
    var res: SyncResult = .init;
    errdefer res.deinit(alloc);

    // Check for dropped routes
    var mainIt = mainRib.rib.prefixes.iterator();
    while (mainIt.next()) |mainEntry| {
        // TODO: AS Path Loop detection

        // Check if route has path from this neighbor
        if (!mainEntry.value_ptr.paths.contains(.{ .neighbor = adjRib.neighbor })) {
            continue;
        }

        // Check if neighbor still has that route
        if (adjRib.adjRib.prefixes.contains(mainEntry.key_ptr.*)) {
            continue;
        }

        // Delete the route from the main rib if not
        try res.deletedRoutes.append(alloc, mainEntry.key_ptr.*);
    }

    for (res.deletedRoutes.items) |routeToRemove| {
        _ = mainRib.rib.removePath(routeToRemove, .{ .neighbor = adjRib.neighbor });
    }

    // Update all paths
    var adjIt = adjRib.adjRib.prefixes.iterator();
    while (adjIt.next()) |adjEntry| {
        // TODO: Equality check to save on work
        try mainRib.rib.setPath(adjEntry.key_ptr.*, .{ .neighbor = adjRib.neighbor }, adjEntry.value_ptr.attrs);

        try res.updatedRoutes.append(alloc, .{ adjEntry.key_ptr.*, .{ .advertiser = .{ .neighbor = adjRib.neighbor }, .attrs = try adjEntry.value_ptr.attrs.clone(alloc) } });
    }

    return res;
}

fn updateMainRib(alloc: Allocator, mainRib: *RibManager) !RouteList {
    var updatedRoutes: RouteList = .{};
    errdefer updatedRoutes.deinit(alloc);

    // best path selection
    var mainIt = mainRib.rib.prefixes.iterator();
    while (mainIt.next()) |entry| {
        const ribEntry = entry.value_ptr;

        std.debug.assert(ribEntry.paths.count() > 0);

        var pathsIt = ribEntry.paths.iterator();
        var nextHop = ribEntry.bestPath orelse pathsIt.next().?.key_ptr.*;
        var bestPath = ribEntry.paths.getPtr(nextHop).?;

        var updated = false;
        while (pathsIt.next()) |pathsEntry| {
            if (nextHop.equals(pathsEntry.key_ptr.*)) {
                continue;
            }

            if (pathsEntry.value_ptr.cmp(bestPath) <= 0) {
                continue;
            }

            // TODO: If the NEXT_HOP attribute of a BGP route depicts an address that is
            // not resolvable, or if it would become unresolvable if the route was
            // installed in the routing table, the BGP route MUST be excluded from
            // the Phase 2 decision function.

            nextHop = pathsEntry.key_ptr.*;
            bestPath = pathsEntry.value_ptr;
            updated = true;
        }

        if (updated) {
            ribEntry.bestPath = nextHop;
            try updatedRoutes.append(alloc, entry.key_ptr.*);
        }
    }

    // TODO: what if the best path got updated in the adj-in -> main sync?
    return updatedRoutes;
}

fn syncFromMainToAdjOut(alloc: Allocator, adjRib: *AdjRibOutManager, mainRib: *const RibManager) !SyncResult {
    var res: SyncResult = .init;
    errdefer res.deinit(alloc);

    var adjIt = adjRib.adjRib.prefixes.iterator();
    while (adjIt.next()) |entry| {
        if (mainRib.rib.prefixes.contains(entry.key_ptr.*)) {
            continue;
        }

        try res.deletedRoutes.append(alloc, entry.key_ptr.*);
    }

    for (res.deletedRoutes.items) |routeToRemove| {
        adjRib.adjRib.removePath(routeToRemove);
    }

    var mainIt = mainRib.rib.prefixes.iterator();
    while (mainIt.next()) |ribEntry| {
        const bestPath = ribEntry.value_ptr.paths.get(ribEntry.value_ptr.bestPath.?).?;
        try adjRib.setPath(ribEntry.key_ptr.*, ribEntry.value_ptr.bestPath.?, bestPath.attrs);

        try res.updatedRoutes.append(alloc, .{ ribEntry.key_ptr.*, try bestPath.clone(alloc) });
    }

    return res;
}

pub const RibThreadContext = struct {
    allocator: Allocator,
    mainRib: *RibManager,
    peerMap: *PeerMap,
};

pub const SyncTask = struct {
    fn syncRibsAndUpdate(self: *const SyncTask, ctx: RibThreadContext, scheduler: *zul.Scheduler(SyncTask, RibThreadContext)) !void {
        std.log.info("Running RIB Thread", .{});
        _ = self;
        ctx.mainRib.ribMutex.lock();
        defer ctx.mainRib.ribMutex.unlock();

        // sync adj-in -> main rib
        var entryIt = ctx.peerMap.iterator();
        while (entryIt.next()) |entry| {
            const peer = entry.value_ptr.*;
            // Lock the session to grab the adjIn reference
            peer.session.mutex.lock();
            if (peer.session.state != .ESTABLISHED) {
                peer.session.mutex.unlock();
                continue;
            }

            const adjIn = &peer.session.adjRibInManager.?;
            adjIn.ribMutex.lock();
            defer adjIn.ribMutex.unlock();

            // Once we grab the adjIn and lock it we can unlock the session
            // While the adjIn is locked the session can't terminate
            peer.session.mutex.unlock();

            var result = try syncFromAdjInToMain(ctx.allocator, adjIn, ctx.mainRib);
            result.deinit(ctx.allocator);
        }

        // main rib best path selection
        var updatedRoutes = try updateMainRib(ctx.allocator, ctx.mainRib);
        defer updatedRoutes.deinit(ctx.allocator);

        // sync main -> adj-out ribs
        entryIt = ctx.peerMap.iterator();
        while (entryIt.next()) |entry| {
            const peer = entry.value_ptr.*;
            const key = entry.key_ptr;

            // Lock the session to grab the adjIn reference
            peer.session.mutex.lock();
            if (peer.session.state != .ESTABLISHED) {
                peer.session.mutex.unlock();
                continue;
            }

            const adjOut = &peer.session.adjRibOutManager.?;
            adjOut.ribMutex.lock();
            defer adjOut.ribMutex.unlock();

            // Once we grab the adjOut and lock it we can unlock the session
            // While the adjOut is locked the session can't terminate
            peer.session.mutex.unlock();

            var result = try syncFromMainToAdjOut(ctx.allocator, adjOut, ctx.mainRib);
            defer result.deinit(ctx.allocator);

            // Split Horizon: filter out routes that were advertised by this peer
            var filteredUpdates = try filterSplitHorizon(ctx.allocator, adjOut.neighbor, result.updatedRoutes);
            defer {
                for (filteredUpdates.items) |*update| {
                    update.@"1".deinit();
                }
                filteredUpdates.deinit(ctx.allocator);
            }

            var aggregatedRoutes = try aggregateRouteUpdates(ctx.allocator, &filteredUpdates);
            defer aggregatedRoutes.deinit();

            // TODO: Message packaging, one message per prefix is naive
            for (result.deletedRoutes.items) |deletedRoute| {
                try peer.session.sendMessage(.{ .UPDATE = .{ 
                    .allocator = ctx.allocator,
                    .withdrawnRoutes = &[_]model.Route{deletedRoute},
                    .advertisedRoutes = &[_]model.Route{},
                    .pathAttributes = null,
                } });
            }
            for (result.updatedRoutes.items) |update| {
                var attrs = try update.@"1".attrs.clone(ctx.allocator);
                attrs.nexthop.value = key.localAddress;
                try attrs.asPath.value.prependASN(peer.localAsn);

                try peer.session.sendMessage(.{ .UPDATE = .{ 
                    .allocator = ctx.allocator, 
                    .withdrawnRoutes = &[_]model.Route{}, 
                    .advertisedRoutes = &[_]model.Route{update.@"0"},
                    .pathAttributes = attrs 
                } });
            }
        }

        std.log.info("RIB Thread Complete", .{});
        try scheduler.scheduleIn(.{}, std.time.ms_per_s * 30);
    }

    pub fn run(self: *const SyncTask, ctx: RibThreadContext, scheduler: *zul.Scheduler(SyncTask, RibThreadContext), at: i64) void {
        _ = at;

        self.syncRibsAndUpdate(ctx, scheduler) catch |err| {
            std.log.err("Ribs sync run failed with error: {}", .{err});
        };
    }
};

const t = std.testing;

test "Adj -> Main Adds Routes" {
    var adjRib: AdjRibInManager = try .init(t.allocator, ip.IpAddress{ .V4 = try .parse("192.168.0.1") });
    var mainRib: RibManager = try .init(t.allocator);
    defer adjRib.deinit();
    defer mainRib.deinit();

    const asPath: model.ASPath = .{ .allocator = t.allocator, .segments = try t.allocator.dupe(model.ASPathSegment, &[_]model.ASPathSegment{}) };

    const attrs = model.PathAttributes{ .allocator = t.allocator, .origin = .init(.EGP), .asPath = .init(asPath), .nexthop = .init(ip.IpV4Address.init(0, 0, 0, 0)), .localPref = .init(100), .atomicAggregate = .init(false), .multiExitDiscriminator = null, .aggregator = null };

    try adjRib.setPath(.{ .prefixData = [4]u8{ 10, 0, 1, 0 }, .prefixLength = 24 }, attrs);
    try adjRib.setPath(.{ .prefixData = [4]u8{ 10, 0, 2, 0 }, .prefixLength = 24 }, attrs);

    var res = try syncFromAdjInToMain(t.allocator, &adjRib, &mainRib);
    defer res.deinit(t.allocator);

    try t.expectEqual(adjRib.adjRib.prefixes.count(), 2);
    try t.expect(adjRib.adjRib.prefixes.contains(.{ .prefixData = [4]u8{ 10, 0, 1, 0 }, .prefixLength = 24 }));
    try t.expect(adjRib.adjRib.prefixes.contains(.{ .prefixData = [4]u8{ 10, 0, 2, 0 }, .prefixLength = 24 }));

    try t.expectEqual(mainRib.rib.prefixes.count(), 2);
    try t.expect(mainRib.rib.prefixes.contains(.{ .prefixData = [4]u8{ 10, 0, 1, 0 }, .prefixLength = 24 }));
    try t.expect(mainRib.rib.prefixes.contains(.{ .prefixData = [4]u8{ 10, 0, 2, 0 }, .prefixLength = 24 }));
}

test "Adj -> Main Removes Routes" {
    var adjRib: AdjRibInManager = try .init(t.allocator, ip.IpAddress{ .V4 = try .parse("192.168.0.1") });
    var mainRib: RibManager = try .init(t.allocator);
    defer adjRib.deinit();
    defer mainRib.deinit();

    const asPath: model.ASPath = .{ .allocator = t.allocator, .segments = try t.allocator.dupe(model.ASPathSegment, &[_]model.ASPathSegment{}) };

    const attrs = model.PathAttributes{ .allocator = t.allocator, .origin = .init(.EGP), .asPath = .init(asPath), .nexthop = .init(ip.IpV4Address.init(0, 0, 0, 0)), .localPref = .init(100), .atomicAggregate = .init(false), .multiExitDiscriminator = null, .aggregator = null };

    try mainRib.setPath(.{ .prefixData = [4]u8{ 10, 0, 1, 0 }, .prefixLength = 24 }, .{ .neighbor = adjRib.neighbor }, attrs);
    try mainRib.setPath(.{ .prefixData = [4]u8{ 10, 0, 2, 0 }, .prefixLength = 24 }, .{ .neighbor = adjRib.neighbor }, attrs);

    try t.expectEqual(mainRib.rib.prefixes.count(), 2);

    var res = try syncFromAdjInToMain(t.allocator, &adjRib, &mainRib);
    defer res.deinit(t.allocator);

    try t.expectEqual(adjRib.adjRib.prefixes.count(), 0);
    try t.expectEqual(mainRib.rib.prefixes.count(), 0);
}

test "Adj -> Main Updates Routes" {
    var adjRib: AdjRibInManager = try .init(t.allocator, ip.IpAddress{ .V4 = try .parse("192.168.0.1") });
    var mainRib: RibManager = try .init(t.allocator);
    defer adjRib.deinit();
    defer mainRib.deinit();

    const asPath: model.ASPath = .{ .allocator = t.allocator, .segments = try t.allocator.dupe(model.ASPathSegment, &[_]model.ASPathSegment{}) };

    const mainAttrs = model.PathAttributes{ .allocator = t.allocator, .origin = .init(.EGP), .asPath = .init(asPath), .nexthop = .init(ip.IpV4Address.init(0, 0, 0, 0)), .localPref = .init(100), .atomicAggregate = .init(false), .multiExitDiscriminator = null, .aggregator = null };
    try mainRib.setPath(.{ .prefixData = [4]u8{ 10, 0, 1, 0 }, .prefixLength = 24 }, .{ .neighbor = adjRib.neighbor }, mainAttrs);

    const adjAttrs = model.PathAttributes{ .allocator = t.allocator, .origin = .init(.EGP), .asPath = .init(asPath), .nexthop = .init(ip.IpV4Address.init(0, 0, 0, 0)), .localPref = .init(110), .atomicAggregate = .init(false), .multiExitDiscriminator = null, .aggregator = null };
    try adjRib.setPath(.{ .prefixData = [4]u8{ 10, 0, 1, 0 }, .prefixLength = 24 }, adjAttrs);

    // Asserts
    try t.expectEqual(adjRib.adjRib.prefixes.count(), 1);
    try t.expectEqual(mainRib.rib.prefixes.count(), 1);
    try t.expectEqual(110, adjRib.adjRib.prefixes.get(.{ .prefixData = [4]u8{ 10, 0, 1, 0 }, .prefixLength = 24 }).?.attrs.localPref.value);
    try t.expectEqual(100, mainRib.rib.prefixes.get(.{ .prefixData = [4]u8{ 10, 0, 1, 0 }, .prefixLength = 24 }).?.paths.get(.{ .neighbor = adjRib.neighbor }).?.attrs.localPref.value);

    var res = try syncFromAdjInToMain(t.allocator, &adjRib, &mainRib);
    defer res.deinit(t.allocator);

    try t.expectEqual(adjRib.adjRib.prefixes.count(), 1);
    try t.expectEqual(mainRib.rib.prefixes.count(), 1);
    try t.expectEqual(110, adjRib.adjRib.prefixes.get(.{ .prefixData = [4]u8{ 10, 0, 1, 0 }, .prefixLength = 24 }).?.attrs.localPref.value);
    try t.expectEqual(110, mainRib.rib.prefixes.get(.{ .prefixData = [4]u8{ 10, 0, 1, 0 }, .prefixLength = 24 }).?.paths.get(.{ .neighbor = adjRib.neighbor }).?.attrs.localPref.value);
}

test "Main Rib Update" {
    var mainRib: RibManager = try .init(t.allocator);
    defer mainRib.deinit();

    const neighbor1: common.Advertiser = .{ .neighbor = .{ .V4 = try .parse("192.168.0.1") } };
    const neighbor2: common.Advertiser = .{ .neighbor = .{ .V4 = try .parse("192.168.0.2") } };

    const route1: model.Route = .{ .prefixData = [4]u8{ 10, 0, 1, 0 }, .prefixLength = 24 };
    const route2: model.Route = .{ .prefixData = [4]u8{ 10, 0, 2, 0 }, .prefixLength = 24 };
    const route3: model.Route = .{ .prefixData = [4]u8{ 10, 0, 3, 0 }, .prefixLength = 24 };

    const asPath: model.ASPath = .{ .allocator = t.allocator, .segments = try t.allocator.dupe(model.ASPathSegment, &[_]model.ASPathSegment{}) };

    const morePrefAttrs = model.PathAttributes{ .allocator = t.allocator, .origin = .init(.EGP), .asPath = .init(asPath), .nexthop = .init(ip.IpV4Address.init(0, 0, 0, 0)), .localPref = .init(110), .atomicAggregate = null, .multiExitDiscriminator = null, .aggregator = null };
    const lessPredAttrs = model.PathAttributes{ .allocator = t.allocator, .origin = .init(.EGP), .asPath = .init(asPath), .nexthop = .init(ip.IpV4Address.init(0, 0, 0, 0)), .localPref = .init(100), .atomicAggregate = null, .multiExitDiscriminator = null, .aggregator = null };

    try mainRib.setPath(route1, neighbor1, morePrefAttrs);
    try mainRib.setPath(route1, neighbor2, lessPredAttrs);
    mainRib.rib.prefixes.getPtr(route1).?.bestPath = neighbor2;

    try mainRib.setPath(route2, neighbor1, morePrefAttrs);
    try mainRib.setPath(route2, neighbor2, lessPredAttrs);
    mainRib.rib.prefixes.getPtr(route2).?.bestPath = neighbor1;

    try mainRib.setPath(route3, neighbor1, lessPredAttrs);
    try mainRib.setPath(route3, neighbor2, lessPredAttrs);
    mainRib.rib.prefixes.getPtr(route3).?.bestPath = neighbor2;

    var res = try updateMainRib(t.allocator, &mainRib);
    defer res.deinit(t.allocator);

    try t.expectEqual(1, res.items.len);

    try t.expect(mainRib.rib.prefixes.get(route1).?.bestPath.?.equals(neighbor1));
    try t.expect(mainRib.rib.prefixes.get(route2).?.bestPath.?.equals(neighbor1));
    try t.expect(mainRib.rib.prefixes.get(route3).?.bestPath.?.equals(neighbor2));
}

test "Main -> Adj Adds Routes" {
    var adjRib: AdjRibOutManager = try .init(t.allocator, ip.IpAddress{ .V4 = try .parse("192.168.0.1") });
    var mainRib: RibManager = try .init(t.allocator);
    defer adjRib.deinit();
    defer mainRib.deinit();

    const asPath: model.ASPath = .{ .allocator = t.allocator, .segments = try t.allocator.dupe(model.ASPathSegment, &[_]model.ASPathSegment{}) };

    const mainAttrs = model.PathAttributes{ .allocator = t.allocator, .origin = .init(.EGP), .asPath = .init(asPath), .nexthop = .init(ip.IpV4Address.init(0, 0, 0, 0)), .localPref = .init(100), .atomicAggregate = null, .multiExitDiscriminator = null, .aggregator = null };
    try mainRib.setPath(.{ .prefixData = [4]u8{ 10, 0, 1, 0 }, .prefixLength = 24 }, .{ .neighbor = adjRib.neighbor }, mainAttrs);
    try mainRib.setPath(.{ .prefixData = [4]u8{ 10, 0, 2, 0 }, .prefixLength = 24 }, .{ .neighbor = adjRib.neighbor }, mainAttrs);

    var res = try syncFromMainToAdjOut(t.allocator, &adjRib, &mainRib);
    defer res.deinit(t.allocator);

    try t.expectEqual(adjRib.adjRib.prefixes.count(), 2);
}

test "Main -> Adj Removes Routes" {
    var adjRib: AdjRibOutManager = try .init(t.allocator, ip.IpAddress{ .V4 = try .parse("192.168.0.1") });
    var mainRib: RibManager = try .init(t.allocator);
    defer adjRib.deinit();
    defer mainRib.deinit();

    const asPath: model.ASPath = .{ .allocator = t.allocator, .segments = try t.allocator.dupe(model.ASPathSegment, &[_]model.ASPathSegment{}) };

    const attrs = model.PathAttributes{ .allocator = t.allocator, .origin = .init(.EGP), .asPath = .init(asPath), .nexthop = .init(ip.IpV4Address.init(0, 0, 0, 0)), .localPref = .init(100), .atomicAggregate = null, .multiExitDiscriminator = null, .aggregator = null };
    try adjRib.setPath(.{ .prefixData = [4]u8{ 10, 0, 1, 0 }, .prefixLength = 24 }, .{ .neighbor = adjRib.neighbor }, attrs);
    try adjRib.setPath(.{ .prefixData = [4]u8{ 10, 0, 2, 0 }, .prefixLength = 24 }, .{ .neighbor = adjRib.neighbor }, attrs);
    try mainRib.setPath(.{ .prefixData = [4]u8{ 10, 0, 2, 0 }, .prefixLength = 24 }, .{ .neighbor = adjRib.neighbor }, attrs);

    var res = try syncFromMainToAdjOut(t.allocator, &adjRib, &mainRib);
    defer res.deinit(t.allocator);

    try t.expectEqual(adjRib.adjRib.prefixes.count(), 1);
}

test "Main -> Adj Updates Routes" {
    var adjRib: AdjRibOutManager = try .init(t.allocator, ip.IpAddress{ .V4 = try .parse("192.168.0.1") });
    var mainRib: RibManager = try .init(t.allocator);
    defer adjRib.deinit();
    defer mainRib.deinit();

    const asPath: model.ASPath = .{ .allocator = t.allocator, .segments = try t.allocator.dupe(model.ASPathSegment, &[_]model.ASPathSegment{}) };

    const mainAttrs = model.PathAttributes{ .allocator = t.allocator, .origin = .init(.EGP), .asPath = .init(asPath), .nexthop = .init(ip.IpV4Address.init(0, 0, 0, 0)), .localPref = .init(100), .atomicAggregate = null, .multiExitDiscriminator = null, .aggregator = null };
    try mainRib.setPath(.{ .prefixData = [4]u8{ 10, 0, 1, 0 }, .prefixLength = 24 }, .{ .neighbor = adjRib.neighbor }, mainAttrs);

    const adjAttrs = model.PathAttributes{ .allocator = t.allocator, .origin = .init(.EGP), .asPath = .init(asPath), .nexthop = .init(ip.IpV4Address.init(0, 0, 0, 0)), .localPref = .init(110), .atomicAggregate = null, .multiExitDiscriminator = null, .aggregator = null };
    try adjRib.setPath(.{ .prefixData = [4]u8{ 10, 0, 1, 0 }, .prefixLength = 24 }, .{ .neighbor = adjRib.neighbor }, adjAttrs);

    // Asserts
    try t.expectEqual(adjRib.adjRib.prefixes.count(), 1);
    try t.expectEqual(mainRib.rib.prefixes.count(), 1);
    try t.expectEqual(110, adjRib.adjRib.prefixes.get(.{ .prefixData = [4]u8{ 10, 0, 1, 0 }, .prefixLength = 24 }).?.attrs.localPref.value);
    try t.expectEqual(100, mainRib.rib.prefixes.get(.{ .prefixData = [4]u8{ 10, 0, 1, 0 }, .prefixLength = 24 }).?.paths.get(.{ .neighbor = adjRib.neighbor }).?.attrs.localPref.value);

    var res = try syncFromMainToAdjOut(t.allocator, &adjRib, &mainRib);
    defer res.deinit(t.allocator);

    try t.expectEqual(adjRib.adjRib.prefixes.count(), 1);
    try t.expectEqual(mainRib.rib.prefixes.count(), 1);
    try t.expectEqual(100, adjRib.adjRib.prefixes.get(.{ .prefixData = [4]u8{ 10, 0, 1, 0 }, .prefixLength = 24 }).?.attrs.localPref.value);
    try t.expectEqual(100, mainRib.rib.prefixes.get(.{ .prefixData = [4]u8{ 10, 0, 1, 0 }, .prefixLength = 24 }).?.paths.get(.{ .neighbor = adjRib.neighbor }).?.attrs.localPref.value);
}

test "aggregateRouteUpdates grouping" {
    const alloc = t.allocator;

    const asPath = model.ASPath.createEmpty(alloc);
    defer asPath.deinit();

    const attrs1 = model.PathAttributes{
        .allocator = alloc,
        .origin = .init(.IGP),
        .asPath = .init(try asPath.clone(alloc)),
        .nexthop = .init(ip.IpV4Address.init(1, 1, 1, 1)),
        .localPref = .init(100),
        .atomicAggregate = null,
        .multiExitDiscriminator = null,
        .aggregator = null,
    };
    defer attrs1.deinit();

    const attrs2 = model.PathAttributes{
        .allocator = alloc,
        .origin = .init(.IGP),
        .asPath = .init(try asPath.clone(alloc)),
        .nexthop = .init(ip.IpV4Address.init(2, 2, 2, 2)),
        .localPref = .init(100),
        .atomicAggregate = null,
        .multiExitDiscriminator = null,
        .aggregator = null,
    };
    defer attrs2.deinit();

    var updates = UpdatesList{};
    defer {
        for (updates.items) |*update| {
            update.@"1".deinit();
        }
        updates.deinit(alloc);
    }

    const route1 = model.Route{ .prefixData = [4]u8{ 10, 0, 1, 0 }, .prefixLength = 24 };
    const route2 = model.Route{ .prefixData = [4]u8{ 10, 0, 2, 0 }, .prefixLength = 24 };
    const route3 = model.Route{ .prefixData = [4]u8{ 10, 0, 3, 0 }, .prefixLength = 24 };

    try updates.append(alloc, .{ route1, .{ .advertiser = .self, .attrs = try attrs1.clone(alloc) } });
    try updates.append(alloc, .{ route2, .{ .advertiser = .self, .attrs = try attrs1.clone(alloc) } });
    try updates.append(alloc, .{ route3, .{ .advertiser = .self, .attrs = try attrs2.clone(alloc) } });

    var aggregated = try aggregateRouteUpdates(alloc, &updates);
    defer aggregated.deinit();

    try t.expectEqual(@as(usize, 2), aggregated.groups.count());

    // Check attrs1 group
    const group1 = aggregated.groups.get(attrs1).?;
    try t.expectEqual(@as(usize, 2), group1.items.len);
    try t.expect(group1.items[0].prefixLength == route1.prefixLength and std.mem.eql(u8, &group1.items[0].prefixData, &route1.prefixData));
    try t.expect(group1.items[1].prefixLength == route2.prefixLength and std.mem.eql(u8, &group1.items[1].prefixData, &route2.prefixData));

    // Check attrs2 group
    const group2 = aggregated.groups.get(attrs2).?;
    try t.expectEqual(@as(usize, 1), group2.items.len);
    try t.expect(group2.items[0].prefixLength == route3.prefixLength and std.mem.eql(u8, &group2.items[0].prefixData, &route3.prefixData));
}

test "filterSplitHorizon" {
    const alloc = t.allocator;
    const neighbor_ip = try ip.IpAddress.parse("192.168.1.1");

    const asPath = model.ASPath.createEmpty(alloc);
    defer asPath.deinit();

    const attrs = model.PathAttributes{
        .allocator = alloc,
        .origin = .init(.IGP),
        .asPath = .init(try asPath.clone(alloc)),
        .nexthop = .init(ip.IpV4Address.init(1, 1, 1, 1)),
        .localPref = .init(100),
        .atomicAggregate = null,
        .multiExitDiscriminator = null,
        .aggregator = null,
    };
    defer attrs.deinit();

    var updates = UpdatesList{};
    defer {
        for (updates.items) |*update| {
            update.@"1".deinit();
        }
        updates.deinit(alloc);
    }

    const route1 = model.Route{ .prefixData = [4]u8{ 10, 0, 1, 0 }, .prefixLength = 24 };
    const route2 = model.Route{ .prefixData = [4]u8{ 10, 0, 2, 0 }, .prefixLength = 24 };

    // Route 1 from self
    try updates.append(alloc, .{ route1, .{ .advertiser = .self, .attrs = try attrs.clone(alloc) } });
    // Route 2 from neighbor
    try updates.append(alloc, .{ route2, .{ .advertiser = .{ .neighbor = neighbor_ip }, .attrs = try attrs.clone(alloc) } });

    try t.expectEqual(@as(usize, 2), updates.items.len);

    var filtered = try filterSplitHorizon(alloc, neighbor_ip, updates);
    defer {
        for (filtered.items) |*update| {
            update.@"1".deinit();
        }
        filtered.deinit(alloc);
    }

    // Route 2 should be filtered out because it came from the same neighbor
    try t.expectEqual(@as(usize, 1), filtered.items.len);
    try t.expect(filtered.items[0].@"0".prefixLength == route1.prefixLength);
    try t.expect(std.mem.eql(u8, &filtered.items[0].@"0".prefixData, &route1.prefixData));

    // Original list should still have 2 items
    try t.expectEqual(@as(usize, 2), updates.items.len);
}
