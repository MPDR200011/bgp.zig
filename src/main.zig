const std = @import("std");
const builtin = @import("builtin");
const net = std.net;
const posix = std.posix;
const process = std.process;
const Allocator = std.mem.Allocator;
const fsm = @import("sessions/fsm.zig");
const session = @import("sessions/session.zig");


const model = @import("messaging/model.zig");
const headerReader = @import("messaging/parsing/header.zig");
const openReader = @import("messaging/parsing/open.zig");
const bgpEncoding = @import("messaging/encoding/encoder.zig");


pub const PeerSessionAddresses = struct {
    localAddress: []const u8,
    peerAddress: []const u8,
};

pub const PeerMapCtx = struct {
    const Self = @This();

    pub fn hash(_: Self, s: PeerSessionAddresses) u64 {
        return std.hash_map.hashString(s.localAddress) ^ std.hash_map.hashString(s.peerAddress);
    }

    pub fn eql(_: Self, s1: PeerSessionAddresses, s2: PeerSessionAddresses) bool {
        return std.hash_map.eqlString(s1.localAddress, s2.localAddress) and std.hash_map.eqlString(s1.peerAddress, s2.peerAddress);
    }
};

pub const Peer = struct {
    sessionAddresses: PeerSessionAddresses,
    sessionInfo: session.Session,
    sessionFSM: fsm.SessionFSM,

    const Self = @This();

};

const PeerMap = std.HashMap(PeerSessionAddresses, *Peer, PeerMapCtx, std.hash_map.default_max_load_percentage);

pub fn getAddrString(address: net.Address, allocator: std.mem.Allocator) ![]const u8 {
    var addressBuffer: [32]u8 = undefined;
    var addressStream = std.io.fixedBufferStream(&addressBuffer);
    const addressWriter = addressStream.writer();
    try address.format("", .{}, addressWriter);

    const newBuffer: []u8 = try allocator.alloc(u8, addressStream.getPos() catch unreachable);
    std.mem.copyForwards(u8, newBuffer, addressStream.getWritten());
    return newBuffer;
}

pub fn connectionHandler(conn: net.Server.Connection, peerMap: *PeerMap, allocator: Allocator) !void {
    defer conn.stream.close();

    const peerAddr = conn.address;
    const peerAddrStr = try getAddrString(peerAddr, allocator);
    defer allocator.free(peerAddrStr);

    var local_addr: net.Address = undefined;
    var addr_len: posix.socklen_t = @sizeOf(net.Address);
    posix.getsockname(conn.stream.handle, &local_addr.any, &addr_len) catch |err| {
        std.log.err("Error getting local address for connection : {s}", .{@errorName(err)});
    };
    const localAddrStr = try getAddrString(peerAddr, allocator);
    defer allocator.free(localAddrStr);

    _ = peerMap.get(PeerSessionAddresses{
        .localAddress = localAddrStr,
        .peerAddress = peerAddrStr,
    }) orelse {
        std.log.info("Received connection request from unconfigured peer localAddr={s} remoteAddr={s}", .{localAddrStr, peerAddrStr});
        return;
    };

    // TODO: get the configured peer, close connection if the peer is not configured

    const client_reader = conn.stream.reader().any();

    while (true) {
        const messageHeader = try headerReader.readHeader(client_reader);
        const message: model.BgpMessage = switch (messageHeader.messageType) {
            .OPEN => .{.OPEN = try openReader.readOpenMessage(client_reader)},
            .KEEPALIVE =>.{.KEEPALIVE = .{}},
            else => {
                return;
            },
        };

        const event: fsm.Event = switch(message) {
            .OPEN => |openMessage| .{.OpenReceived = openMessage},
            else => return,
        };

        _ = event;

        // TODO: Pass event to the FSM
    }
}

pub fn main() !void {
    std.log.info("Hello World!", .{});
    std.log.info("Initializing BGP Listener", .{});

    // Initializing GPA for the process
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer {
        switch (debug_allocator.deinit()) {
            .leak => std.debug.print("UNFREE'D MEMORY DETECTED!!!! CHECK YOUR ALLOCS!!! >:(", .{}),
            else => std.debug.print("No memory leaks detected :)", .{}),
        }
    }
    const gpa, const is_debug = gpa: {
        if (builtin.os.tag == .wasi) {
            break :gpa .{ std.heap.wasm_allocator, false };
        }

        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    // TODO: Initialize Peers:
    //      - Src - Dst addresses
    //      - Session objects
    //      - FSMs
    var env = try process.getEnvMap(gpa);
    defer env.deinit();

    const LOCAL_ADDR_ENV_NAME = "BGP_LOCAL_ADDR";
    const PEER_ADDR_ENV_NAME = "BGP_PEER_ADDR";
    const MODE_ENV_NAME = "BGP_MODE";

    const localAddr = env.get(LOCAL_ADDR_ENV_NAME) orelse {
        std.log.err("Missing local address", .{});
        process.exit(1);
    };
    const peerAddr = env.get(PEER_ADDR_ENV_NAME) orelse {
        std.log.err("Missing peer address", .{});
        process.exit(1);
    };
    const modeStr = env.get(MODE_ENV_NAME) orelse {
        std.log.err("Missing bgp mode", .{});
        process.exit(1);
    };

    const mode = std.meta.stringToEnum(session.Mode, modeStr) orelse {
        std.log.err("Invalid bgp mode {s}", .{modeStr});
        process.exit(1);
    };

    var peerMap = PeerMap.init(gpa);
    defer {
        var it = peerMap.valueIterator();
        while (it.next()) |peer| {
            gpa.destroy(peer.*);
        }
        peerMap.deinit();
    }

    const peer = try gpa.create(Peer);
    peer.* = .{
        .sessionAddresses = .{
            .localAddress = localAddr,
            .peerAddress = peerAddr,
        },
        .sessionInfo = .init(mode),
        .sessionFSM = .init(&peer.sessionInfo),
    };

    try peerMap.put(peer.sessionAddresses, peer);


    const addr = net.Address.initIp4(.{ 127, 0, 0, 1 }, 179);

    std.log.info("Listening on port 179", .{});
    var server = try addr.listen(.{});

    const client = try server.accept();

    const peerAddrStr = try getAddrString(client.address, gpa);
    defer gpa.free(peerAddrStr);

    std.log.info("Connection received from {s}", .{peerAddrStr});

    var connectionThread = try std.Thread.spawn(.{}, connectionHandler, .{client, &peerMap, gpa});

    connectionThread.join();
}
