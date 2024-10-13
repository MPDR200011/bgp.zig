const std = @import("std");
const net = std.net;

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

    const client_reader = client.stream.reader();
    const client_writer = client.stream.writer();

    const buffer: []u8 = try std.heap.page_allocator.alloc(u8, 5);
    defer std.heap.page_allocator.free(buffer);
    while(true) {
        const read_bytes = client_reader.readAll(buffer) catch |err| {
            std.debug.print("unable to read bytes: {}\n", .{err});
            break;
        };

        std.log.info("Read {} bytes", .{read_bytes});

        if (read_bytes == 0) {
            client_writer.writeByte(1) catch |err| {
                switch (err) {
                    error.BrokenPipe => {
                        std.log.info("Connection closed, terminating loop...", .{});
                        break;
                    },
                    else => {return err;}
                }
            };
            continue;
        }

        const valid_bytes = buffer[0..read_bytes];

        std.log.info("Received message: \"{}\"", .{std.zig.fmtEscapes(valid_bytes)});

        client_writer.writeAll(valid_bytes) catch |err| {
            std.debug.print("unable to write bytes: {}\n", .{err});
            break;
        };
    }
}
