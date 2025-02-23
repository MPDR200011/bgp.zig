const std = @import("std");
const builtin = @import("builtin");
const net = std.net;
const model = @import("messaging/model.zig");
const headerReader = @import("messaging/parsing/header.zig");
const openReader = @import("messaging/parsing/open.zig");
const bgpEncoding = @import("messaging/encoding/encoder.zig");

pub fn main() !void {
    std.debug.print("Hello World!\n", .{});

    const addr = net.Address.initIp4(.{ 127, 0, 0, 1 }, 8000);

    var server = try addr.listen(.{});

    const client = try server.accept();
    defer client.stream.close();

    const address_buffer: []u8 = try std.heap.page_allocator.alloc(u8, 16 + 16);
    defer std.heap.page_allocator.free(address_buffer);
    var address_stream = std.io.fixedBufferStream(address_buffer);
    const address_writer = address_stream.writer();
    try client.address.format("", .{}, address_writer);

    std.log.info("Connection received: {s}", .{address_stream.getWritten()});

    const client_reader = client.stream.reader().any();
    const client_writer = client.stream.writer().any();

    const messageEncoder = bgpEncoding.MessageEncoder.init();
    defer messageEncoder.deinit();

    try messageEncoder.writeMessage(model.BgpMessage{ .OPEN = .{ .version = 4, .asNumber = 64000, .peerRouterId = 1, .holdTime = 60, .parameters = null } }, client_writer);
    std.debug.print("Wrote message to peer.", .{});

    const messageHeader = try headerReader.readHeader(client_reader);
    std.debug.print("Received header: msg length = {d}, msg type {s}", .{ messageHeader.messageLength, @tagName(messageHeader.messageType) });
    switch (messageHeader.messageType) {
        .OPEN => _ = try openReader.readOpenMessage(client_reader),
        else => {
            std.process.exit(1);
        },
    }

    client_writer.writeAll("ACK") catch |err| {
        std.debug.print("unable to write bytes: {}\n", .{err});
    };
}
