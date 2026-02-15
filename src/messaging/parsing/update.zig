const std = @import("std");
const ip = @import("ip");
const model = @import("../model.zig");

const Route = model.Route;
const PathAttributes = model.PathAttributes;

const UpdateParsingError = error{ 
RoutesLengthInconsistent, 
AttributesLengthInconsistent, 
InvalidPrefixLength, 
MissingMandatoryAttribute, 
ASPAthAttrLengthInconsistent,
};

pub const UpdateMsgParser = @This();
const Self = UpdateMsgParser;

reader: *std.Io.Reader,
allocator: std.mem.Allocator,

fn takeIntoRoute(self: *Self, route: *Route) !u16 {
    const prefixLength = try self.reader.takeInt(u8, .big);
    if (prefixLength > 32) {
        std.debug.print("Invalid prefix length: {}\n", .{prefixLength});
        return UpdateParsingError.InvalidPrefixLength;
    }

    const prefixByteLength: u8 = (prefixLength / 8) + @as(u8, if ((prefixLength % 8) > 0) 1 else 0);
    std.debug.assert(prefixByteLength <= 4);

    route.prefixLength = prefixLength;
    route.prefixData = [4]u8{ 0, 0, 0, 0 };

    var bitsToRead: i32 = @intCast(prefixLength);
    for (0..prefixByteLength) |i| {
        const addressByte = try self.reader.takeInt(u8, .big);

        const shiftAmount: u4 = 8 - @min(8, @as(u8, @intCast(bitsToRead)));
        const mask: u8 = @truncate(@as(u16, 0xff) << shiftAmount);

        route.prefixData[i] = addressByte & mask;

        bitsToRead -= 8;
    }

    return (prefixByteLength + 1);
}

fn readRoutes(self: *Self, routesLength: u16) !std.array_list.Managed(Route) {
    var routesList = std.array_list.Managed(Route).init(self.allocator);
    errdefer routesList.deinit();

    var bytesToRead: i32 = @intCast(routesLength);
    while (bytesToRead > 0) {
        const route = try routesList.addOne();

        bytesToRead -= try self.takeIntoRoute(route);
    }

    if (bytesToRead != 0) {
        return UpdateParsingError.RoutesLengthInconsistent;
    }

    return routesList;
}

fn readOrigin(self: *Self) !model.Origin {
    // TODO: origin value validation
    const origin: model.Origin = @enumFromInt(try self.reader.takeInt(u8, .big));
    return origin;
}

fn readAsPath(self: *Self, bytesLength: u16) !model.ASPath {
    var pathSegments: std.ArrayList(model.ASPathSegment) = .empty;
    defer pathSegments.deinit(self.allocator);

    var currentRead: usize = 0;
    while (currentRead < bytesLength) {
        // TODO: segment type value validation
        const segmentType: model.ASPathSegmentType = @enumFromInt(try self.reader.takeInt(u8, .big));
        const segmentLength: usize = @intCast(try self.reader.takeInt(u8, .big));

        const segmentContents = try self.allocator.alloc(u16, segmentLength);
        for (0..segmentLength) |i| {
            segmentContents[i] = try self.reader.takeInt(u16, .big);
        }
        const segment = try pathSegments.addOne(self.allocator);
        segment.* = .{
            .allocator = self.allocator,
            .segType = segmentType,
            .contents = segmentContents,
        };

        currentRead += (2 + (segmentLength * 2));
    }

    if (currentRead != bytesLength) {
        return UpdateParsingError.ASPAthAttrLengthInconsistent;
    }

    return .{
        .allocator = self.allocator,
        .segments = try self.allocator.dupe(model.ASPathSegment, pathSegments.items),
    };
}

fn readNextHop(self: *Self) !ip.IpV4Address {
    var address: ip.IpV4Address = undefined;
    try self.reader.readSliceAll(&address.address);
    return address;
}

fn readAttributes(self: *Self, attributesLength: u16) !PathAttributes {
    var attributes: PathAttributes = .empty;
    attributes.allocator = self.allocator;

    var originRead: bool = false;
    var asPathRead: bool = false;
    var nextHopRead: bool = false;

    var bytesToRead: i32 = @intCast(attributesLength);
    while (bytesToRead > 0) {
        const attributeFlags = try self.reader.takeInt(u8, .big);
        const attributeType = try self.reader.takeInt(u8, .big);

        const extendedLength: bool = (attributeFlags & model.ATTR_EXTENDED_LENGTH_FLAG) > 0;
        const attributeLength: u16 = if (extendedLength) try self.reader.takeInt(u16, .big) else @intCast(try self.reader.takeInt(u8, .big));

        // TODO: Unrecognized non-transitive optional attributes MUST be
        // quietly ignored and not passed along to other BGP peers.
        switch (attributeType) {
            1 => {
                attributes.origin = .{ .flags = attributeFlags, .value = try self.readOrigin() };
                originRead = true;
            },
            2 => {
                attributes.asPath = .{ .flags = attributeFlags, .value = try self.readAsPath(attributeLength) };
                asPathRead = true;
            },
            3 => {
                std.debug.assert(attributeLength == 4);
                attributes.nexthop = .{ .flags = attributeFlags, .value = try self.readNextHop() };
                nextHopRead = true;
            },
            else => {
                // Ignore unknown attribute
                try self.reader.discardAll(attributeLength);
            },
        }

        bytesToRead -= 2; // For attributeFlags and attributeType
        bytesToRead -= if (extendedLength) 2 else 1; // For attributeLength field itself
        bytesToRead -= attributeLength; // For the attribute value
    }

    if (!originRead or !nextHopRead or !asPathRead) {
        return UpdateParsingError.MissingMandatoryAttribute;
    }

    if (bytesToRead != 0) {
        return UpdateParsingError.AttributesLengthInconsistent;
    }

    return attributes;
}

pub fn readUpdateMessage(self: *Self, messageLength: u16) !model.UpdateMessage {
    const withdrawnLength = try self.reader.takeInt(u16, .big);
    const withdrawnRoutes = try self.readRoutes(withdrawnLength);
    defer withdrawnRoutes.deinit();

    const attributesLength = try self.reader.takeInt(u16, .big);
    const routeAttributes = try self.readAttributes(attributesLength);
    defer routeAttributes.deinit();

    const advertisedLength = messageLength - withdrawnLength - attributesLength - 4;
    const advertisedRoutes = try self.readRoutes(advertisedLength);
    defer advertisedRoutes.deinit();

    return .init(self.allocator, withdrawnRoutes.items, advertisedRoutes.items, routeAttributes);
}

const testing = std.testing;

fn testReadIntoRoute(routeBuffer: []const u8, expectedReadBytes: u16, expectedRoute: Route) !void {
    var stream = std.io.fixedBufferStream(routeBuffer[0..]);

    var readBuffer: [1024]u8 = undefined;
    var reader = stream.reader().adaptToNewApi(&readBuffer);
    var updateReader = Self{
        .allocator = testing.allocator,
        .reader = &reader.new_interface,
    };

    var actualRoute: Route = undefined;
    const readBytes = try updateReader.takeIntoRoute(&actualRoute);

    try testing.expectEqual(expectedRoute, actualRoute);
    try testing.expectEqual(expectedReadBytes, readBytes);
}

test "takeIntoRoute()" {
    try testReadIntoRoute(&.{
        // Length
        32,
        // Route
        192,
        168,
        0,
        42,
    }, 5, Route{ .prefixLength = 32, .prefixData = [_]u8{ 192, 168, 0, 42 } });
    try testReadIntoRoute(&.{
        // Length
        16,
        // Route
        192,
        168,
    }, 3, Route{ .prefixLength = 16, .prefixData = [_]u8{ 192, 168, 0, 0 } });
    try testReadIntoRoute(&.{
        // Length
        12,
        // Route
        192,
        0b10111111,
    }, 3, Route{ .prefixLength = 12, .prefixData = [_]u8{ 192, 0b10110000, 0, 0 } });
}

test "readRoutes()" {
    const routesBuffer = [_]u8{
        // R1
        // Length
        32,
        // Route
        192,
        168,
        0,
        42,
        // R2
        // Length
        16,
        // Route
        192,
        168,
        // R3
        // Length
        12,
        // Route
        192,
        0b10111111,
    };

    var stream = std.io.fixedBufferStream(routesBuffer[0..]);

    var readBuffer: [1024]u8 = undefined;
    var reader = stream.reader().adaptToNewApi(&readBuffer);
    var updateReader = Self{
        .allocator = testing.allocator,
        .reader = &reader.new_interface,
    };
    const routes = try updateReader.readRoutes(@intCast(routesBuffer.len));
    defer routes.deinit();

    const expectedRoutes = [_]Route{
        Route{ .prefixLength = 32, .prefixData = [_]u8{ 192, 168, 0, 42 } },
        Route{ .prefixLength = 16, .prefixData = [_]u8{ 192, 168, 0, 0 } },
        Route{ .prefixLength = 12, .prefixData = [_]u8{ 192, 0b10110000, 0, 0 } },
    };
    try testing.expectEqualSlices(Route, expectedRoutes[0..], routes.items);
}

test "readUpdateMessage()" {
    const messageBuffer = [_]u8{
        //Withdrawn length
        0,
        3,
        // R3
        // Length
        12,
        // Route
        192,
        0b10111111,
        // Attributes Length
        0,
        20,
        // Origin
        0x40,
        1,
        1,
        0,
        // ASPath
        0x40,
        2,
        6,
        2,
        2,
        0,
        100,
        0,
        200,
        // NextHop
        0x40,
        3,
        4,
        192,
        168,
        0,
        1,
        // Advertised
        // R1
        // Length
        32,
        // Route
        192,
        168,
        0,
        42,
        // R2
        // Length
        16,
        // Route
        192,
        168,
    };

    var stream = std.io.fixedBufferStream(messageBuffer[0..]);

    var readBuffer: [1024]u8 = undefined;
    var reader = stream.reader().adaptToNewApi(&readBuffer);
    var updateReader = Self{
        .allocator = testing.allocator,
        .reader = &reader.new_interface,
    };
    const message = try updateReader.readUpdateMessage(@intCast(messageBuffer.len));
    defer message.deinit();

    try testing.expectEqual(stream.getPos(), messageBuffer.len);

    try testing.expectEqualSlices(Route, &[_]Route{Route{ .prefixLength = 12, .prefixData = [_]u8{ 192, 0b10110000, 0, 0 } }}, message.withdrawnRoutes);
    try testing.expectEqualSlices(Route, &[_]Route{
        Route{ .prefixLength = 32, .prefixData = [_]u8{ 192, 168, 0, 42 } },
        Route{ .prefixLength = 16, .prefixData = [_]u8{ 192, 168, 0, 0 } },
    }, message.advertisedRoutes);
    // Verify attribute values
    try testing.expect(message.pathAttributes != null);
    const attrs = message.pathAttributes.?;
    try testing.expectEqual(model.Origin.IGP, attrs.origin.value);

    try testing.expectEqual(@as(usize, 1), attrs.asPath.value.segments.len);
    try testing.expectEqual(model.ASPathSegmentType.AS_Sequence, attrs.asPath.value.segments[0].segType);
    try testing.expectEqualSlices(u16, &[_]u16{ 100, 200 }, attrs.asPath.value.segments[0].contents);

    try testing.expect(attrs.nexthop.value.equals(ip.IpV4Address.parse("192.168.0.1") catch unreachable));
}

fn testReadAsPath(asPathBuffer: []const u8, expectedASPath: model.ASPath) !void {
    var stream = std.io.fixedBufferStream(asPathBuffer[0..]);
    var readBuffer: [1024]u8 = undefined;
    var reader = stream.reader().adaptToNewApi(&readBuffer);
    var updateReader = Self{
        .allocator = testing.allocator,
        .reader = &reader.new_interface,
    };

    const actualASPath = try updateReader.readAsPath(@intCast(asPathBuffer.len));
    defer actualASPath.deinit();

    try testing.expect(expectedASPath.equal(&actualASPath));
}

test "readAsPath()" {
    // 1. One AS_SEQUENCE segment
    const buffer1 = [_]u8{
        2, // AS_SEQUENCE
        2, // Length (2 ASNs)
        0, 100, // ASN 100
        0, 200, // ASN 200
    };
    const segments1 = try testing.allocator.alloc(model.ASPathSegment, 1);
    segments1[0] = .{
        .allocator = testing.allocator,
        .segType = .AS_Sequence,
        .contents = try testing.allocator.dupe(u16, &[_]u16{ 100, 200 }),
    };
    const expected1 = model.ASPath{
        .allocator = testing.allocator,
        .segments = segments1,
    };
    defer expected1.deinit();
    try testReadAsPath(&buffer1, expected1);

    // 2. AS_SEQUENCE followed by AS_SET
    const buffer2 = [_]u8{
        2, // AS_SEQUENCE
        1, // Length (1 ASN)
        0, 100, // ASN 100
        1, // AS_SET
        2, // Length (2 ASNs)
        0, 200, // ASN 200
        0, 201, // ASN 201
    };
    const segments2 = try testing.allocator.alloc(model.ASPathSegment, 2);
    segments2[0] = .{
        .allocator = testing.allocator,
        .segType = .AS_Sequence,
        .contents = try testing.allocator.dupe(u16, &[_]u16{100}),
    };
    segments2[1] = .{
        .allocator = testing.allocator,
        .segType = .AS_Set,
        .contents = try testing.allocator.dupe(u16, &[_]u16{ 200, 201 }),
    };
    const expected2 = model.ASPath{
        .allocator = testing.allocator,
        .segments = segments2,
    };
    defer expected2.deinit();
    try testReadAsPath(&buffer2, expected2);
}

test "readNextHop()" {
    const buffer = [_]u8{ 192, 168, 0, 1 };
    var stream = std.io.fixedBufferStream(&buffer);
    var readBuffer: [1024]u8 = undefined;
    var reader = stream.reader().adaptToNewApi(&readBuffer);
    var updateReader = Self{
        .allocator = testing.allocator,
        .reader = &reader.new_interface,
    };

    const actualNextHop = try updateReader.readNextHop();
    try testing.expect(actualNextHop.equals(ip.IpV4Address.parse("192.168.0.1") catch unreachable));
}

test "readAttributes with unknown attribute" {
    const attributesBuffer = [_]u8{
        // Origin (Well-known mandatory)
        0x40, // Flags (Transitive)
        1,    // Type
        1,    // Length
        0,    // Value (IGP)
        
        // Unknown Attribute (Mocked)
        0x00, // Flags (Non-transitive, Optional as per BGP rules it should be ignored if unknown)
        99,   // Type (Unknown)
        5,    // Length
        1, 2, 3, 4, 5, // Data (to be ignored)

        // ASPath (Well-known mandatory)
        0x40, // Flags (Transitive)
        2,    // Type
        6,    // Length
        2,    // AS_Sequence
        2,    // Length
        0, 100,
        0, 200,

        // NextHop (Well-known mandatory)
        0x40, // Flags (Transitive)
        3,    // Type
        4,    // Length
        192, 168, 0, 1,
    };

    var stream = std.io.fixedBufferStream(&attributesBuffer);
    var readBuffer: [1024]u8 = undefined;
    var reader = stream.reader().adaptToNewApi(&readBuffer);
    var updateReader = UpdateMsgParser{
        .allocator = testing.allocator,
        .reader = &reader.new_interface,
    };

    const attrs = try updateReader.readAttributes(@intCast(attributesBuffer.len));
    defer attrs.deinit();

    // Verify mandatory attributes were parsed correctly despite the unknown attribute
    try testing.expectEqual(model.Origin.IGP, attrs.origin.value);
    try testing.expectEqual(@as(usize, 1), attrs.asPath.value.segments.len);
    try testing.expectEqual(model.ASPathSegmentType.AS_Sequence, attrs.asPath.value.segments[0].segType);
    try testing.expectEqualSlices(u16, &[_]u16{ 100, 200 }, attrs.asPath.value.segments[0].contents);
    try testing.expect(attrs.nexthop.value.equals(ip.IpV4Address.parse("192.168.0.1") catch unreachable));
    
    // Ensure we read the entire buffer
    try testing.expectEqual(attributesBuffer.len, stream.getPos());
}
