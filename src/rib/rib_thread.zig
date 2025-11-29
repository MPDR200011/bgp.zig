const std = @import("std");
const ip = @import("ip");
const adjRibManager = @import("adj_rib_manager.zig");
const mainRibManager = @import("main_rib_manager.zig");
const model = @import("../messaging/model.zig");

const AdjRibManager = adjRibManager.AdjRibManager;
const RibManager = mainRibManager.RibManager;

pub fn syncFromAdjInToMain(adjRib: *AdjRibManager, mainRib: *RibManager) !void {
    adjRib.ribMutex.lock();
    mainRib.ribMutex.lock();
    defer adjRib.ribMutex.unlock();
    defer mainRib.ribMutex.unlock();

const SyncResult = struct {
    deletedRoutes: RouteList,
    updatedRoutes: RouteList,

    const init: @This() = .{
        .deletedRoutes = .{},
        .updatedRoutes = .{}
    };

    pub fn deinit(self: *@This(), alloc: Allocator) void {
        self.deletedRoutes.deinit(alloc);
        self.updatedRoutes.deinit(alloc);
    }
};

    // Check for dropped routes
    var mainIt = mainRib.rib.prefixes.iterator();
    while (mainIt.next()) |mainEntry| {
        // Check if route has path from this neighbor
        if (!mainEntry.value_ptr.paths.contains(adjRib.neighbor)) {
            continue;
        }

        // Check if neighbor still has that route
        if (adjRib.adjRib.prefixes.contains(mainEntry.key_ptr.*)) {
            continue;
        }

        // Delete the route from the main rib if not
        _ = mainRib.rib.removePath(mainEntry.key_ptr.*, adjRib.neighbor);
    }


    // Update all paths
    var adjIt = adjRib.adjRib.prefixes.iterator();
    while (adjIt.next()) |adjEntry| {
        try mainRib.rib.setPath(adjEntry.key_ptr.*, adjRib.neighbor, adjEntry.value_ptr.attrs);
fn syncFromMainToAdjOut(alloc: Allocator, adjRib: *AdjRibManager, mainRib: *const RibManager) !SyncResult {
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
        try adjRib.setPath(ribEntry.key_ptr.*, ribEntry.value_ptr.paths.get(ribEntry.value_ptr.bestPath.?).?.attrs);

        try res.updatedRoutes.append(alloc, ribEntry.key_ptr.*);
    }

    return res;
}
}

const t = std.testing;

test "Adj -> Main Adds Routes" {
    var adjRib: AdjRibManager = try .init(t.allocator, ip.IpAddress{.V4 = try .parse("192.168.0.1")});
    var mainRib: RibManager = try .init(t.allocator);
    defer adjRib.deinit();
    defer mainRib.deinit();

    const asPath: model.ASPath = .{
        .allocator = t.allocator,
        .segments = try t.allocator.dupe(model.ASPathSegment, &[_]model.ASPathSegment{})
    };

    const attrs = model.PathAttributes{.allocator = t.allocator, .origin = .EGP, .asPath = asPath , .nexthop = ip.IpV4Address.init(0, 0, 0, 0), .localPref = 100, .atomicAggregate = false, .multiExitDiscriminator = null, .aggregator = null};

    try adjRib.setPath(.{.prefixData = [4]u8{10,0,1,0}, .prefixLength = 24}, attrs);
    try adjRib.setPath(.{.prefixData = [4]u8{10,0,2,0}, .prefixLength = 24}, attrs);

    try syncFromAdjInToMain(&adjRib, &mainRib);

    try t.expectEqual(adjRib.adjRib.prefixes.count(), 2);
    try t.expect(adjRib.adjRib.prefixes.contains(.{.prefixData = [4]u8{10,0,1,0}, .prefixLength = 24}));
    try t.expect(adjRib.adjRib.prefixes.contains(.{.prefixData = [4]u8{10,0,2,0}, .prefixLength = 24}));

    try t.expectEqual(mainRib.rib.prefixes.count(), 2);
    try t.expect(mainRib.rib.prefixes.contains(.{.prefixData = [4]u8{10,0,1,0}, .prefixLength = 24}));
    try t.expect(mainRib.rib.prefixes.contains(.{.prefixData = [4]u8{10,0,2,0}, .prefixLength = 24}));
}

test "Adj -> Main Removes Routes" {
    var adjRib: AdjRibManager = try .init(t.allocator, ip.IpAddress{.V4 = try .parse("192.168.0.1")});
    var mainRib: RibManager = try .init(t.allocator);
    defer adjRib.deinit();
    defer mainRib.deinit();

    const asPath: model.ASPath = .{
        .allocator = t.allocator,
        .segments = try t.allocator.dupe(model.ASPathSegment, &[_]model.ASPathSegment{})
    };

    const attrs = model.PathAttributes{.allocator = t.allocator, .origin = .EGP, .asPath = asPath , .nexthop = ip.IpV4Address.init(0, 0, 0, 0), .localPref = 100, .atomicAggregate = false, .multiExitDiscriminator = null, .aggregator = null};

    try mainRib.setPath(.{.prefixData = [4]u8{10,0,1,0}, .prefixLength = 24}, adjRib.neighbor, attrs);
    try mainRib.setPath(.{.prefixData = [4]u8{10,0,2,0}, .prefixLength = 24}, adjRib.neighbor, attrs);

    try t.expectEqual(mainRib.rib.prefixes.count(), 2);

    try syncFromAdjInToMain(&adjRib, &mainRib);

    try t.expectEqual(adjRib.adjRib.prefixes.count(), 0);
    try t.expectEqual(mainRib.rib.prefixes.count(), 0);
}

test "Adj -> Main Updates Routes" {
    var adjRib: AdjRibManager = try .init(t.allocator, ip.IpAddress{.V4 = try .parse("192.168.0.1")});
    var mainRib: RibManager = try .init(t.allocator);
    defer adjRib.deinit();
    defer mainRib.deinit();

    const asPath: model.ASPath = .{
        .allocator = t.allocator,
        .segments = try t.allocator.dupe(model.ASPathSegment, &[_]model.ASPathSegment{})
    };

    const mainAttrs = model.PathAttributes{.allocator = t.allocator, .origin = .EGP, .asPath = asPath , .nexthop = ip.IpV4Address.init(0, 0, 0, 0), .localPref = 100, .atomicAggregate = false, .multiExitDiscriminator = null, .aggregator = null};
    try mainRib.setPath(.{.prefixData = [4]u8{10,0,1,0}, .prefixLength = 24}, adjRib.neighbor, mainAttrs);

    const adjAttrs = model.PathAttributes{.allocator = t.allocator, .origin = .EGP, .asPath = asPath , .nexthop = ip.IpV4Address.init(0, 0, 0, 0), .localPref = 110, .atomicAggregate = false, .multiExitDiscriminator = null, .aggregator = null};
    try adjRib.setPath(.{.prefixData = [4]u8{10,0,1,0}, .prefixLength = 24}, adjAttrs);


    // Asserts
    try t.expectEqual(adjRib.adjRib.prefixes.count(), 1);
    try t.expectEqual(mainRib.rib.prefixes.count(), 1);
    try t.expectEqual(110, adjRib.adjRib.prefixes.get(.{.prefixData = [4]u8{10,0,1,0}, .prefixLength = 24}).?.attrs.localPref);
    try t.expectEqual(100, mainRib.rib.prefixes.get(.{.prefixData = [4]u8{10,0,1,0}, .prefixLength = 24}).?.paths.get(adjRib.neighbor).?.attrs.localPref);

    try syncFromAdjInToMain(&adjRib, &mainRib);

    try t.expectEqual(adjRib.adjRib.prefixes.count(), 1);
    try t.expectEqual(mainRib.rib.prefixes.count(), 1);
    try t.expectEqual(110, adjRib.adjRib.prefixes.get(.{.prefixData = [4]u8{10,0,1,0}, .prefixLength = 24}).?.attrs.localPref);
    try t.expectEqual(110, mainRib.rib.prefixes.get(.{.prefixData = [4]u8{10,0,1,0}, .prefixLength = 24}).?.paths.get(adjRib.neighbor).?.attrs.localPref);
}

test "Main -> Adj Adds Routes" {
    var adjRib: AdjRibManager = try .init(t.allocator, ip.IpAddress{.V4 = try .parse("192.168.0.1")});
    var mainRib: RibManager = try .init(t.allocator);
    defer adjRib.deinit();
    defer mainRib.deinit();

    const asPath: model.ASPath = .{
        .allocator = t.allocator,
        .segments = try t.allocator.dupe(model.ASPathSegment, &[_]model.ASPathSegment{})
    };

    const mainAttrs = model.PathAttributes{.allocator = t.allocator, .origin = .EGP, .asPath = asPath , .nexthop = ip.IpV4Address.init(0, 0, 0, 0), .localPref = 100, .atomicAggregate = false, .multiExitDiscriminator = null, .aggregator = null};
    try mainRib.setPath(.{.prefixData = [4]u8{10,0,1,0}, .prefixLength = 24}, adjRib.neighbor, mainAttrs);
    try mainRib.setPath(.{.prefixData = [4]u8{10,0,2,0}, .prefixLength = 24}, adjRib.neighbor, mainAttrs);


    var res = try syncFromMainToAdjOut(t.allocator, &adjRib, &mainRib);
    defer res.deinit(t.allocator);

    try t.expectEqual(adjRib.adjRib.prefixes.count(), 2);
}

test "Main -> Adj Removes Routes" {
    var adjRib: AdjRibManager = try .init(t.allocator, ip.IpAddress{.V4 = try .parse("192.168.0.1")});
    var mainRib: RibManager = try .init(t.allocator);
    defer adjRib.deinit();
    defer mainRib.deinit();

    const asPath: model.ASPath = .{
        .allocator = t.allocator,
        .segments = try t.allocator.dupe(model.ASPathSegment, &[_]model.ASPathSegment{})
    };

    const attrs = model.PathAttributes{.allocator = t.allocator, .origin = .EGP, .asPath = asPath , .nexthop = ip.IpV4Address.init(0, 0, 0, 0), .localPref = 100, .atomicAggregate = false, .multiExitDiscriminator = null, .aggregator = null};
    try adjRib.setPath(.{.prefixData = [4]u8{10,0,1,0}, .prefixLength = 24}, attrs);
    try adjRib.setPath(.{.prefixData = [4]u8{10,0,2,0}, .prefixLength = 24}, attrs);
    try mainRib.setPath(.{.prefixData = [4]u8{10,0,2,0}, .prefixLength = 24}, adjRib.neighbor, attrs);


    var res = try syncFromMainToAdjOut(t.allocator, &adjRib, &mainRib);
    defer res.deinit(t.allocator);

    try t.expectEqual(adjRib.adjRib.prefixes.count(), 1);
}

test "Main -> Adj Updates Routes" {
    var adjRib: AdjRibManager = try .init(t.allocator, ip.IpAddress{.V4 = try .parse("192.168.0.1")});
    var mainRib: RibManager = try .init(t.allocator);
    defer adjRib.deinit();
    defer mainRib.deinit();

    const asPath: model.ASPath = .{
        .allocator = t.allocator,
        .segments = try t.allocator.dupe(model.ASPathSegment, &[_]model.ASPathSegment{})
    };

    const mainAttrs = model.PathAttributes{.allocator = t.allocator, .origin = .EGP, .asPath = asPath , .nexthop = ip.IpV4Address.init(0, 0, 0, 0), .localPref = 100, .atomicAggregate = false, .multiExitDiscriminator = null, .aggregator = null};
    try mainRib.setPath(.{.prefixData = [4]u8{10,0,1,0}, .prefixLength = 24}, adjRib.neighbor, mainAttrs);

    const adjAttrs = model.PathAttributes{.allocator = t.allocator, .origin = .EGP, .asPath = asPath , .nexthop = ip.IpV4Address.init(0, 0, 0, 0), .localPref = 110, .atomicAggregate = false, .multiExitDiscriminator = null, .aggregator = null};
    try adjRib.setPath(.{.prefixData = [4]u8{10,0,1,0}, .prefixLength = 24}, adjAttrs);


    // Asserts
    try t.expectEqual(adjRib.adjRib.prefixes.count(), 1);
    try t.expectEqual(mainRib.rib.prefixes.count(), 1);
    try t.expectEqual(110, adjRib.adjRib.prefixes.get(.{.prefixData = [4]u8{10,0,1,0}, .prefixLength = 24}).?.attrs.localPref);
    try t.expectEqual(100, mainRib.rib.prefixes.get(.{.prefixData = [4]u8{10,0,1,0}, .prefixLength = 24}).?.paths.get(adjRib.neighbor).?.attrs.localPref);

    var res = try syncFromMainToAdjOut(t.allocator, &adjRib, &mainRib);
    defer res.deinit(t.allocator);

    try t.expectEqual(adjRib.adjRib.prefixes.count(), 1);
    try t.expectEqual(mainRib.rib.prefixes.count(), 1);
    try t.expectEqual(100, adjRib.adjRib.prefixes.get(.{.prefixData = [4]u8{10,0,1,0}, .prefixLength = 24}).?.attrs.localPref);
    try t.expectEqual(100, mainRib.rib.prefixes.get(.{.prefixData = [4]u8{10,0,1,0}, .prefixLength = 24}).?.paths.get(adjRib.neighbor).?.attrs.localPref);
}
