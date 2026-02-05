const std = @import("std");
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

const SyncResult = struct {
    deletedRoutes: RouteList,
    updatedRoutes: UpdatesList,

    const init: @This() = .{ .deletedRoutes = .{}, .updatedRoutes = .{} };

    pub fn deinit(self: *@This(), alloc: Allocator) void {
        self.deletedRoutes.deinit(alloc);
        self.updatedRoutes.deinit(alloc);
    }
};

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

const RibThreadContext = struct {
    allocator: Allocator,
    mainRib: *RibManager,
    peerMap: *PeerMap,
};

fn mainRibThread(ctx: RibThreadContext) !void {
    ctx.mainRib.ribMutex.lock();
    defer ctx.adjRib.ribMutex.unlock();

    // sync adj-in -> main rib
    var peerIt = ctx.peerMap.valueIterator();
    while (peerIt.next()) |peer| {
        // Lock the session to grab the adjIn reference
        peer.*.session.mutex.lock();

        const adjIn = &peer.*.session.adjRibInManager;
        adjIn.ribMutex.lock();
        defer adjIn.ribMutex.unlock();

        // Once we grab the adjIn and lock it we can unlock the session
        // While the adjIn is locked the session can't terminate
        peer.*.session.mutex.unlock();

        const result = try syncFromAdjInToMain(ctx.allocator, adjIn, ctx.mainRib);
        result.deinit(ctx.allocator);
    }

    // main rib best path selection
    const updatedRoutes = try updateMainRib(ctx.allocator, ctx.mainRib);
    defer updatedRoutes.deinit(ctx.allocator);

    // sync main -> adj-out ribs
    peerIt = ctx.peerMap.valueIterator();
    while (peerIt.next()) |peer| {
        // Lock the session to grab the adjIn reference
        peer.*.session.mutex.lock();

        const adjOut = &peer.*.session.adjRibOutManager;
        adjOut.ribMutex.lock();
        defer adjOut.ribMutex.unlock();

        // Once we grab the adjOut and lock it we can unlock the session
        // While the adjOut is locked the session can't terminate
        peer.*.session.mutex.unlock();

        const result = try syncFromMainToAdjOut(ctx.allocator, adjOut, ctx.mainRib, updatedRoutes);
        defer result.deinit(ctx.allocator);

        // TODO Aggregate routes

        // FIXME: THIS SHIT IS STUPID
        // FIXME: Don't send update back to neighbor that sent it to us in the first place
        const updateAttrs = &adjOut.*.?.adjRib.prefixes.getPtr(result.updatedRoutes[0]).?.attrs;
        peer.*.session.sendMessage(.{ .UPDATE = .init(ctx.allocator, result.deletedRoutes, result.updatedRoutes, updateAttrs.*) });
    }

    // TODO: send out messages
}

const t = std.testing;

test "Adj -> Main Adds Routes" {
    var adjRib: AdjRibInManager = try .init(t.allocator, ip.IpAddress{ .V4 = try .parse("192.168.0.1") });
    var mainRib: RibManager = try .init(t.allocator);
    defer adjRib.deinit();
    defer mainRib.deinit();

    const asPath: model.ASPath = .{ .allocator = t.allocator, .segments = try t.allocator.dupe(model.ASPathSegment, &[_]model.ASPathSegment{}) };

    const attrs = model.PathAttributes{ .allocator = t.allocator, .origin = .EGP, .asPath = asPath, .nexthop = ip.IpV4Address.init(0, 0, 0, 0), .localPref = 100, .atomicAggregate = false, .multiExitDiscriminator = null, .aggregator = null };

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

    const attrs = model.PathAttributes{ .allocator = t.allocator, .origin = .EGP, .asPath = asPath, .nexthop = ip.IpV4Address.init(0, 0, 0, 0), .localPref = 100, .atomicAggregate = false, .multiExitDiscriminator = null, .aggregator = null };

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

    const mainAttrs = model.PathAttributes{ .allocator = t.allocator, .origin = .EGP, .asPath = asPath, .nexthop = ip.IpV4Address.init(0, 0, 0, 0), .localPref = 100, .atomicAggregate = false, .multiExitDiscriminator = null, .aggregator = null };
    try mainRib.setPath(.{ .prefixData = [4]u8{ 10, 0, 1, 0 }, .prefixLength = 24 }, .{ .neighbor = adjRib.neighbor }, mainAttrs);

    const adjAttrs = model.PathAttributes{ .allocator = t.allocator, .origin = .EGP, .asPath = asPath, .nexthop = ip.IpV4Address.init(0, 0, 0, 0), .localPref = 110, .atomicAggregate = false, .multiExitDiscriminator = null, .aggregator = null };
    try adjRib.setPath(.{ .prefixData = [4]u8{ 10, 0, 1, 0 }, .prefixLength = 24 }, adjAttrs);

    // Asserts
    try t.expectEqual(adjRib.adjRib.prefixes.count(), 1);
    try t.expectEqual(mainRib.rib.prefixes.count(), 1);
    try t.expectEqual(110, adjRib.adjRib.prefixes.get(.{ .prefixData = [4]u8{ 10, 0, 1, 0 }, .prefixLength = 24 }).?.attrs.localPref);
    try t.expectEqual(100, mainRib.rib.prefixes.get(.{ .prefixData = [4]u8{ 10, 0, 1, 0 }, .prefixLength = 24 }).?.paths.get(.{ .neighbor = adjRib.neighbor }).?.attrs.localPref);

    var res = try syncFromAdjInToMain(t.allocator, &adjRib, &mainRib);
    defer res.deinit(t.allocator);

    try t.expectEqual(adjRib.adjRib.prefixes.count(), 1);
    try t.expectEqual(mainRib.rib.prefixes.count(), 1);
    try t.expectEqual(110, adjRib.adjRib.prefixes.get(.{ .prefixData = [4]u8{ 10, 0, 1, 0 }, .prefixLength = 24 }).?.attrs.localPref);
    try t.expectEqual(110, mainRib.rib.prefixes.get(.{ .prefixData = [4]u8{ 10, 0, 1, 0 }, .prefixLength = 24 }).?.paths.get(.{ .neighbor = adjRib.neighbor }).?.attrs.localPref);
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
    const morePrefAttrs = model.PathAttributes{ .allocator = t.allocator, .origin = .EGP, .asPath = asPath, .nexthop = ip.IpV4Address.init(0, 0, 0, 0), .localPref = 110, .atomicAggregate = false, .multiExitDiscriminator = null, .aggregator = null };
    const lessPredAttrs = model.PathAttributes{ .allocator = t.allocator, .origin = .EGP, .asPath = asPath, .nexthop = ip.IpV4Address.init(0, 0, 0, 0), .localPref = 100, .atomicAggregate = false, .multiExitDiscriminator = null, .aggregator = null };

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

    const mainAttrs = model.PathAttributes{ .allocator = t.allocator, .origin = .EGP, .asPath = asPath, .nexthop = ip.IpV4Address.init(0, 0, 0, 0), .localPref = 100, .atomicAggregate = false, .multiExitDiscriminator = null, .aggregator = null };
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

    const attrs = model.PathAttributes{ .allocator = t.allocator, .origin = .EGP, .asPath = asPath, .nexthop = ip.IpV4Address.init(0, 0, 0, 0), .localPref = 100, .atomicAggregate = false, .multiExitDiscriminator = null, .aggregator = null };
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

    const mainAttrs = model.PathAttributes{ .allocator = t.allocator, .origin = .EGP, .asPath = asPath, .nexthop = ip.IpV4Address.init(0, 0, 0, 0), .localPref = 100, .atomicAggregate = false, .multiExitDiscriminator = null, .aggregator = null };
    try mainRib.setPath(.{ .prefixData = [4]u8{ 10, 0, 1, 0 }, .prefixLength = 24 }, .{ .neighbor = adjRib.neighbor }, mainAttrs);

    const adjAttrs = model.PathAttributes{ .allocator = t.allocator, .origin = .EGP, .asPath = asPath, .nexthop = ip.IpV4Address.init(0, 0, 0, 0), .localPref = 110, .atomicAggregate = false, .multiExitDiscriminator = null, .aggregator = null };
    try adjRib.setPath(.{ .prefixData = [4]u8{ 10, 0, 1, 0 }, .prefixLength = 24 }, .{ .neighbor = adjRib.neighbor }, adjAttrs);

    // Asserts
    try t.expectEqual(adjRib.adjRib.prefixes.count(), 1);
    try t.expectEqual(mainRib.rib.prefixes.count(), 1);
    try t.expectEqual(110, adjRib.adjRib.prefixes.get(.{ .prefixData = [4]u8{ 10, 0, 1, 0 }, .prefixLength = 24 }).?.attrs.localPref);
    try t.expectEqual(100, mainRib.rib.prefixes.get(.{ .prefixData = [4]u8{ 10, 0, 1, 0 }, .prefixLength = 24 }).?.paths.get(.{ .neighbor = adjRib.neighbor }).?.attrs.localPref);

    var res = try syncFromMainToAdjOut(t.allocator, &adjRib, &mainRib);
    defer res.deinit(t.allocator);

    try t.expectEqual(adjRib.adjRib.prefixes.count(), 1);
    try t.expectEqual(mainRib.rib.prefixes.count(), 1);
    try t.expectEqual(100, adjRib.adjRib.prefixes.get(.{ .prefixData = [4]u8{ 10, 0, 1, 0 }, .prefixLength = 24 }).?.attrs.localPref);
    try t.expectEqual(100, mainRib.rib.prefixes.get(.{ .prefixData = [4]u8{ 10, 0, 1, 0 }, .prefixLength = 24 }).?.paths.get(.{ .neighbor = adjRib.neighbor }).?.attrs.localPref);
}
