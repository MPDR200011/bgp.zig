const std = @import("std");
const net = std.net;
const posix = std.posix;

const config = @import("config/json.zig");
const session = @import("sessions/session.zig");

const PeerMap = @import("peer_map.zig").PeerMap;

const Allocator = std.mem.Allocator;
const Self = @This();

const v4PeerSessionAddresses = session.v4PeerSessionAddresses;

alloc: Allocator,
socket: posix.socket_t,
processConfig: *const config.Config,

pub fn getAddrString(address: net.Address, allocator: std.mem.Allocator) ![]const u8 {
    var addressBuffer: [64]u8 = undefined;
    var addressWriter = std.Io.Writer.fixed(&addressBuffer);
    try address.format(&addressWriter);

    const newBuffer: []u8 = try allocator.alloc(u8, addressWriter.end);
    errdefer allocator.free(newBuffer);

    std.mem.copyForwards(u8, newBuffer, addressBuffer[0..addressWriter.end]);
    return newBuffer;
}

const AcceptContext = struct {
    conn: net.Server.Connection,
    peerMap: *const PeerMap,
    allocator: Allocator,
    localConfig: config.LocalConfig,
};

const AcceptHandlerError = error{
    PeerNotConfigured,
    ParsingError,
    UnexpectedMessageType,
};

fn wrapper(ctx: AcceptContext) !void {
    const peerAddr = ctx.conn.address;
    const peerAddrStr = try getAddrString(peerAddr, ctx.allocator);
    var peerSepIdx: usize = 0;
    for (peerAddrStr, 0..) |c, i| {
        if (c == ':') {
            peerSepIdx = i;
            break;
        }
    }
    defer ctx.allocator.free(peerAddrStr);

    var local_addr: net.Address = undefined;
    var addr_len: posix.socklen_t = @sizeOf(net.Address);
    posix.getsockname(ctx.conn.stream.handle, &local_addr.any, &addr_len) catch |err| {
        std.log.err("Error getting local address for connection : {s}", .{@errorName(err)});
    };
    const localAddrStr = try getAddrString(peerAddr, ctx.allocator);
    var localSepIdx: usize = 0;
    for (localAddrStr, 0..) |c, i| {
        if (c == ':') {
            localSepIdx = i;
            break;
        }
    }
    defer ctx.allocator.free(localAddrStr);

    const peer = ctx.peerMap.get(v4PeerSessionAddresses{
        .localAddress = try .parse(localAddrStr[0..localSepIdx]),
        .peerAddress = try .parse(peerAddrStr[0..peerSepIdx]),
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
                std.log.info("Session is idle and not accepting connections", .{});
                ctx.conn.stream.close();
                return;
            },
            .ACTIVE => {
                // Looking for connection, accept it
                try peer.session.submitEvent(.{ .TcpConnectionSuccessful = ctx.conn.stream });
                return;
            },
            else => {},
        }

        // From here on, we need to spin up a parallel FSM and track this connection until collision happens
    }
}

pub fn acceptHandler(ctx: AcceptContext) void {
    errdefer ctx.conn.stream.close();

    wrapper(ctx) catch |err| {
        std.log.err("Error handling incoming connection: {}", .{err});
    };
}

fn acceptThread(self: *Self, peerMap: *const PeerMap) void {
    while (true) {
        var client_address: net.Address = undefined;
        var client_address_len: posix.socklen_t = @sizeOf(net.Address);

        const socket = posix.accept(self.socket, &client_address.any, &client_address_len, 0) catch |err| switch (err) {
            error.SocketNotListening => {
                return;
            },
            else => {
                // Rare that this happens, but in later parts we'll
                // see examples where it does.
                std.debug.print("error accept: {}\n", .{err});
                continue;
            }
        };
        errdefer posix.close(socket);

        const peerAddrStr = getAddrString(client_address, self.alloc) catch |err| {
            std.log.err("Error getting client address string {}", .{err});
            posix.close(socket);
            continue;
        };
        defer self.alloc.free(peerAddrStr);

        std.log.info("Connection received from {s}", .{peerAddrStr});

        const acceptContext: AcceptContext = .{ 
            .conn = .{
                .stream = .{ .handle = socket },
                .address = client_address,
            }, 
            .peerMap = peerMap, 
            .allocator = self.alloc, 
            .localConfig = self.processConfig.localConfig 
        };
        var acceptHandlerThread = std.Thread.spawn(.{}, acceptHandler, .{acceptContext}) catch |err| {
            std.log.err("Error starting accept handler {}", .{err});
            posix.close(socket);
            continue;
        };
        acceptHandlerThread.join();
    }
}

pub fn init(alloc: Allocator, localPort: u16, processConfig: *const config.Config) !Self {
    const address = net.Address.initIp4(.{ 127, 0, 0, 1 }, localPort);

    const listener = try posix.socket(address.any.family, posix.SOCK.STREAM, posix.IPPROTO.TCP);
    errdefer posix.close(listener);

    try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    try posix.bind(listener, &address.any, address.getOsSockLen());
    try posix.listen(listener, 128);

    return Self{
        .alloc = alloc,
        .socket = listener,
        .processConfig = processConfig,
    };
}

pub fn start(self: *Self, peerMap: *const PeerMap) !std.Thread {
    return try std.Thread.spawn(.{}, acceptThread, .{self, peerMap});
}

pub fn stop(self: *Self) !void {
    try posix.shutdown(self.socket, .both);
}
