const std = @import("std");
const builtin = @import("builtin");
const net = std.net;
const posix = std.posix;
const process = std.process;
const clap = @import("clap");

const Allocator = std.mem.Allocator;

const session = @import("sessions/session.zig");
const connections = @import("sessions/connections.zig");

const model = @import("messaging/model.zig");
const headerReader = @import("messaging/parsing/header.zig");
const openReader = @import("messaging/parsing/open.zig");
const bgpEncoding = @import("messaging/encoding/encoder.zig");

const PeerSessionAddresses = session.PeerSessionAddresses;
const Peer = session.Peer;

pub const std_options: std.Options = .{
    // Set the log level to info
    .log_level = .info,

    // Define logFn to override the std implementation
    .logFn = myLogFn,
};

pub fn myLogFn(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    // Ignore all non-error logging from sources other than
    // .my_project, .nice_library and the default
    const scope_prefix = "(" ++ @tagName(scope) ++ "): ";

    comptime var upperLevel = [_]u8{0};
    comptime _ = std.ascii.upperString(&upperLevel, level.asText()[0..1]);
    const prefix = comptime upperLevel ++ " " ++ scope_prefix;

    // Print the message to stderr, silently ignoring any errors
    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();
    const stderr = std.io.getStdErr().writer();
    nosuspend stderr.print(prefix ++ format ++ "\n", args) catch return;
}

pub const PeerMapCtx = struct {
    const Self = @This();

    pub fn hash(_: Self, s: PeerSessionAddresses) u64 {
        return std.hash_map.hashString(s.localAddress) ^ std.hash_map.hashString(s.peerAddress);
    }

    pub fn eql(_: Self, s1: PeerSessionAddresses, s2: PeerSessionAddresses) bool {
        return std.hash_map.eqlString(s1.localAddress, s2.localAddress) and std.hash_map.eqlString(s1.peerAddress, s2.peerAddress);
    }
};

pub const PeerMap = std.HashMap(PeerSessionAddresses, *Peer, PeerMapCtx, std.hash_map.default_max_load_percentage);

pub fn getAddrString(address: net.Address, allocator: std.mem.Allocator) ![]const u8 {
    var addressBuffer: [32]u8 = undefined;
    var addressStream = std.io.fixedBufferStream(&addressBuffer);
    const addressWriter = addressStream.writer();
    try address.format("", .{}, addressWriter);

    const newBuffer: []u8 = try allocator.alloc(u8, addressStream.getPos() catch unreachable);
    errdefer allocator.free(newBuffer);

    std.mem.copyForwards(u8, newBuffer, addressStream.getWritten());
    return newBuffer;
}

const DeviceConfig = struct {
    asn: u16,
    routerId: u32,
};

const AcceptContext = struct {
    conn: net.Server.Connection,
    peerMap: *PeerMap,
    allocator: Allocator,
    localConfig: DeviceConfig,
};

const AcceptHandlerError = error{
    PeerNotConfigured,
    ParsingError,
    UnexpectedMessageType,
};

pub fn acceptHandler(ctx: AcceptContext) !void {
    errdefer ctx.conn.stream.close();

    const peerAddr = ctx.conn.address;
    const peerAddrStr = try getAddrString(peerAddr, ctx.allocator);
    defer ctx.allocator.free(peerAddrStr);

    var local_addr: net.Address = undefined;
    var addr_len: posix.socklen_t = @sizeOf(net.Address);
    posix.getsockname(ctx.conn.stream.handle, &local_addr.any, &addr_len) catch |err| {
        std.log.err("Error getting local address for connection : {s}", .{@errorName(err)});
    };
    const localAddrStr = try getAddrString(peerAddr, ctx.allocator);
    defer ctx.allocator.free(localAddrStr);

    const peer = ctx.peerMap.get(PeerSessionAddresses{
        .localAddress = localAddrStr,
        .peerAddress = peerAddrStr,
    }) orelse {
        std.log.info("Received connection request from unconfigured peer localAddr={s} remoteAddr={s}", .{ localAddrStr, peerAddrStr });
        return AcceptHandlerError.PeerNotConfigured;
    };

    {
        peer.lock();
        defer peer.unlock();

        switch (peer.session.state) {
            .IDLE => {
                // IDLE sessions should not accept connections as they are not looking for one
                ctx.conn.stream.close();
                return;
            },
            .ACTIVE => {
                // Looking for connection, accept it
                try peer.session.handleEvent(.{ .TcpConnectionSuccessful = ctx.conn.stream });
                return;
            },
            else => {},
        }

        // From here on, we need to spin up a parallel FSM and track this connection until collision happens
    }
}

pub fn main() !void {
    std.log.info("Hello World!", .{});
    std.log.info("Initializing BGP Listener", .{});

    // Initializing GPA for the process
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
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
        switch (debug_allocator.deinit()) {
            .leak => std.debug.print("UNFREE'D MEMORY DETECTED!!!! CHECK YOUR ALLOCS!!! >:(\n", .{}),
            else => std.debug.print("No memory leaks detected :)\n", .{}),
        }
    };

    const params = comptime clap.parseParamsComptime(
        \\-h, --help     Display this help and exit.
        \\--local_addr  <str>   Local address of the peering session, will also be used as router id
        \\--local_port  <port>  Local port to listen on
        \\--peer_addr   <str>   Address of peer to connect to
        \\--peer_port  <port>   Port Peer is listening on
        \\--peering_mode    <PEER_MODE> Peering Mode
        \\--local_asn   <asn>   Local ASN
        \\--router_id   <rID>   Router ID to use
    );

    const parsers = comptime .{ .str = clap.parsers.string, .asn = clap.parsers.int(u16, 10), .rID = clap.parsers.int(u32, 10), .PEER_MODE = clap.parsers.enumeration(session.Mode), .port = clap.parsers.default.u16 };

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, parsers, .{
        .diagnostic = &diag,
        .allocator = gpa,
    }) catch |err| {
        // Report useful error and exit.
        diag.report(std.io.getStdErr().writer(), err) catch {};
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        return clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{});
    }

    const localAddr = res.args.local_addr orelse "127.0.0.1";
    const peerAddr = res.args.peer_addr orelse {
        std.debug.print("Missing peer_addr\n", .{});
        return clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{});
    };

    const peeringMode = res.args.peering_mode orelse {
        std.debug.print("Missing peering_mode\n", .{});
        return clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{});
    };

    const localConfig: DeviceConfig = .{
        .asn = res.args.local_asn orelse {
            std.debug.print("Missing local_asn\n", .{});
            return clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{});
        },
        .routerId = res.args.router_id orelse {
            std.debug.print("Missing router_id\n", .{});
            return clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{});
        },
    };

    const localPort = res.args.local_port orelse 179;
    const peerPort = res.args.peer_port orelse 179;

    var peerMap = PeerMap.init(gpa);
    defer {
        var it = peerMap.valueIterator();
        while (it.next()) |peer| {
            peer.*.deinit();
            gpa.destroy(peer.*);
        }
        peerMap.deinit();
    }

    {
        const peer = try gpa.create(Peer);
        peer.* = .init(.{
            .localAsn = localConfig.asn,
            .holdTime = 60,
            .localRouterId = localConfig.routerId,
            .peeringMode = peeringMode,
            .delayOpen = false,
            .sessionAddresses = .{
                .localAddress = localAddr,
                .peerAddress = peerAddr,
            },
            .sessionPorts = .{
                .localPort = localPort,
                .peerPort = peerPort,
            },
        }, peer, gpa);

        try peerMap.put(peer.sessionAddresses, peer);
    }


    var it = peerMap.valueIterator();
    while (it.next()) |peer| {
        try peer.*.session.handleEvent(.{ .Start = {} });
    }

    const addr = net.Address.initIp4(.{ 127, 0, 0, 1 }, localPort);

    std.log.info("Listening on port {}", .{localPort});
    var server = try addr.listen(.{});

    const client = try server.accept();

    const peerAddrStr = try getAddrString(client.address, gpa);
    defer gpa.free(peerAddrStr);

    std.log.info("Connection received from {s}", .{peerAddrStr});

    const acceptContext: AcceptContext = .{ .conn = client, .peerMap = &peerMap, .allocator = gpa, .localConfig = localConfig };
    var acceptThread = try std.Thread.spawn(.{}, acceptHandler, .{acceptContext});
    acceptThread.join();
}
