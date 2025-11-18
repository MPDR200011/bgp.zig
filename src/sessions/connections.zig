const std = @import("std");
const net = std.net;
const session = @import("session.zig");

const model = @import("../messaging/model.zig");
const consts = @import("../messaging/consts.zig");
const bgpParsing = @import("../messaging/parsing/message_reader.zig");

const Session = session.Session;

pub const ConnectionHandlerContext = struct {
    session: *Session,
    allocator: std.mem.Allocator,
};

pub fn connectionHandler(ctx: ConnectionHandlerContext) void {
    const connection = ctx.session.peerConnection orelse {
        std.log.info("There is no peer connection active right now.", .{});
        return;
    };

    const readerBuffer = ctx.allocator.alloc(u8, 1024) catch |err| {
        std.log.err("Error allocation read buffer {}", .{err});
        return;
    };
    defer ctx.allocator.free(readerBuffer);
    var clientReader = connection.reader(readerBuffer);

    std.log.info("Connection handler thread started.", .{});

    // TODO: this guy will need to know if the connection teardown is graceful or not,
    // possibly a "graceful" flag in the session struct?
    connection: while (true) {
        std.log.debug("Reading next message from socket: {}", .{connection.handle});
        const message: model.BgpMessage = ctx.session.messageReader.readMessage(clientReader.interface()) catch |err| {
            std.log.err("Error reading next BGP message: {}", .{err});

            switch (err) {
                error.EndOfStream => {
                    ctx.session.parent.lock();
                    defer ctx.session.parent.unlock();
                    ctx.session.submitEvent(.{ .TcpConnectionFailed = {} }) catch {
                        std.log.err("Failed to handle TCP error", .{});
                        std.process.abort();
                    };
                    break :connection;
                },
                else => {
                    std.log.err("FATAL: Unhandled Error reading BGP message: {}", .{err});
                    std.process.abort();
                },
            }
        };
        std.log.debug("Got message: {s}", .{@tagName(message)});

        const event: session.Event = switch (message) {
            .OPEN => |openMessage| .{ .OpenReceived = openMessage },
            .KEEPALIVE => .{ .KeepAliveReceived = {} },
            .UPDATE => |msg| .{ .UpdateReceived = msg },
            .NOTIFICATION => |msg| .{ .NotificationReceived = msg },
        };

        // ctx.session.parent.lock();
        // defer ctx.session.parent.unlock();
        ctx.session.submitEvent(event) catch |err| {
            std.log.err("Error handling event {s}: {}", .{ @tagName(event), err });
            break :connection;
        };
    }
}
