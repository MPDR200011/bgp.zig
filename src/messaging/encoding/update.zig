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

fn calculateAttributesLength(attrs: PathAttributes) usize {
    // FIXME complete dis
    _ = attrs;
    return 0;
}

fn writeAttributes(attrs: PathAttributes, writer: *std.Io.Writer) !void {
    // FIXME complete dis
    _ = attrs;
    _ = writer;
}

pub fn writeUpdateBody(msg: model.UpdateMessage, writer: *std.Io.Writer) !void {
    try writer.writeInt(u16, @intCast(calculateRoutesLength(msg.withdrawnRoutes)), .big);
    try writeRoutes(msg.withdrawnRoutes, writer);

    try writer.writeInt(u16, @intCast(calculateAttributesLength(msg.pathAttributes)), .big);
    try writeAttributes(msg.pathAttributes, writer);

    try writeRoutes(msg.advertisedRoutes, writer);
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
    const asPath: AsPath = .{
        .allocator = testing.allocator,
        .segments = try testing.allocator.dupe(model.ASPathSegment, &[_]model.ASPathSegment{})
    };

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
        PathAttributes{.allocator = testing.allocator, .origin = .init(.EGP), .asPath = .init(asPath), .nexthop = ip.IpV4Address.init(0, 0, 0, 0), .localPref = 100, .atomicAggregate = false, .multiExitDiscriminator = null, .aggregator = null},
    );
    defer msg.deinit();

    // zig fmt: off
    const expectedBuffer = [_]u8{ 
        // Withdrawn
        0, 6,
        16, 0xff, 0xff, 
        12, 0, 0xff, 
        // Attrs
        0, 0,
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
