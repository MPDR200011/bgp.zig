const std = @import("std");
const net = std.net;
const session = @import("session.zig");
const fsm = @import("fsm.zig");

const model = @import("../messaging/model.zig");
const headerReader = @import("../messaging/parsing/header.zig");
const openReader = @import("../messaging/parsing/open.zig");
const bgpEncoding = @import("../messaging/encoding/encoder.zig");

const Peer = session.Peer;

pub const ConnectionHandlerContext = struct {
    peer: *Peer,
};

pub fn connectionHandler(ctx: ConnectionHandlerContext) void {
    if (ctx.peer.sessionInfo.peerConnection == null) {
        std.log.info("There is not peer connection active right now.", .{});
        return;
    }
    const client_reader = ctx.peer.sessionInfo.peerConnection.?.reader().any();

    while (true) {
        const messageHeader = headerReader.readHeader(client_reader) catch |e| {
            std.log.err("Error reading message header: {}", .{e});
            return;
        };
        const message: model.BgpMessage = switch (messageHeader.messageType) {
            .OPEN => .{ .OPEN = openReader.readOpenMessage(client_reader) catch |err| {
                std.log.err("Error parsing OPEN message: {}", .{err});
                return;
            } },
            else => {
                return;
            },
        };

        const event: fsm.Event = switch (message) {
            .OPEN => |openMessage| .{ .OpenReceived = openMessage },
            .KEEPALIVE => .{ .KeepAliveReceived = {} },
            else => return,
        };

        ctx.peer.sessionFSM.handleEvent(event) catch |err| {
            std.log.err("Error handling event {s}: {}", .{ @tagName(event), err });
            return;
        };
    }
}

