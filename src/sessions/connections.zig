const std = @import("std");
const net = std.net;
const session = @import("session.zig");

const model = @import("../messaging/model.zig");
const consts = @import("../messaging/consts.zig");
const headerReader = @import("../messaging/parsing/header.zig");
const openReader = @import("../messaging/parsing/open.zig");
const notificationReader = @import("../messaging/parsing/notification.zig");
const bgpEncoding = @import("../messaging/encoding/encoder.zig");

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

    // TODO: this guy will need to know if the connection teardown is graceful or not,
    // possibly a "graceful" flag in the session struct?
    connection: while (true) {
        const messageHeader = headerReader.readHeader(clientReader) catch |e| {
            std.log.err("Error reading message header: {}", .{e});
            return;
        };

        const message: model.BgpMessage = switch (messageHeader.messageType) {
            .OPEN => .{ .OPEN = openReader.readOpenMessage(clientReader) catch |err| {
                std.log.err("Error parsing OPEN message: {}", .{err});
                break :connection;
            }},
            .KEEPALIVE => .{ .KEEPALIVE = .{} },
            .NOTIFICATION => .{ .NOTIFICATION = notificationReader.readNotificationMessage(clientReader, messageHeader.messageLength - consts.HEADER_LENGTH - 2, ctx.allocator) catch |err| {
                std.log.err("Error parsing NOTIFICATION message: {}", .{err});
                break :connection;
            }},
            else => {
                break :connection;
            },
        };

        defer {
            switch (message) {
                .NOTIFICATION => |msg| {
                    msg.deinit();
                },
                else => {}
            }
        }

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
