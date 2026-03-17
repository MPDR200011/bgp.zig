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

    var unknownAttributes: std.ArrayListUnmanaged(ribModel.UnknownAttr) = .empty;
    defer unknownAttributes.deinit(attributes.allocator);

    // FIXME: validate attribute flags

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
                attributes.nexthop = .{
                    .flags = nexthop.flags,
                    .value = .{ .Address = nexthop.value },
                };
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
                if (uk.isOptional() and uk.isTransitive()) {
                    try unknownAttributes.append(allocator, .{
                        .flags = uk.flags | ribModel.ATTR_PARTIAL_FLAG,
                        .value = try uk.value.clone(attributes.allocator),
                    });
                } else {
                    std.log.info("Dropping unknown non-optional attribute (type={})", .{uk.value.typeCode});
                }
            }
        }
    }

    const sortFn = struct {
        fn lessThan(_: void, a: ribModel.UnknownAttr, b: ribModel.UnknownAttr) bool {
            return a.value.typeCode < b.value.typeCode;
        }
    }.lessThan;
    std.mem.sort(ribModel.UnknownAttr, unknownAttributes.items, {}, sortFn);

    attributes.unknownAttributes = try unknownAttributes.toOwnedSlice(attributes.allocator);
    
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

    try attributes.list.append(allocator, .{ .Origin = .{
        .flags = ribModel.ATTR_TRANSITIVE_FLAG,
        .value = attrs.origin.value
    } });
    {
        try attributes.list.append(allocator, .{ .AsPath = .{ 
            .flags = ribModel.ATTR_TRANSITIVE_FLAG,
            .value = try attrs.asPath.value.clone(allocator),
        } });
    }
    std.debug.assert(std.meta.activeTag(attrs.nexthop.value) == .Address);
    try attributes.list.append(allocator, .{ .Nexthop = .{ 
        .flags = ribModel.ATTR_TRANSITIVE_FLAG,
        .value = attrs.nexthop.value.Address,
    } });

    // MED isn't propagated to other speakers
    // TODO: "MULTI_EXIT_DISC attribute MAY be propagated over IBGP to other
    // BGP speakers within the same AS"
    // if (attrs.multiExitDiscriminator) |med| {
    //     try attributes.list.append(allocator, .{ .MultiExitDiscriminator = med });
    // }

    if (peerType == .Internal) {
        try attributes.list.append(allocator, .{ .LocalPref = .{
            .flags = ribModel.ATTR_TRANSITIVE_FLAG,
            .value = attrs.localPref.value,
        } });
    }
    if (attrs.atomicAggregate) |aAgg| {
        try attributes.list.append(allocator, .{ .AtomicAggregate = .{
            .flags = ribModel.ATTR_TRANSITIVE_FLAG,
            .value = aAgg.value,
        } });
    }
    if (attrs.aggregator) |agg| {
        try attributes.list.append(allocator, .{ .Aggregator = .{
            .flags = (agg.flags & ribModel.ATTR_PARTIAL_FLAG) | ribModel.ATTR_OPTIONAL_FLAG | ribModel.ATTR_TRANSITIVE_FLAG,
            .value = agg.value,
        } });
    }

    for (attrs.unknownAttributes) |uk| {
        try attributes.list.append(allocator, .{ .Unknown = .{
            .flags = uk.flags | ribModel.ATTR_PARTIAL_FLAG,
            .value = try uk.value.clone(allocator),
        } });
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

    const unknown_attr = ribModel.UnknownAttr{
        .flags = ribModel.ATTR_OPTIONAL_FLAG | ribModel.ATTR_TRANSITIVE_FLAG | ribModel.ATTR_PARTIAL_FLAG,
        .value = .{
            .allocator = testing.allocator,
            .typeCode = 100,
            .value = try testing.allocator.dupe(u8, &[_]u8{ 1, 2, 3, 4 }),
        },
    };

    const attrs1 = ribModel.PathAttributes{
        .allocator = testing.allocator,
        .origin = .init(.IGP),
        .asPath = .init(as_path),
        .nexthop = .init(.{ .Address = try ip.IpV4Address.parse("1.1.1.1") }),
        .localPref = .init(200),
        .atomicAggregate = .init(false),
        .multiExitDiscriminator = .init(10),
        .aggregator = .init(.{
            .as = 65001,
            .address = try ip.IpV4Address.parse("2.2.2.2"),
        }),
        .unknownAttributes = try testing.allocator.dupe(ribModel.UnknownAttr, &[_]ribModel.UnknownAttr{unknown_attr}),
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
