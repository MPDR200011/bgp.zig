const std = @import("std");
const connections = @import("../connections.zig");
const sessionLib = @import("../session.zig");
const model = @import("../../messaging/model.zig");

const Session = sessionLib.Session;
const Peer = sessionLib.Peer;

const PostHandlerAction = sessionLib.PostHandlerAction;
const Event = sessionLib.Event;

fn handleStart(peer: *Peer) !PostHandlerAction {
    var session = &peer.session;

    session.connectionRetryCount = 0;
    try session.connectionRetryTimer.start(Session.CONNECTION_RETRY_TIMER_DEFAULT);

    if (peer.mode == .PASSIVE) {
        return .{
            .Transition = .ACTIVE,
        };
    }

    session.startConnection() catch |err| {
        // BGP connection failed
        // By the BGP spec, this should be run while in the CONNECT state.
        // However, I don't know how to do asynchronous TCP connection stuff
        // for that to be possible (i.e. start the connection here, and receive
        // event later) and I don't want to learn that right now, so I'll
        // handle that here.

        std.log.err("Error attempting to start connection to peer: {}", .{err});

        // Cancel the retry timer
        session.connectionRetryTimer.cancel();

        return .{
            .Keep = {},
        };
    };
    session.connectionRetryTimer.cancel();

    if (peer.delayOpen) {
        try session.delayOpenTimer.start(peer.delayOpen_ms);
        return .{ .Transition = .CONNECT };
    }

    const openMsg: model.BgpMessage = .{ .OPEN = .{ .version = 4, .asNumber = peer.localAsn, .holdTime = peer.holdTime, .peerRouterId = 0, .parameters = null } };
    try session.messageEncoder.writeMessage(openMsg, session.peerConnection.?.writer().any());
    try session.holdTimer.start(4 * std.time.ms_per_min);
    return .{ .Transition = .OPEN_SENT };
}

pub fn handleEvent(peer: *Peer, event: Event) !PostHandlerAction {
    switch (event) {
        .Start => return try handleStart(peer),
        else => return .{ .Keep = {} },
    }
}
