const std = @import("std");
const model = @import("../model.zig");

const Route = model.Route;
const Attribute = model.PathAttribute;

const UpdateParsingError = error{ RoutesLengthInconsistent, AttributesLengthInconsistent, InvalidPrefixLength };

pub const UpdateMsgParser = @This();
const Self = UpdateMsgParser;

reader: std.io.AnyReader,
allocator: std.mem.Allocator,

fn readIntoRoute(self: Self, route: *Route) !u16 {
    const prefixLength = try self.reader.readInt(u8, .big);
    if (prefixLength > 32) {
        std.debug.print("Invalid prefix length: {}\n", .{prefixLength});
        return UpdateParsingError.InvalidPrefixLength;
    }

    const prefixByteLength: u8 = (prefixLength / 8) + @as(u8, if ((prefixLength % 8) > 0) 1 else 0);
    std.debug.assert(prefixByteLength <= 4);

    route.prefixLength = prefixLength;
    route.prefixData = [4]u8{0,0,0,0};

    var bitsToRead: i32 = @intCast(prefixLength);
    for (0..prefixByteLength) |i| {
        const addressByte = try self.reader.readInt(u8, .big);

        const shiftAmount: u4 = 8 - @min(8, @as(u8, @intCast(bitsToRead)));
        const mask: u8 = @truncate(@as(u16, 0xff) << shiftAmount);

        route.prefixData[i] = addressByte & mask;

        bitsToRead -= 8;
    }

    return (prefixByteLength + 1);
}

fn readRoutes(self: Self, routesLength: u16) !std.ArrayList(Route) {
    var routesList = std.ArrayList(Route).init(self.allocator);
    errdefer routesList.deinit();

    var bytesToRead: i32 = @intCast(routesLength);
    while (bytesToRead > 0) {
        const route = try routesList.addOne();

        bytesToRead -= try self.readIntoRoute(route);
    }

    if (bytesToRead != 0) {
        return UpdateParsingError.RoutesLengthInconsistent;
    }

    return routesList;
}

fn readAttributes(self: Self, attributesLength: u16) !std.ArrayList(Attribute) {
    const attributesList = std.ArrayList(Attribute).init(self.allocator);
    errdefer attributesList.deinit();

    var bytesToRead: i32 = @intCast(attributesLength);
    while (bytesToRead > 0) {
        const attributeFlags = try self.reader.readInt(u8, .big);
        const attributeType = try self.reader.readInt(u8, .big);
        _ = attributeType;

        const extendedLength: bool = (attributeFlags & (0b00010000)) > 0;
        const attributeLength: u16 = if (extendedLength) try self.reader.readInt(u16, .big) else @intCast(try self.reader.readInt(u8, .big));

        // TODO parse attributes
        try self.reader.skipBytes(attributeLength, .{});

        bytesToRead -= 1;
        bytesToRead -= if (extendedLength) 2 else 1;
        bytesToRead -= attributeLength;
    }

    if (bytesToRead != 0) {
        return UpdateParsingError.AttributesLengthInconsistent;
    }

    return attributesList;
}

pub fn readUpdateMessage(self: Self, messageLength: u16) !model.UpdateMessage {
    const withdrawnLength = try self.reader.readInt(u16, .big);
    const withdrawnRoutes = try self.readRoutes(withdrawnLength);
    defer withdrawnRoutes.deinit();

    const attributesLength = try self.reader.readInt(u16, .big);
    const routeAttributes = try self.readAttributes(attributesLength);
    defer routeAttributes.deinit();

    const advertisedLength = messageLength - withdrawnLength - attributesLength;
    const advertisedRoutes = try self.readRoutes(advertisedLength);
    defer advertisedRoutes.deinit();

    return .init(self.allocator, withdrawnRoutes.items, advertisedRoutes.items, routeAttributes.items);
}

const testing = std.testing;

fn testReadIntoRoute(routeBuffer: []const u8, expectedReadBytes: u16, expectedRoute: Route) !void {
    var stream = std.io.fixedBufferStream(routeBuffer[0..]);
    const updateReader = Self{
        .allocator = testing.allocator,
        .reader = stream.reader().any(),
    };

    var actualRoute: Route = undefined;
    const readBytes = try updateReader.readIntoRoute(&actualRoute);

    try testing.expectEqual(expectedRoute, actualRoute);
    try testing.expectEqual(expectedReadBytes, readBytes);
}

test "readIntoRoute()" {
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

    const updateReader = Self{
        .allocator = testing.allocator,
        .reader = stream.reader().any(),
    };
    const routes = try updateReader.readRoutes(routesBuffer.len);
    defer routes.deinit();

    const expectedRoutes = [_]Route{
        Route{ .prefixLength = 32, .prefixData = [_]u8{ 192, 168, 0, 42 } },
        Route{ .prefixLength = 16, .prefixData = [_]u8{ 192, 168, 0, 0 } },
        Route{ .prefixLength = 12, .prefixData = [_]u8{ 192, 0b10110000, 0, 0 } },
    };
    try testing.expectEqualSlices(Route, expectedRoutes[0..], routes.items);
}
