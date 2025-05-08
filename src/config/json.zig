const std = @import("std");
const zul = @import("zul");

const Allocator = std.mem.Allocator;

pub const LocalConfig = struct {
    asn: u16,
    routerId: u32,

    localPort: ?u16,
};

pub const PeerDefinition = struct {
    localAddress: []const u8,

    peerAddress: []const u8,
    peerPort: ?u16,

    peeringMode: []const u8,
    delayOpen_s: ?u32,
};

pub const NetworkDefinition = struct {
    afi: u8,
    address: []const u8,
};

pub const Config = struct {
    localConfig: LocalConfig,
    peers: []const PeerDefinition,
    networks: []const NetworkDefinition,
};

pub fn loadConfig(allocator: Allocator, configPath: []const u8) !zul.Managed(Config) {
    return try zul.fs.readJson(Config, allocator, configPath, .{
        .ignore_unknown_fields = true,
    });
}
