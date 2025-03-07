const std = @import("std");
const builtin = @import("builtin");
const net = std.net;
const posix = std.posix;
const Allocator = std.mem.Allocator;

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
    defer conn.stream.close();

    // const peer_addr = conn.address;

    var local_addr: net.Address = undefined;
    var addr_len: posix.socklen_t = @sizeOf(net.Address);
    posix.getsockname(conn.stream.handle, &local_addr.any, &addr_len) catch |err| {
        std.log.err("Error getting local address for connection : {s}", .{@errorName(err)});
    };

    const client_reader = conn.stream.reader().any();
    const client_writer = conn.stream.writer().any();

    var messageEncoder = bgpEncoding.MessageEncoder.init(allocator);
    defer messageEncoder.deinit();

    try messageEncoder.writeMessage(model.BgpMessage{ .OPEN = .{ .version = 4, .asNumber = 64000, .peerRouterId = 1, .holdTime = 60, .parameters = null } }, client_writer);

    const messageHeader = try headerReader.readHeader(client_reader);
    switch (messageHeader.messageType) {
        .OPEN => _ = try openReader.readOpenMessage(client_reader),
        .KEEPALIVE => {},
        else => {
            return;
        },
    }

    client_writer.writeAll("ACK") catch |err| {
        std.debug.print("unable to write bytes: {}\n", .{err});
    };
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
