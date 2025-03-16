const std = @import("std");
const connections = @import("../connections.zig");
const sessionLib = @import("../session.zig");
const fsmLib = @import("../fsm.zig");
const model = @import("../../messaging/model.zig");

const Session = sessionLib.Session;
const Peer = sessionLib.Peer;

const PostHandlerAction = fsmLib.PostHandlerAction;
const Event = fsmLib.Event;

fn handleStart(peer: *Peer) !PostHandlerAction {
    var session = &peer.sessionInfo;

    session.mutex.lock();
    defer session.mutex.unlock();

    session.connectionRetryCount = 0;
    try session.connectionRetryTimer.start(Session.CONNECTION_RETRY_TIMER_DEFAULT);

    if (peer.mode == .PASSIVE) {
        return .{
            .Transition = .ACTIVE,
        };
    }

    // Start Connection Thread
    const peerAddress = std.net.Address.parseIp(peer.sessionAddresses.peerAddress, 179) catch {
        return .{ .Keep = {} };
    };
    const peerConnection = std.net.tcpConnectToAddress(peerAddress) catch {
        // BGP connection failed
        // By the BGP spec, this should be run while in the CONNECT state.
        // However, I don't know how to do asynchronous TCP connection stuff
        // for that to be possible (i.e. start the connection here, and receive
        // event later) and I don't want to learn that right now, so I'll
        // handle that here.

        // TODO: check delay open timer, when we implement that

        // Cancel the retry timer
        session.connectionRetryTimer.cancel();

        // Close the connection
        session.peerConnection = null;
        session.peerConnectionThread = null;

        // Transition to IDLE state, which means stay in this state, in this
        // specific implementation
        return .{
            .Keep = {},
        };
    };
    session.connectionRetryTimer.cancel();

    // Seet connection data in the session
    session.peerConnection = peerConnection;
    const connContext: connections.ConnectionHandlerContext = .{ .peer = peer };
    session.peerConnectionThread = try std.Thread.spawn(.{}, connections.connectionHandler, .{connContext});

    if (peer.delayOpen) {
        try session.delayOpenTimer.start(peer.delayOpen_ms);
        return .{ .Transition = .CONNECT };
    }

    const openMsg: model.BgpMessage = .{ .OPEN = .{ .version = 4, .asNumber = peer.localAsn, .holdTime = peer.holdTime, .peerRouterId = 0, .parameters = null } };
    try session.messageEncoder.writeMessage(openMsg, peerConnection.writer().any());
    try session.holdTimer.start(4 * std.time.ms_per_min);
    return .{ .Transition = .OPEN_SENT };
}

pub fn handleEvent(peer: *Peer, event: Event) !PostHandlerAction {
    switch (event) {
        .Start => return try handleStart(peer),
        else => return .{ .Keep = {} },
    }
}
