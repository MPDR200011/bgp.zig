const std = @import("std");
const ribModel = @import("../rib/model.zig");
const messageModel = @import("../messaging/model.zig");
const session = @import("../sessions/session.zig");

const Allocator = std.mem.Allocator;

pub fn convertAttributeListToUnifiedStruct(allocator: Allocator, peerType: session.Session.PeerType, attrList: messageModel.AttributeList) !ribModel.PathAttributes {
    var attributes: ribModel.PathAttributes = .empty;
    attributes.allocator = allocator;

    attributes.localPref = .{
        .flags = 0,
        .value = 100
    };

    var originRead: bool = false;
    var asPathRead: bool = false;
    var nextHopRead: bool = false;

    for (attrList.list.items) |attr| {
        switch (attr) {
            .Origin => |origin| {
                attributes.origin = origin;
                originRead = true;
            },
            .AsPath => |asPath| {
                attributes.asPath = asPath;
                attributes.asPath.value = try asPath.value.clone(allocator);
                asPathRead = true;
            },
            .Nexthop => |nexthop| {
                attributes.nexthop = nexthop;
                nextHopRead = true;
            },
            .MultiExitDiscriminator => |med| {
                attributes.multiExitDiscriminator = med;
            },
            .LocalPref => |lpref| {
                if (peerType == .Internal) {
                    attributes.localPref = lpref;
                }
            },
            .AtomicAggregate => |aAgg| {
                attributes.atomicAggregate = aAgg;
            },
            .Aggregator => |agg| {
                attributes.aggregator = agg;
            },
            .Unknown => |uk| {
                std.log.info("Unknown parameter (type={})", .{uk.value.typeCode});
            }
        }
    }
    
    if (!originRead) {
        return error.MissingOriginAttribute;
    }
    if (!asPathRead) {
        return error.MissingASPathAttribute;
    }
    if (!nextHopRead) {
        return error.MissingNexthopAttribute;
    }

    return attributes;
}

pub fn convertUnifiedStructToAttributeList(allocator: Allocator, peerType: session.Session.PeerType, attrs: ribModel.PathAttributes) !messageModel.AttributeList {
    var attributes: messageModel.AttributeList = .{
        .alloc = allocator,
        .list = try .initCapacity(allocator, 3),
    };
    errdefer attributes.deinit();

    try attributes.list.append(allocator, .{ .Origin = attrs.origin });
    {
        var asPath = attrs.asPath;
        asPath.value = try attrs.asPath.value.clone(allocator);
        try attributes.list.append(allocator, .{ .AsPath = asPath });
    }
    try attributes.list.append(allocator, .{ .Nexthop = attrs.nexthop });
    if (attrs.multiExitDiscriminator) |med| {
        try attributes.list.append(allocator, .{ .MultiExitDiscriminator = med });
    }
    if (peerType == .Internal) {
        try attributes.list.append(allocator, .{ .LocalPref = attrs.localPref });
    }
    if (attrs.atomicAggregate) |aAgg| {
        try attributes.list.append(allocator, .{ .AtomicAggregate = aAgg });
    }
    if (attrs.aggregator) |agg| {
        try attributes.list.append(allocator, .{ .Aggregator = agg });
    }

    return attributes;
}

test "symmetry between attribute conversions obj -> list -> obj" {
    const testing = std.testing;
    const ip = @import("ip");
    
    // Create a robust initial structure
    const as_path_seg = ribModel.ASPathSegment{
        .allocator = testing.allocator,
        .segType = .AS_Sequence,
        .contents = try testing.allocator.dupe(u16, &[_]u16{ 1, 2, 3 }),
    };
    defer as_path_seg.deinit();

    const as_path = ribModel.ASPath{
        .allocator = testing.allocator,
        .segments = try testing.allocator.dupe(ribModel.ASPathSegment, &[_]ribModel.ASPathSegment{try as_path_seg.clone(testing.allocator)}),
    };

    const attrs1 = ribModel.PathAttributes{
        .allocator = testing.allocator,
        .origin = .init(.IGP),
        .asPath = .init(as_path),
        .nexthop = .init(try ip.IpV4Address.parse("1.1.1.1")),
        .localPref = .init(200),
        .atomicAggregate = .init(false),
        .multiExitDiscriminator = .init(10),
        .aggregator = .init(.{
            .as = 65001,
            .address = try ip.IpV4Address.parse("2.2.2.2"),
        }),
    };
    defer attrs1.deinit();

    // Test Internal peer type encoding/decoding symmetry
    {
        var attrList = try convertUnifiedStructToAttributeList(testing.allocator, .Internal, attrs1);
        defer attrList.deinit();

        const attrs2 = try convertAttributeListToUnifiedStruct(testing.allocator, .Internal, attrList);
        defer attrs2.deinit();

        try testing.expect(attrs1.equal(&attrs2));
    }

    // Test External peer type encoding/decoding symmetry
    {
        var attrList = try convertUnifiedStructToAttributeList(testing.allocator, .External, attrs1);
        defer attrList.deinit();

        const attrs3 = try convertAttributeListToUnifiedStruct(testing.allocator, .External, attrList);
        defer attrs3.deinit();

        // LocalPref is forced to 100 on reading External attributes
        var expected_attrs3 = try attrs1.clone(testing.allocator);
        defer expected_attrs3.deinit();
        expected_attrs3.localPref.value = 100;

        try testing.expect(expected_attrs3.equal(&attrs3));
    }
}
