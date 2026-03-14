const std = @import("std");
const ribModel = @import("../rib/model.zig");
const messageModel = @import("../messaging/model.zig");
const session = @import("../sessions/session.zig");

const Allocator = std.mem.Allocator;

pub fn convertAttributeListToUnifiedStruct(allocator: Allocator, peerType: session.Session.PeerType, attrList: messageModel.AttributeList) !?ribModel.PathAttributes {
    if (attrList.list.items.len == 0) {
        return null;
    }
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
