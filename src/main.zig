const std = @import("std");
const builtin = @import("builtin");
const net = std.net;
const posix = std.posix;
const Allocator = std.mem.Allocator;
const fsm = @import("sessions/fsm.zig");

const model = @import("messaging/model.zig");
const headerReader = @import("messaging/parsing/header.zig");
const openReader = @import("messaging/parsing/open.zig");
const bgpEncoding = @import("messaging/encoding/encoder.zig");

pub fn getAddrString(address: net.Address, allocator: std.mem.Allocator) ![]const u8 {
    var addressBuffer: [32]u8 = undefined;
    var addressStream = std.io.fixedBufferStream(&addressBuffer);
    const addressWriter = addressStream.writer();
    try address.format("", .{}, addressWriter);

    const newBuffer: []u8 = try allocator.alloc(u8, addressStream.getPos() catch unreachable);
    std.mem.copyForwards(u8, newBuffer, addressStream.getWritten());
    return newBuffer;
}

pub fn connectionHandler(conn: net.Server.Connection, allocator: Allocator) !void {
    _  = allocator;

    defer conn.stream.close();

    // const peer_addr = conn.address;

    var local_addr: net.Address = undefined;
    var addr_len: posix.socklen_t = @sizeOf(net.Address);
    posix.getsockname(conn.stream.handle, &local_addr.any, &addr_len) catch |err| {
        std.log.err("Error getting local address for connection : {s}", .{@errorName(err)});
    };

    // TODO: get the configured peer, close connection if the peer is not configured

    const client_reader = conn.stream.reader().any();

    while (true) {
        const messageHeader = try headerReader.readHeader(client_reader);
        const message: model.BgpMessage = switch (messageHeader.messageType) {
            .OPEN => _ = try openReader.readOpenMessage(client_reader),
            .KEEPALIVE => {},
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

    const addr = net.Address.initIp4(.{ 127, 0, 0, 1 }, 179);

    std.log.info("Listening on port 179", .{});
    var server = try addr.listen(.{});

    const client = try server.accept();

    const peerAddrStr = try getAddrString(client.address, gpa);
    defer gpa.free(peerAddrStr);

    std.log.info("Connection received from {s}", .{peerAddrStr});

    var connectionThread = try std.Thread.spawn(.{}, connectionHandler, .{client, gpa});

    connectionThread.join();
}
