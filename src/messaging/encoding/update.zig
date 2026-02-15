const std = @import("std");
const ip = @import("ip");
const consts = @import("../consts.zig");
const model = @import("../model.zig");

const PathAttributes = model.PathAttributes;
const AsPath = model.ASPath;

fn calculateRoutesLength(routes: []const model.Route) usize {
    var total: usize = 0;
    for (routes) |route| {
        total += 1;

        const bytes = (route.prefixLength / 8) + @as(usize, if (route.prefixLength % 8 > 0) 1 else 0);
        total += bytes;
    }

    return total;
}

fn writeRoutes(routes: []const model.Route, writer: *std.Io.Writer) !void {
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

fn calculateAttributesLength(attrs: *const PathAttributes) usize {
    var result: usize = 0;

    // Origin: Flags(1) + Type(1) + Len(1) + Val(1)
    result += 4;

    // AS Path: Flags(1) + Type(1) + Len(1 or 2) + Data
    const asPathDataLen = calculateASPathByteLength(&attrs.asPath.value);
    result += 2; // Flags + Type
    result += if (asPathDataLen > 255) @as(usize, 2) else @as(usize, 1); // Length field
    result += asPathDataLen;

    // Nexthop: Flags(1) + Type(1) + Len(1) + Val(4)
    result += 7;

    return result;
}

fn writeAttributes(attrs: *const PathAttributes, writer: *std.Io.Writer) !void {
    // TODO: For well-known attributes, the Transitive bit MUST be set to 1.

    // Origin
    try writer.writeInt(u8, attrs.origin.flags, .big);
    try writer.writeInt(u8, 1, .big);
    try writer.writeInt(u8, 1, .big);
    try writer.writeInt(u8, @intFromEnum(attrs.origin.value), .big);

    // AS Path
    const asPathDataLen = calculateASPathByteLength(&attrs.asPath.value);
    const isExtendedLen = asPathDataLen > 255;
    if (isExtendedLen) {
        try writer.writeInt(u8, attrs.asPath.flags | model.ATTR_EXTENDED_LENGTH_FLAG, .big);
    } else {
        try writer.writeInt(u8, attrs.asPath.flags, .big);
    }
    try writer.writeInt(u8, 2, .big);
    if (isExtendedLen) {
        try writer.writeInt(u16, @intCast(asPathDataLen), .big);
    } else {
        try writer.writeInt(u8, @intCast(asPathDataLen), .big);
    }
    for (attrs.asPath.value.segments) |segment| {
        try writer.writeInt(u8, @intFromEnum(segment.segType), .big);
        try writer.writeInt(u8, @intCast(segment.contents.len), .big);
        for (segment.contents) |asn| {
            try writer.writeInt(u16, asn, .big);
        }
    }

    // Nexthop
    try writer.writeInt(u8, attrs.nexthop.flags, .big);
    try writer.writeInt(u8, 3, .big);
    try writer.writeInt(u8, 4, .big);
    try writer.writeAll(&attrs.nexthop.value.address);
}

pub fn writeUpdateBody(msg: model.UpdateMessage, writer: *std.Io.Writer) !void {
    try writer.writeInt(u16, @intCast(calculateRoutesLength(msg.withdrawnRoutes)), .big);
    try writeRoutes(msg.withdrawnRoutes, writer);

    if (msg.pathAttributes) |*attrs| {
        try writer.writeInt(u16, @intCast(calculateAttributesLength(attrs)), .big);
        try writeAttributes(attrs, writer);

        try writeRoutes(msg.advertisedRoutes, writer);
    }
}

const testing = std.testing;

test "calculateRoutesLength()" {
    try testing.expectEqual(0, calculateRoutesLength(&[_]model.Route{}));
    try testing.expectEqual(16, calculateRoutesLength(&[_]model.Route{
        model.Route{
            .prefixLength = 16,
            .prefixData = [4]u8{ 0, 0, 0, 0 },
        },
        model.Route{
            .prefixLength = 12,
            .prefixData = [4]u8{ 0, 0, 0, 0 },
        },
        model.Route{
            .prefixLength = 32,
            .prefixData = [4]u8{ 0, 0, 0, 0 },
        },
        model.Route{
            .prefixLength = 31,
            .prefixData = [4]u8{ 0, 0, 0, 0 },
        },
    }));
}

test "writeRoutes()" {
    const testRoutes = [_]model.Route{
        model.Route{
            .prefixLength = 16,
            .prefixData = [4]u8{ 0xff, 0xff, 0, 0 },
        },
        model.Route{
            .prefixLength = 12,
            .prefixData = [4]u8{ 0, 0xff, 0, 0 },
        },
        model.Route{
            .prefixLength = 32,
            .prefixData = [4]u8{ 127, 0, 42, 69 },
        },
        model.Route{
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

test "writeUpdateBody()" {
    const asPath = asPathInit: {
        const referencePath: AsPath = .{
            .allocator = testing.allocator,
            .segments = &[_]model.ASPathSegment{
                .{.allocator = testing.allocator, .segType = .AS_Set, .contents = &[_]u16{69}}
            },
        };
        break :asPathInit try referencePath.clone(testing.allocator);
    };
    defer asPath.deinit();

    const msg = try model.UpdateMessage.init(
        testing.allocator, 
        &[_]model.Route{ 
            model.Route{
                .prefixLength = 16,
                .prefixData = [4]u8{ 0xff, 0xff, 0, 0 },
            }, 
            model.Route{
                .prefixLength = 12,
                .prefixData = [4]u8{ 0, 0xff, 0, 0 },
            } 
        }, 
        &[_]model.Route{
            model.Route{
                .prefixLength = 32,
                .prefixData = [4]u8{ 127, 0, 42, 69 },
            },
            model.Route{
                .prefixLength = 31,
                .prefixData = [4]u8{ 127, 0, 42, 69 },
            },
        }, 
        PathAttributes{
            .allocator = testing.allocator, 
            .origin = .{ .flags = model.ATTR_TRANSITIVE_FLAG, .value = .EGP }, 
            .asPath = .{ .flags = model.ATTR_TRANSITIVE_FLAG, .value = asPath }, 
            .nexthop = .{ .flags = model.ATTR_TRANSITIVE_FLAG, .value = ip.IpV4Address.init(0, 0, 0, 0) }, 
            .localPref = .init(100), 
            .atomicAggregate = .init(false), 
            .multiExitDiscriminator = null, 
            .aggregator = null
        },
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
