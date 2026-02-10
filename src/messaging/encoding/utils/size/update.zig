const std = @import("std");
const model = @import("../../../model.zig");

fn calculateRouteSize(route: *const model.Route) usize {
    var l = route.prefixLength / 8;
    if (route.prefixLength % 8 > 0) {
        l += 1;
    }

    return l;
}

const t = std.testing;

test "calculateRouteSize" {
    try t.expectEqual(1, calculateRouteSize(&model.Route{ .prefixData = .{0,0,0,0}, .prefixLength = 7}));
    try t.expectEqual(1, calculateRouteSize(&model.Route{ .prefixData = .{0,0,0,0}, .prefixLength = 8}));
    try t.expectEqual(2, calculateRouteSize(&model.Route{ .prefixData = .{0,0,0,0}, .prefixLength = 9}));


    try t.expectEqual(3, calculateRouteSize(&model.Route{ .prefixData = .{0,0,0,0}, .prefixLength = 20}));
    try t.expectEqual(3, calculateRouteSize(&model.Route{ .prefixData = .{0,0,0,0}, .prefixLength = 24}));
    try t.expectEqual(4, calculateRouteSize(&model.Route{ .prefixData = .{0,0,0,0}, .prefixLength = 26}));
}
