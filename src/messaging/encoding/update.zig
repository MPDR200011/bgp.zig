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
        result += size: switch (attr.*) {
            .Origin => 4, // Origin: Flags(1) + Type(1) + Len(1) + Val(1)
            .AsPath => |*asPath| {
                // AS Path: Flags(1) + Type(1) + Len(1 or 2) + Data
                const asPathDataLen = calculateASPathByteLength(&asPath.value);
                var tmp: usize = 0;
                tmp += 2; // Flags + Type
                tmp += if (asPathDataLen > 255) @as(usize, 2) else @as(usize, 1); // Length field
                tmp += asPathDataLen;
                break :size tmp;
            },
            .Nexthop => 7, // Nexthop: Flags(1) + Type(1) + Len(1) + Val(4)
            .LocalPref => 7,
            else => 0,
        };
    }

    return result;
}

fn writeLocalPref(writer: *std.Io.Writer, localPref: * const ribModel.LocalPrefAttr) !void {
    try writer.writeInt(u32, localPref.value, .big);
}

fn writeAttributes(attrs: *const AttributeList, writer: *std.Io.Writer) !void {
    // TODO: For well-known attributes, the Transitive bit MUST be set to 1.

    for (attrs.list.items) |*attr| {
        switch (attr.*) {
            .Origin => |*origin| {
                try writer.writeInt(u8, origin.flags, .big);
                try writer.writeInt(u8, 1, .big);
                try writer.writeInt(u8, 1, .big);
                try writer.writeInt(u8, @intFromEnum(origin.value), .big);
            },
            .AsPath => |*asPath| {
                // AS Path
                const asPathDataLen = calculateASPathByteLength(&asPath.value);
                const isExtendedLen = asPathDataLen > 255;
                if (isExtendedLen) {
                    try writer.writeInt(u8, asPath.flags | ribModel.ATTR_EXTENDED_LENGTH_FLAG, .big);
                } else {
                    try writer.writeInt(u8, asPath.flags, .big);
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
            .Nexthop => |*nexthop| {
                try writer.writeInt(u8, nexthop.flags, .big);
                try writer.writeInt(u8, 3, .big);
                try writer.writeInt(u8, 4, .big);
                try writer.writeAll(&nexthop.value.address);
            },
            .LocalPref => |*localPref| {
                try writer.writeInt(u8, localPref.flags, .big);
                try writer.writeInt(u8, 5, .big);
                try writer.writeInt(u8, 4, .big);
                try writeLocalPref(writer, localPref);
            },
            else => {},
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

    try writer.writeInt(u16, @intCast(calculateAttributesLength(&msg.pathAttributes)), .big);
    try writeAttributes(&msg.pathAttributes, writer);

    try writeRoutes(msg.advertisedRoutes, writer);
}

const testing = std.testing;

test "calculateRoutesLength()" {
    try testing.expectEqual(0, calculateRoutesLength(&[_]messageModel.Route{}));
    try testing.expectEqual(16, calculateRoutesLength(&[_]messageModel.Route{
        messageModel.Route{
            .prefixLength = 16,
            .prefixData = [4]u8{ 0, 0, 0, 0 },
        },
        messageModel.Route{
            .prefixLength = 12,
            .prefixData = [4]u8{ 0, 0, 0, 0 },
        },
        messageModel.Route{
            .prefixLength = 32,
            .prefixData = [4]u8{ 0, 0, 0, 0 },
        },
        messageModel.Route{
            .prefixLength = 31,
            .prefixData = [4]u8{ 0, 0, 0, 0 },
        },
    }));
}

test "writeRoutes()" {
    const testRoutes = [_]messageModel.Route{
        messageModel.Route{
            .prefixLength = 16,
            .prefixData = [4]u8{ 0xff, 0xff, 0, 0 },
        },
        messageModel.Route{
            .prefixLength = 12,
            .prefixData = [4]u8{ 0, 0xff, 0, 0 },
        },
        messageModel.Route{
            .prefixLength = 32,
            .prefixData = [4]u8{ 127, 0, 42, 69 },
        },
        messageModel.Route{
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

test "writeUpdateBody() - External Peer" {
    const asPath = asPathInit: {
        const referencePath: AsPath = .{
            .allocator = testing.allocator,
            .segments = &[_]messageModel.ASPathSegment{
                .{.allocator = testing.allocator, .segType = .AS_Set, .contents = &[_]u16{69}}
            },
        };
        break :asPathInit try referencePath.clone(testing.allocator);
    };

    var list = std.ArrayListUnmanaged(PathAttribute){};
    try list.append(testing.allocator, .{ .Origin = .{ .flags = messageModel.ATTR_TRANSITIVE_FLAG, .value = .EGP } });
    try list.append(testing.allocator, .{ .AsPath = .{ .flags = messageModel.ATTR_TRANSITIVE_FLAG, .value = asPath } });
    try list.append(testing.allocator, .{ .Nexthop = .{ .flags = messageModel.ATTR_TRANSITIVE_FLAG, .value = ip.IpV4Address.init(0, 0, 0, 0) } });
    try list.append(testing.allocator, .{ .LocalPref = .init(100) });
    const attrs = AttributeList{ .alloc = testing.allocator, .list = list };

    const msg = try messageModel.UpdateMessage.init(
        testing.allocator, 
        &[_]messageModel.Route{ 
            messageModel.Route{
                .prefixLength = 16,
                .prefixData = [4]u8{ 0xff, 0xff, 0, 0 },
            }, 
            messageModel.Route{
                .prefixLength = 12,
                .prefixData = [4]u8{ 0, 0xff, 0, 0 },
            } 
        }, 
        &[_]messageModel.Route{
            messageModel.Route{
                .prefixLength = 32,
                .prefixData = [4]u8{ 127, 0, 42, 69 },
            },
            messageModel.Route{
                .prefixLength = 31,
                .prefixData = [4]u8{ 127, 0, 42, 69 },
            },
        }, 
        attrs,
    );
    defer msg.deinit();

    // zig fmt: off
    const expectedBuffer = [_]u8{ 
        // Withdrawn
        0, 6,
        16, 0xff, 0xff, 
        12, 0, 0xff, 
        // Attrs
        0, 4 + 7 + 7, 
        // -- Origin (Flags:0x40, Type:1, Len:1, Val:1)
        0x40, 1, 1, 1,
        // -- As Path (Flags:0x40, Type:2, Len:4, Val: [AS_SET, 1 ASN, 69])
        0x40, 2, 4, 1, 1, 0, 69,
        // -- Next hop (Flags:0x40, Type:3, Len:4, Val: 0.0.0.0)
        0x40, 3, 4, 0, 0, 0, 0, 
        // Adv
        32, 127, 0, 42, 69, 
        31, 127, 0, 42, 69 
    };

    var writer = std.Io.Writer.Allocating.init(testing.allocator);
    defer writer.deinit();

    try writeUpdateBody(msg, &writer.writer);

    const writtenBuffer = try writer.toOwnedSlice();
    defer testing.allocator.free(writtenBuffer);
    try testing.expectEqualSlices(u8, &expectedBuffer, writtenBuffer);
}

test "writeUpdateBody() - Internal Peer" {
    const asPath = asPathInit: {
        const referencePath: AsPath = .{
            .allocator = testing.allocator,
            .segments = &[_]messageModel.ASPathSegment{
                .{.allocator = testing.allocator, .segType = .AS_Set, .contents = &[_]u16{69}}
            },
        };
        break :asPathInit try referencePath.clone(testing.allocator);
    };

    var list = std.ArrayListUnmanaged(PathAttribute){};
    try list.append(testing.allocator, .{ .Origin = .{ .flags = messageModel.ATTR_TRANSITIVE_FLAG, .value = .EGP } });
    try list.append(testing.allocator, .{ .AsPath = .{ .flags = messageModel.ATTR_TRANSITIVE_FLAG, .value = asPath } });
    try list.append(testing.allocator, .{ .Nexthop = .{ .flags = messageModel.ATTR_TRANSITIVE_FLAG, .value = ip.IpV4Address.init(0, 0, 0, 0) } });
    try list.append(testing.allocator, .{ .LocalPref = .init(100) });
    const attrs = AttributeList{ .alloc = testing.allocator, .list = list };

    const msg = try messageModel.UpdateMessage.init(
        testing.allocator, 
        &[_]messageModel.Route{ 
            messageModel.Route{
                .prefixLength = 16,
                .prefixData = [4]u8{ 0xff, 0xff, 0, 0 },
            }, 
            messageModel.Route{
                .prefixLength = 12,
                .prefixData = [4]u8{ 0, 0xff, 0, 0 },
            } 
        }, 
        &[_]messageModel.Route{
            messageModel.Route{
                .prefixLength = 32,
                .prefixData = [4]u8{ 127, 0, 42, 69 },
            },
            messageModel.Route{
                .prefixLength = 31,
                .prefixData = [4]u8{ 127, 0, 42, 69 },
            },
        }, 
        attrs,
    );
    // Let's set the flags on localPref to 0x40 (Transitive) just in case, though it's typically 0x40 for well-known
    // Actually the default flags is 0, let's keep it 0 as the other test doesn't set it 
    defer msg.deinit();

    // zig fmt: off
    const expectedBuffer = [_]u8{ 
        // Withdrawn
        0, 6,
        16, 0xff, 0xff, 
        12, 0, 0xff, 
        // Attrs
        0, 4 + 7 + 7 + 7, 
        // -- Origin (Flags:0x40, Type:1, Len:1, Val:1)
        0x40, 1, 1, 1,
        // -- As Path (Flags:0x40, Type:2, Len:4, Val: [AS_SET, 1 ASN, 69])
        0x40, 2, 4, 1, 1, 0, 69,
        // -- Next hop (Flags:0x40, Type:3, Len:4, Val: 0.0.0.0)
        0x40, 3, 4, 0, 0, 0, 0, 
        // -- Local Pref (Flags:0x00, Type:5, Len:4, Val: 100)
        0x00, 5, 4, 0, 0, 0, 100,
        // Adv
        32, 127, 0, 42, 69, 
        31, 127, 0, 42, 69 
    };

    var writer = std.Io.Writer.Allocating.init(testing.allocator);
    defer writer.deinit();

    try writeUpdateBody(msg, &writer.writer);

    const writtenBuffer = try writer.toOwnedSlice();
    defer testing.allocator.free(writtenBuffer);
    try testing.expectEqualSlices(u8, &expectedBuffer, writtenBuffer);
}
