const std = @import("std");
const ip = @import("ip");

const session = @import("sessions/session.zig");

const v4PeerSessionAddresses = session.v4PeerSessionAddresses;
const Peer = session.Peer;

pub const PeerMapCtx = struct {
    const Self = @This();

    pub fn hash(_: Self, s: v4PeerSessionAddresses) u64 {
        const hashFn = std.hash_map.getAutoHashFn(ip.IpV4Address, void);
        return hashFn({}, s.localAddress) ^ hashFn({}, s.peerAddress);
    }

    pub fn eql(_: Self, s1: v4PeerSessionAddresses, s2: v4PeerSessionAddresses) bool {
        return s1.localAddress.equals(s2.localAddress) and s1.peerAddress.equals(s2.peerAddress);
    }
};

pub const PeerMap = std.HashMap(v4PeerSessionAddresses, *Peer, PeerMapCtx, std.hash_map.default_max_load_percentage);

