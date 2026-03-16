const std = @import("std");
const ip = @import("ip");
const ribModel = @import("../../rib/model.zig");
const messageModel = @import("../model.zig");

const Route = ribModel.Route;
const PathAttribute = messageModel.PathAttribute;
const AttributeList = messageModel.AttributeList;

const UpdateParsingError = error{ 
RoutesLengthInconsistent, 
AttributesLengthInconsistent, 
InvalidPrefixLength, 
ASPAthAttrLengthInconsistent,
MissingOriginAttribute, 
MissingASPathAttribute,
MissingNexthopAttribute
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

    return (prefixByteLength + 1); // prefix length + length filed
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

fn readOrigin(self: *Self) !ribModel.Origin {
    // TODO: origin value validation
    const origin: ribModel.Origin = @enumFromInt(try self.reader.takeInt(u8, .big));
    return origin;
}

fn readAsPath(self: *Self, bytesLength: u16) !ribModel.ASPath {
    var pathSegments: std.ArrayList(ribModel.ASPathSegment) = .empty;
    defer pathSegments.deinit(self.allocator);
    errdefer {
        for (pathSegments.items) |*seg| {
            seg.deinit();
        }
    }

    var currentRead: usize = 0;
    while (currentRead < bytesLength) {
        // TODO: segment type value validation
        const segmentType: ribModel.ASPathSegmentType = @enumFromInt(try self.reader.takeInt(u8, .big));
        const segmentLength: usize = @intCast(try self.reader.takeInt(u8, .big));

        const segmentContents = try self.allocator.alloc(u16, segmentLength);
        for (0..segmentLength) |i| {
            segmentContents[i] = try self.reader.takeInt(u16, .big);
        }
        try pathSegments.append(self.allocator, .{
            .allocator = self.allocator,
            .segType = segmentType,
            .contents = segmentContents,
        });

        currentRead += (2 + (segmentLength * 2));
    }

    if (currentRead != bytesLength) {
        return UpdateParsingError.ASPAthAttrLengthInconsistent;
    }

    return .{
        .allocator = self.allocator,
        .segments = try self.allocator.dupe(ribModel.ASPathSegment, pathSegments.items),
    };
}

fn readNextHop(self: *Self) !ip.IpV4Address {
    var address: ip.IpV4Address = undefined;
    try self.reader.readSliceAll(&address.address);
    return address;
}

fn readLocalPref(self: *Self) !u32 {
    return try self.reader.takeInt(u32, .big);
}

fn readAggregator(self: *Self) !ribModel.Aggregator {
    var agg: ribModel.Aggregator = .{
        .as = try self.reader.takeInt(u16, .big),
        .address = undefined
    };
    try self.reader.readSliceAll(&agg.address.address);
    return agg;
}

fn readUnknownAttributeValue(self: *Self, len: u16) ![]u8 {
    const buffer = try self.allocator.alloc(u8, len);
    errdefer self.allocator.free(buffer);

    try self.reader.readSliceAll(buffer);

    return buffer;
}

fn readAttributes(self: *Self, attributesLength: u16) !AttributeList {
    var attributes: AttributeList = .{
        .alloc = self.allocator,
        .list = .empty
    };
    errdefer {
        attributes.deinit();
    }

    var bytesToRead: i32 = @intCast(attributesLength);
    while (bytesToRead > 0) {
        const attributeFlags = try self.reader.takeInt(u8, .big);
        const attributeType = try self.reader.takeInt(u8, .big);

        const extendedLength: bool = (attributeFlags & ribModel.ATTR_EXTENDED_LENGTH_FLAG) > 0;
        const attributeLength: u16 = if (extendedLength) try self.reader.takeInt(u16, .big) else @intCast(try self.reader.takeInt(u8, .big));

        // TODO: Unrecognized non-transitive optional attributes MUST be
        // quietly ignored and not passed along to other BGP peers.
        const attribute: PathAttribute = attr: switch (attributeType) {
            1 => {
                break :attr .{ .Origin = .{
                    .flags = attributeFlags,
                    .value = try self.readOrigin(),
                } };
            },
            2 => {
                break :attr .{ .AsPath = .{
                    .flags = attributeFlags,
                    .value = try self.readAsPath(attributeLength),
                } };
            },
            3 => {
                std.debug.assert(attributeLength == 4);
                break :attr .{ .Nexthop = .{
                    .flags = attributeFlags,
                    .value = .{ .Address = try self.readNextHop() },
                } };
            },
            4 => {
                break :attr .{ .MultiExitDiscriminator = .{
                    .flags = attributeFlags,
                    .value = try self.reader.takeInt(u32, .big),
                } };
            },
            5 => {
                // FIXME make sure localPref flags are properly set
                std.debug.assert(attributeLength == 4);
                break :attr .{ .LocalPref = .{
                    .flags = attributeFlags,
                    .value = try self.readLocalPref(),
                } };
            },
            6 => {
                break :attr .{ .AtomicAggregate = .{
                    .flags = attributeFlags,
                    .value = true
                }};
            },
            7 => {
                break :attr .{ .Aggregator = .{
                    .flags = attributeFlags,
                    .value = try self.readAggregator(),
                }};
            },
            else => {
                // Ignore unknown attribute
                break :attr .{ .Unknown = .{
                    .flags = attributeFlags,
                    .value = .{
                        .allocator = self.allocator,
                        .typeCode = attributeType,
                        .value = try self.readUnknownAttributeValue(attributeLength),
                    },
                } };
            },
        };

        try attributes.list.append(self.allocator, attribute);

        bytesToRead -= 2; // For attributeFlags and attributeType
        bytesToRead -= if (extendedLength) 2 else 1; // For attributeLength field itself
        bytesToRead -= attributeLength; // For the attribute value
    }

    if (bytesToRead != 0) {
        return UpdateParsingError.AttributesLengthInconsistent;
    }

    return attributes;
}

pub fn readUpdateMessage(self: *Self, messageLength: u16) !messageModel.UpdateMessage {
    const withdrawnLength = try self.reader.takeInt(u16, .big);
    const withdrawnRoutes = try self.readRoutes(withdrawnLength);
    defer withdrawnRoutes.deinit();

    const attributesLength = try self.reader.takeInt(u16, .big);
    const advertisedLength = messageLength - withdrawnLength - attributesLength - 4;
    if (attributesLength == 0) {
        if (advertisedLength != 0) {
            return error.AdvertisedRoutesWithoutAttrs;
        }
        const attrs: AttributeList = .{
            .alloc = self.allocator,
            .list = .empty
        };
        return .init(self.allocator, withdrawnRoutes.items, self.allocator.alloc(Route, 0) catch unreachable, attrs);
    } else {
        var routeAttributes = try self.readAttributes(attributesLength);
        errdefer routeAttributes.deinit();

        const advertisedRoutes = try self.readRoutes(advertisedLength);
        defer advertisedRoutes.deinit();

        return .init(self.allocator, withdrawnRoutes.items, advertisedRoutes.items, routeAttributes);
    }
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

test "readUpdateMessage() - Minimal (Withdrawn only)" {
    const messageBuffer = [_]u8{
        0, 3, // Withdrawn length: 3
        12, 192, 0b10111111, // R3: 192.176.0.0/12 (roughly)
        0, 0, // Attributes length: 0
    };

    var stream = std.io.fixedBufferStream(&messageBuffer);
    var readBuffer: [1024]u8 = undefined;
    var reader = stream.reader().adaptToNewApi(&readBuffer);
    var updateReader = UpdateMsgParser{
        .allocator = testing.allocator,
        .reader = &reader.new_interface,
    };
    var message = try updateReader.readUpdateMessage(@intCast(messageBuffer.len));
    defer message.deinit();

    try testing.expectEqual(stream.getPos(), messageBuffer.len);
    try testing.expectEqual(@as(usize, 1), message.withdrawnRoutes.len);
    try testing.expectEqual(@as(usize, 0), message.advertisedRoutes.len);
    try testing.expectEqual(@as(usize, 0), message.pathAttributes.list.items.len);
}

fn testReadAsPath(asPathBuffer: []const u8, expectedASPath: ribModel.ASPath) !void {
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
    const segments1 = try testing.allocator.alloc(ribModel.ASPathSegment, 1);
    segments1[0] = .{
        .allocator = testing.allocator,
        .segType = .AS_Sequence,
        .contents = try testing.allocator.dupe(u16, &[_]u16{ 100, 200 }),
    };
    const expected1 = ribModel.ASPath{
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
    const segments2 = try testing.allocator.alloc(ribModel.ASPathSegment, 2);
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
    const expected2 = ribModel.ASPath{
        .allocator = testing.allocator,
        .segments = segments2,
    };
    defer expected2.deinit();
    try testReadAsPath(&buffer2, expected2);
}

test "readUpdateMessage() - All Attributes" {
    const unknownDataShort = [_]u8{ 1, 2, 3 };
    var unknownDataLong: [300]u8 = undefined;
    @memset(&unknownDataLong, 0xAA);

    const messageBuffer = blk: {
        var list = std.array_list.Managed(u8).init(testing.allocator);
        // Withdrawn (1 route: 10.0.0.0/24 -> 4 bytes)
        try list.appendSlice(&[_]u8{ 0, 4, 24, 10, 0, 0 });
        
        // Attrs
        // We'll calculate total length later. Let's start with a placeholder.
        const attrLenPlaceholderIdx = list.items.len;
        try list.appendSlice(&[_]u8{ 0, 0 });

        const attrStartIdx = list.items.len;

        // -- Origin (Flags:0x40, Type:1, Len:1, Val:0)
        try list.appendSlice(&[_]u8{ 0x40, 1, 1, 0 });
        // -- AsPath (Flags:0x40, Type:2, Len:6, Val: [Seq, 2 ASNs, 100, 200])
        try list.appendSlice(&[_]u8{ 0x40, 2, 6, 2, 2, 0, 100, 0, 200 });
        // -- NextHop (Flags:0x40, Type:3, Len:4, Val: 1.2.3.4)
        try list.appendSlice(&[_]u8{ 0x40, 3, 4, 1, 2, 3, 4 });
        // -- MED (Flags:0x80, Type:4, Len:4, Val: 1234)
        try list.appendSlice(&[_]u8{ 0x80, 4, 4, 0, 0, 4, 210 });
        // -- LocalPref (Flags:0x40, Type:5, Len:4, Val: 100)
        try list.appendSlice(&[_]u8{ 0x40, 5, 4, 0, 0, 0, 100 });
        // -- AtomicAggregate (Flags:0x40, Type:6, Len:0)
        try list.appendSlice(&[_]u8{ 0x40, 6, 0 });
        // -- Aggregator (Flags:0xC0, Type:7, Len:6, Val: AS 65001, 1.2.3.4)
        try list.appendSlice(&[_]u8{ 0xC0, 7, 6, 0xFD, 0xE9, 1, 2, 3, 4 });
        // -- Unknown Short (Flags:0x80, Type:100, Len:3)
        try list.appendSlice(&[_]u8{ 0x80, 100, 3 });
        try list.appendSlice(&unknownDataShort);
        // -- Unknown Long (Flags:0x90, Type:101, Len:300)
        try list.appendSlice(&[_]u8{ 0x90, 101, 1, 44 });
        try list.appendSlice(&unknownDataLong);

        const attrEndIdx = list.items.len;
        const totalAttrLen: u16 = @intCast(attrEndIdx - attrStartIdx);
        std.mem.writeInt(u16, list.items[attrLenPlaceholderIdx..][0..2], totalAttrLen, .big);

        // Advertised (1 route: 192.168.1.0/24 -> 4 bytes)
        try list.appendSlice(&[_]u8{ 24, 192, 168, 1 });

        break :blk list;
    };
    defer messageBuffer.deinit();

    var stream = std.io.fixedBufferStream(messageBuffer.items);
    var readBuffer: [1024]u8 = undefined;
    var reader = stream.reader().adaptToNewApi(&readBuffer);
    var updateReader = UpdateMsgParser{
        .allocator = testing.allocator,
        .reader = &reader.new_interface,
    };

    var message = try updateReader.readUpdateMessage(@intCast(messageBuffer.items.len));
    defer message.deinit();

    // Verify Routes
    try testing.expectEqual(@as(usize, 1), message.withdrawnRoutes.len);
    try testing.expectEqual(@as(u8, 24), message.withdrawnRoutes[0].prefixLength);
    try testing.expectEqualSlices(u8, &[_]u8{ 10, 0, 0, 0 }, &message.withdrawnRoutes[0].prefixData);

    try testing.expectEqual(@as(usize, 1), message.advertisedRoutes.len);
    try testing.expectEqual(@as(u8, 24), message.advertisedRoutes[0].prefixLength);
    try testing.expectEqualSlices(u8, &[_]u8{ 192, 168, 1, 0 }, &message.advertisedRoutes[0].prefixData);

    // Verify Attributes
    const attrs = message.pathAttributes.list.items;
    try testing.expectEqual(@as(usize, 9), attrs.len);

    try testing.expectEqual(ribModel.Origin.IGP, attrs[0].Origin.value);
    
    try testing.expectEqual(@as(usize, 1), attrs[1].AsPath.value.segments.len);
    try testing.expectEqual(ribModel.ASPathSegmentType.AS_Sequence, attrs[1].AsPath.value.segments[0].segType);
    try testing.expectEqualSlices(u16, &[_]u16{ 100, 200 }, attrs[1].AsPath.value.segments[0].contents);

    try testing.expect(attrs[2].Nexthop.value.equals(ip.IpV4Address.parse("1.2.3.4") catch unreachable));
    try testing.expectEqual(@as(u32, 1234), attrs[3].MultiExitDiscriminator.value);
    try testing.expectEqual(@as(u32, 100), attrs[4].LocalPref.value);
    try testing.expect(attrs[5].AtomicAggregate.value);
    try testing.expectEqual(@as(u16, 65001), attrs[6].Aggregator.value.as);
    try testing.expect(attrs[6].Aggregator.value.address.equals(ip.IpV4Address.init(1, 2, 3, 4)));

    try testing.expectEqual(@as(u8, 100), attrs[7].Unknown.value.typeCode);
    try testing.expectEqualSlices(u8, &unknownDataShort, attrs[7].Unknown.value.value);

    try testing.expectEqual(@as(u8, 101), attrs[8].Unknown.value.typeCode);
    try testing.expectEqualSlices(u8, &unknownDataLong, attrs[8].Unknown.value.value);
    try testing.expect((attrs[8].Unknown.flags & ribModel.ATTR_EXTENDED_LENGTH_FLAG) != 0);
}
