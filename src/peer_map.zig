const std = @import("std");
const ip = @import("ip");

const session = @import("sessions/session.zig");

const v4PeerSessionAddress = ip.IpV4Address;
const Peer = session.Peer;

pub const PeerMapCtx = struct {
    const Self = @This();

    pub fn hash(_: Self, s: v4PeerSessionAddress) u64 {
        const hashFn = std.hash_map.getAutoHashFn(ip.IpV4Address, void);
        return hashFn({}, s);
    }

    pub fn eql(_: Self, s1: v4PeerSessionAddress, s2: v4PeerSessionAddress) bool {
        return s1.equals(s2);
    }
};

pub const PeerMap = std.HashMap(v4PeerSessionAddress, *Peer, PeerMapCtx, std.hash_map.default_max_load_percentage);

