const std = @import("std");
const builtin = @import("builtin");
const net = std.net;
const headerReader = @import("parsing/header.zig");
const openReader = @import("parsing/open.zig");

pub fn main() !void {
    std.debug.print("Hello World!\n", .{});


    // zig fmt: off
    var stream = std.io.fixedBufferStream(&[_]u8{
        0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff,
        0x00, 0x13, 0x01 
    });
    _ = try headerReader.readHeader(stream.reader());

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

    const client_reader = client.stream.reader();
    const client_writer = client.stream.writer();

    const buffer: []u8 = try std.heap.page_allocator.alloc(u8, 5);
    defer std.heap.page_allocator.free(buffer);

    const messageHeader = try headerReader.readHeader(client_reader);

    std.debug.print("Received header: msg length = {d}, msg type {s}", .{ messageHeader.messageLength, @tagName(messageHeader.messageType) });

    switch (messageHeader.messageType) {
        .OPEN => openReader.readOpenMessage(client_reader),
        else => {
            std.process.exit(1);
        }
    }


    client_writer.writeAll("ACK") catch |err| {
        std.debug.print("unable to write bytes: {}\n", .{err});
    };
}
