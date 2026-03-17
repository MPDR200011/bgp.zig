const std = @import("std");
const ip = @import("ip");
const consts = @import("../consts.zig");
const messageModel = @import("../model.zig");
const ribModel = @import("../../rib/model.zig");

const PathAttribute = messageModel.PathAttribute;
const AttributeList = messageModel.AttributeList;

const AsPath = ribModel.ASPath;

fn calculateRoutesLength(routes: []const ribModel.Route) usize {
    var total: usize = 0;
    for (routes) |route| {
        total += 1;

        const bytes = (route.prefixLength / 8) + @as(usize, if (route.prefixLength % 8 > 0) 1 else 0);
        total += bytes;
    }

    return total;
}

fn writeRoutes(routes: []const ribModel.Route, writer: *std.Io.Writer) !void {
    for (routes) |route| {
        try writer.writeInt(u8, route.prefixLength, .big);

        const bytes = (route.prefixLength / 8) + @as(usize, if (route.prefixLength % 8 > 0) 1 else 0);
        try writer.writeAll(route.prefixData[0..bytes]);
    }
}

fn calculateASPathByteLength(asPath: *const AsPath) usize {
    var result: usize = 0;
    for (asPath.segments) |segment| {
        // Segment Type + Segment length
        result += 2;
        result += segment.contents.len * 2;
    }
    return result;
}

fn calculateAttributesLength(attrs: *const AttributeList) usize {
    var result: usize = 0;

    for (attrs.list.items) |*attr| {
        const dataLength: usize = size: switch (attr.*) {
            .Origin => 1,
            .AsPath => |*asPath| {
                break :size calculateASPathByteLength(&asPath.value);
            },
            .Nexthop => 4,
            .MultiExitDiscriminator => 4,
            .LocalPref => 4,
            .AtomicAggregate => 0,
            .Aggregator => 6,
            .Unknown => |*uk| {
                break :size uk.value.value.len;
            }
        };

        const lengthFieldSize: usize = if (dataLength > 255) 2 else 1;
        result += 2 + lengthFieldSize + dataLength;
    }

    return result;
}

fn writeLocalPref(writer: *std.Io.Writer, localPref: * const ribModel.LocalPrefAttr) !void {
    try writer.writeInt(u32, localPref.value, .big);
}

fn writeAttributes(attrs: *const AttributeList, writer: *std.Io.Writer) !void {
    for (attrs.list.items) |attr| {
        switch (attr) {
            .Origin => |origin| {
                try writer.writeInt(u8, origin.flags, .big);
                try writer.writeInt(u8, 1, .big);
                try writer.writeInt(u8, 1, .big);
                try writer.writeInt(u8, @intFromEnum(origin.value), .big);
            },
            .AsPath => |asPath| {
                const asPathDataLen = calculateASPathByteLength(&asPath.value);
                const isExtendedLen = asPathDataLen > 255;
                if (isExtendedLen) {
                    try writer.writeInt(u8, asPath.flags | ribModel.ATTR_EXTENDED_LENGTH_FLAG, .big);
                } else {
                    try writer.writeInt(u8, asPath.flags & (~ribModel.ATTR_EXTENDED_LENGTH_FLAG), .big);
                }
                try writer.writeInt(u8, 2, .big);
                if (isExtendedLen) {
                    try writer.writeInt(u16, @intCast(asPathDataLen), .big);
                } else {
                    try writer.writeInt(u8, @intCast(asPathDataLen), .big);
                }
                for (asPath.value.segments) |segment| {
                    try writer.writeInt(u8, @intFromEnum(segment.segType), .big);
                    try writer.writeInt(u8, @intCast(segment.contents.len), .big);
                    for (segment.contents) |asn| {
                        try writer.writeInt(u16, asn, .big);
                    }
                }
            },
            .Nexthop => |nexthop| {
                try writer.writeInt(u8, nexthop.flags, .big);
                try writer.writeInt(u8, 3, .big);
                try writer.writeInt(u8, 4, .big);
                try writer.writeAll(&nexthop.value.address);
            },
            .MultiExitDiscriminator=> |med| {
                try writer.writeInt(u8, med.flags, .big);
                try writer.writeInt(u8, 4, .big);
                try writer.writeInt(u8, 4, .big);
                try writer.writeInt(u32, med.value, .big);
            },
            .LocalPref => |*localPref| {
                try writer.writeInt(u8, localPref.flags, .big);
                try writer.writeInt(u8, 5, .big);
                try writer.writeInt(u8, 4, .big);
                try writeLocalPref(writer, localPref);
            },
            .AtomicAggregate => |aAgg| {
                try writer.writeInt(u8, aAgg.flags, .big);
                try writer.writeInt(u8, 6, .big);
                try writer.writeInt(u8, 0, .big);
            },
            .Aggregator => |agg| {
                try writer.writeInt(u8, agg.flags, .big);
                try writer.writeInt(u8, 7, .big);
                try writer.writeInt(u8, 6, .big);
                try writer.writeInt(u16, agg.value.as, .big);
                try writer.writeAll(&agg.value.address.address);
            },
            .Unknown => |uk| {
                const isExtendedLen = uk.value.value.len > 255;
                if (isExtendedLen) {
                    try writer.writeInt(u8, uk.flags | ribModel.ATTR_EXTENDED_LENGTH_FLAG, .big);
                } else {
                    try writer.writeInt(u8, uk.flags & (~ribModel.ATTR_EXTENDED_LENGTH_FLAG), .big);
                }

                try writer.writeInt(u8, uk.value.typeCode, .big); // Type

                if (isExtendedLen) {
                    try writer.writeInt(u16, @intCast(uk.value.value.len), .big);
                } else {
                    try writer.writeInt(u8, @intCast(uk.value.value.len), .big);
                }

                try writer.writeAll(uk.value.value);
            }
        }
    }
}

pub fn writeUpdateBody(msg: messageModel.UpdateMessage, writer: *std.Io.Writer) !void {
    std.log.debug(
        "sending UPDATE(withdrawn={d}, advertised={d}, attrs count={d})", 
        .{msg.withdrawnRoutes.len, msg.advertisedRoutes.len, msg.pathAttributes.list.items.len} 
    );

    try writer.writeInt(u16, @intCast(calculateRoutesLength(msg.withdrawnRoutes)), .big);
    try writeRoutes(msg.withdrawnRoutes, writer);

    // FIXME: Maybe it'll be better in the long run to just pre-write to buffer
    // and print out the buffer length, instead of keeping two different
    // implementations of kinda the same thing. Although it does have the
    // benefit of little to no allocs
    try writer.writeInt(u16, @intCast(calculateAttributesLength(&msg.pathAttributes)), .big);
    try writeAttributes(&msg.pathAttributes, writer);

    try writeRoutes(msg.advertisedRoutes, writer);
}

const testing = std.testing;

test "calculateRoutesLength()" {
    try testing.expectEqual(0, calculateRoutesLength(&[_]ribModel.Route{}));
    try testing.expectEqual(16, calculateRoutesLength(&[_]ribModel.Route{
        ribModel.Route{
            .prefixLength = 16,
            .prefixData = [4]u8{ 0, 0, 0, 0 },
        },
        ribModel.Route{
            .prefixLength = 12,
            .prefixData = [4]u8{ 0, 0, 0, 0 },
        },
        ribModel.Route{
            .prefixLength = 32,
            .prefixData = [4]u8{ 0, 0, 0, 0 },
        },
        ribModel.Route{
            .prefixLength = 31,
            .prefixData = [4]u8{ 0, 0, 0, 0 },
        },
    }));
}

test "writeRoutes()" {
    const testRoutes = [_]ribModel.Route{
        ribModel.Route{
            .prefixLength = 16,
            .prefixData = [4]u8{ 0xff, 0xff, 0, 0 },
        },
        ribModel.Route{
            .prefixLength = 12,
            .prefixData = [4]u8{ 0, 0xff, 0, 0 },
        },
        ribModel.Route{
            .prefixLength = 32,
            .prefixData = [4]u8{ 127, 0, 42, 69 },
        },
        ribModel.Route{
            .prefixLength = 31,
            .prefixData = [4]u8{ 127, 0, 42, 69 },
        },
    };

    // zig fmt: off
    const expectedBuffer = [_]u8{ 
        16, 0xff, 0xff, 
        12, 0, 0xff, 
        32, 127, 0, 42, 69, 
        31, 127, 0, 42, 69 
    };

    var writer = std.Io.Writer.Allocating.init(testing.allocator);
    defer writer.deinit();
    
    try writeRoutes(&testRoutes, &writer.writer);

    const writtenBuffer = try writer.toOwnedSlice();
    defer testing.allocator.free(writtenBuffer);
    try testing.expectEqualSlices(u8, &expectedBuffer, writtenBuffer);
}

test "writeUpdateBody() - Minimal (Withdrawn only)" {
    const list = std.ArrayListUnmanaged(PathAttribute){};
    const attrs = AttributeList{ .alloc = testing.allocator, .list = list };

    var msg = try messageModel.UpdateMessage.init(
        testing.allocator, 
        &[_]ribModel.Route{
            .{ .prefixLength = 24, .prefixData = [4]u8{ 10, 0, 0, 0 } },
        }, 
        &[_]ribModel.Route{}, 
        attrs,
    );
    defer msg.deinit();

    var writer = std.Io.Writer.Allocating.init(testing.allocator);
    defer writer.deinit();

    try writeUpdateBody(msg, &writer.writer);

    const writtenBuffer = try writer.toOwnedSlice();
    defer testing.allocator.free(writtenBuffer);

    // zig fmt: off
    const expectedBuffer = [_]u8{ 
        0, 4,       // Withdrawn len: 4
        24, 10, 0, 0, 
        0, 0        // Attrs len: 0
    };
    try testing.expectEqualSlices(u8, &expectedBuffer, writtenBuffer);
}


test "writeUpdateBody() - All Attributes" {
    const asPath = asPathInit: {
        const referencePath: AsPath = .{
            .allocator = testing.allocator,
            .segments = &[_]ribModel.ASPathSegment{
                .{.allocator = testing.allocator, .segType = .AS_Sequence, .contents = &[_]u16{65001}}
            },
        };
        break :asPathInit try referencePath.clone(testing.allocator);
    };

    const unknownExtData = try testing.allocator.alloc(u8, 300);
    @memset(unknownExtData, 0);
    defer testing.allocator.free(unknownExtData);

    var list = std.ArrayListUnmanaged(PathAttribute){};
    try list.append(testing.allocator, .{ .Origin = .{ .flags = ribModel.ATTR_TRANSITIVE_FLAG, .value = .IGP } });
    try list.append(testing.allocator, .{ .AsPath = .{ .flags = ribModel.ATTR_TRANSITIVE_FLAG, .value = asPath } });
    try list.append(testing.allocator, .{ .Nexthop = .{ .flags = ribModel.ATTR_TRANSITIVE_FLAG, .value = ip.IpV4Address.init(1, 2, 3, 4) } });
    try list.append(testing.allocator, .{ .MultiExitDiscriminator = .{ .flags = ribModel.ATTR_OPTIONAL_FLAG, .value = 1234 } });
    try list.append(testing.allocator, .{ .LocalPref = .{ .flags = ribModel.ATTR_TRANSITIVE_FLAG, .value = 100 } });
    try list.append(testing.allocator, .{ .AtomicAggregate = .{ .flags = ribModel.ATTR_TRANSITIVE_FLAG, .value = true } });
    try list.append(testing.allocator, .{ .Aggregator = .{ 
        .flags = ribModel.ATTR_OPTIONAL_FLAG | ribModel.ATTR_TRANSITIVE_FLAG, 
        .value = .{ .as = 65001, .address = ip.IpVAddress.init(1, 2, 3, 4) } 
    } });
    try list.append(testing.allocator, .{ .Unknown = .{ 
        .flags = ribModel.ATTR_OPTIONAL_FLAG, 
        .value = .{ .allocator = testing.allocator, .typeCode = 100, .value = try testing.allocator.dupe(u8, &[_]u8{ 1, 2, 3 }) } 
    } });
    try list.append(testing.allocator, .{ .Unknown = .{ 
        .flags = ribModel.ATTR_OPTIONAL_FLAG, 
        .value = .{ .allocator = testing.allocator, .typeCode = 101, .value = try testing.allocator.dupe(u8, unknownExtData) } 
    } });

    const attrs = AttributeList{ .alloc = testing.allocator, .list = list };

    var msg = try messageModel.UpdateMessage.init(
        testing.allocator, 
        &[_]ribModel.Route{
            .{ .prefixLength = 24, .prefixData = [4]u8{ 192, 168, 1, 0 } },
        }, 
        &[_]ribModel.Route{
            ribModel.Route{
                .prefixLength = 32,
                .prefixData = [4]u8{ 127, 0, 0, 1 },
            },
        }, 
        attrs,
    );
    defer msg.deinit();

    var writer = std.Io.Writer.Allocating.init(testing.allocator);
    defer writer.deinit();

    try writeUpdateBody(msg, &writer.writer);

    const writtenBuffer = try writer.toOwnedSlice();
    defer testing.allocator.free(writtenBuffer);

    // Header: 
    // Withdrawn len: 0 (2 bytes)
    // Attrs len: ... (2 bytes)
    // Attrs:
    // - Origin: 0x40, 1, 1, 0 (4 bytes)
    // - As Path: 0x40, 2, 4, 2, 1, 0xFD, 0xE9 (7 bytes)
    // - Nexthop: 0x40, 3, 4, 1, 2, 3, 4 (7 bytes)
    // - MED: 0x80, 4, 4, 0, 0, 4, 210 (7 bytes)
    // - LocalPref: 0x40, 5, 4, 0, 0, 0, 100 (7 bytes)
    // - AtomicAggregate: 0x40, 6, 0 (3 bytes)
    // - Aggregator: 0xC0, 7, 6, 0xFD, 0xE9, 1, 2, 3, 4 (9 bytes)
    // - Unknown (100): 0x80, 100, 3, 1, 2, 3 (6 bytes)
    // - Unknown (101): 0x90, 101, 1, 44, [0]*300 (4 + 300 = 304 bytes)
    // Adv: 32, 127, 0, 0, 1 (5 bytes)

    const expected_attrs_len = 4 + 7 + 7 + 7 + 7 + 3 + 9 + 6 + 304; // 354
    try testing.expectEqual(4, std.mem.readInt(u16, writtenBuffer[0..2], .big)); // Withdrawn len
    try testing.expectEqualSlices(u8, &[_]u8{ 24, 192, 168, 1 }, writtenBuffer[2..6]);
    try testing.expectEqual(expected_attrs_len, std.mem.readInt(u16, writtenBuffer[6..8], .big)); // Attrs len
    
    // Check specific attributes
    var offset: usize = 8;
    
    // Origin
    try testing.expectEqualSlices(u8, &[_]u8{ 0x40, 1, 1, 0 }, writtenBuffer[offset .. offset + 4]);
    offset += 4;

    // AsPath
    try testing.expectEqualSlices(u8, &[_]u8{ 0x40, 2, 4, 2, 1, 0xFD, 0xE9 }, writtenBuffer[offset .. offset + 7]);
    offset += 7;

    // Nexthop
    try testing.expectEqualSlices(u8, &[_]u8{ 0x40, 3, 4, 1, 2, 3, 4 }, writtenBuffer[offset .. offset + 7]);
    offset += 7;

    // MED
    try testing.expectEqualSlices(u8, &[_]u8{ 0x80, 4, 4, 0, 0, 4, 210 }, writtenBuffer[offset .. offset + 7]);
    offset += 7;

    // LocalPref
    try testing.expectEqualSlices(u8, &[_]u8{ 0x40, 5, 4, 0, 0, 0, 100 }, writtenBuffer[offset .. offset + 7]);
    offset += 7;

    // AtomicAggregate
    try testing.expectEqualSlices(u8, &[_]u8{ 0x40, 6, 0 }, writtenBuffer[offset .. offset + 3]);
    offset += 3;

    // Aggregator
    try testing.expectEqualSlices(u8, &[_]u8{ 0xC0, 7, 6, 0xFD, 0xE9, 1, 2, 3, 4 }, writtenBuffer[offset .. offset + 9]);
    offset += 9;

    // Unknown (100)
    try testing.expectEqualSlices(u8, &[_]u8{ 0x80, 100, 3, 1, 2, 3 }, writtenBuffer[offset .. offset + 6]);
    offset += 6;

    // Unknown (101) - Extended
    try testing.expectEqual(0x90, writtenBuffer[offset]);
    try testing.expectEqual(101, writtenBuffer[offset + 1]);
    try testing.expectEqual(@as(u16, 300), std.mem.readInt(u16, &[_]u8{writtenBuffer[offset + 2], writtenBuffer[offset + 3]}, .big));
    try testing.expectEqualSlices(u8, unknownExtData, writtenBuffer[offset + 4 .. offset + 304]);
    offset += 304;

    // Adv
    try testing.expectEqualSlices(u8, &[_]u8{ 32, 127, 0, 0, 1 }, writtenBuffer[offset .. offset + 5]);
}
