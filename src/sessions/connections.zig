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
        std.log.info("There is not peer connection active right now.", .{});
        return;
    };
    const clientReader = connection.reader().any();

    var messageReader = bgpParsing.MessageReader.init(clientReader, ctx.allocator);
    defer messageReader.deinit();

    // TODO: this guy will need to know if the connection teardown is graceful or not,
    // possibly a "graceful" flag in the session struct?
    connection: while (true) {
        const message: model.BgpMessage = messageReader.readMessage() catch |err| {
            std.log.err("Erro reading next BGP message: {}", .{err});
            break :connection;
        };

        defer messageReader.deInitMessage(message);

        const event: session.Event = switch (message) {
            .OPEN => |openMessage| .{ .OpenReceived = openMessage },
            .KEEPALIVE => .{ .KeepAliveReceived = {} },
            .UPDATE => |msg| .{ .UpdateReceived = msg },
            else => {
                std.log.info("NOTIFICATION received", .{});
                break :connection;
            },
        };

        ctx.session.parent.lock();
        defer ctx.session.parent.unlock();
        ctx.session.handleEvent(event) catch |err| {
            std.log.err("Error handling event {s}: {}", .{ @tagName(event), err });
            break :connection;
        };
    }

    connection.close();
}
