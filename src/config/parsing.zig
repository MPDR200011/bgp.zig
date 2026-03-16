const std = @import("std");
const json = @import("json.zig");
const rib = @import("../rib/model.zig");
const ip = @import("ip");

pub fn parseNetworkToRoute(network: json.NetworkDefinition) !rib.Route {
    var it = std.mem.splitScalar(u8, network.address, '/');

    const parsedIp = ip.IpV4Address.parse(it.next() orelse return error.InvalidNetworkString) catch |err| {
        std.log.err("Error parsing network {s}: {any}", .{network.address, err});
        return err;
    };
    const prefixLength = std.fmt.parseInt(u8, it.next() orelse return error.InvalidNetworkString, 10) catch |err| {
        std.log.err("Error parsing network {s}: {any}", .{network.address, err});
        return err;
    };

    return .{
        .prefixLength = prefixLength,
        .prefixData = parsedIp.address,
    };
}
