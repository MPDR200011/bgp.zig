const std = @import("std");
const connections = @import("../connections.zig");
const sessionLib = @import("../session.zig");
const model = @import("../../messaging/model.zig");

const Session = sessionLib.Session;
const Peer = sessionLib.Peer;

const PostHandlerAction = sessionLib.PostHandlerAction;
const Event = sessionLib.Event;

fn handleStop(peer: *Peer) !PostHandlerAction {
    const session = &peer.sessionInfo;

    session.closeConnection();
    session.connectionRetryCount = 0;
    session.connectionRetryTimer.cancel();

    return .{ .Transition = .IDLE };
}

fn handleRetryExpired(peer: *Peer) !PostHandlerAction {
    const session = &peer.sessionInfo;

    session.closeConnection();

    try session.connectionRetryTimer.reschedule();
    session.delayOpenTimer.cancel();

    // TODO: I assume there's going to be a "connection failed event to handle here"
    session.startConnection() catch |err| {
        std.log.err("Error attempting to start connection to peer: {}", .{err});

        // Cancel the retry timer
        session.connectionRetryTimer.cancel();

        return .{
            .Transition = .IDLE,
        };
    };

    session.connectionRetryTimer.cancel();

    if (peer.delayOpen) {
        try session.delayOpenTimer.start(peer.delayOpen_ms);

        return .{ .Keep = {} };
    }

    const openMsg: model.BgpMessage = .{ .OPEN = .{ .version = 4, .asNumber = peer.localAsn, .holdTime = peer.holdTime, .peerRouterId = 0, .parameters = null } };
    try session.messageEncoder.writeMessage(openMsg, session.peerConnection.?.writer().any());
    try session.holdTimer.start(4 * std.time.ms_per_min);

    return .{ .Transition = .OPEN_SENT };
}

fn handleDelayOpenExpired(peer: *Peer) !PostHandlerAction {
    const session = &peer.sessionInfo;

    const openMsg: model.BgpMessage = .{ .OPEN = .{ .version = 4, .asNumber = peer.localAsn, .holdTime = peer.holdTime, .peerRouterId = 0, .parameters = null } };
    try session.messageEncoder.writeMessage(openMsg, session.peerConnection.?.writer().any());
    try session.holdTimer.start(4 * std.time.ms_per_min);

    return .{ .Transition = .OPEN_SENT };
}

fn handleTcpFailed(peer: *Peer) !PostHandlerAction {
    const session = &peer.sessionInfo;

    if (session.delayOpenTimer.isActive()) {
        try session.connectionRetryTimer.reschedule();
        session.delayOpenTimer.cancel();

        return .{
            .Transition = .ACTIVE,
        };
    } else {
        session.connectionRetryTimer.cancel();

        session.closeConnection();

        return .{ .Transition = .IDLE };
    }
}

fn handleOpenReceived(peer: *Peer, msg: model.OpenMessage) !PostHandlerAction {
    const session = &peer.sessionInfo;

    std.debug.assert(session.delayOpenTimer.isActive());

    session.connectionRetryTimer.cancel();

    session.extractInfoFromOpenMessage(msg);
    const peerHoldTimer = msg.holdTime;

    const negotiatedHoldTimer = @min(peer.holdTime, peerHoldTimer);

    session.delayOpenTimer.cancel();

    const openResponse: model.BgpMessage = .{ .OPEN = .{ .version = 4, .asNumber = peer.localAsn, .holdTime = negotiatedHoldTimer, .peerRouterId = 0, .parameters = null } };
    try session.messageEncoder.writeMessage(openResponse, session.peerConnection.?.writer().any());

    const keepalive: model.BgpMessage = .{ .KEEPALIVE = .{} };
    try session.messageEncoder.writeMessage(keepalive, session.peerConnection.?.writer().any());

    try session.holdTimer.start(negotiatedHoldTimer);
    try session.keepAliveTimer.start(negotiatedHoldTimer / 3);

    return .{ .Transition = .OPEN_CONFIRM };
}

pub fn handleOtherEvents(peer: *Peer) !PostHandlerAction {
    const session = &peer.sessionInfo;

    session.connectionRetryTimer.cancel();
    session.delayOpenTimer.cancel();

    session.closeConnection();
    session.connectionRetryCount += 1;

    // TODO: Peer Oscillation goes here, if ever

    return .{ .Transition = .IDLE };
}

pub fn handleEvent(peer: *Peer, event: Event) !PostHandlerAction {
    switch (event) {
        .Stop => return try handleStop(peer),
        .ConnectionRetryTimerExpired => return try handleRetryExpired(peer),
        .DelayOpenTimerExpired => return try handleDelayOpenExpired(peer),
        .TcpConnectionFailed => return try handleTcpFailed(peer),
        .OpenReceived => |openMsg| return try handleOpenReceived(peer, openMsg),
        // Start events are skipped
        .Start => return .keep,
        // TODO handle message checking error events
        // TODO handle notification msg event
        else => return try handleOtherEvents(peer),
    }
}
