const std = @import("std");
const connections = @import("../connections.zig");
const sessionLib = @import("../session.zig");
const fsmLib = @import("../fsm.zig");
const model = @import("../../messaging/model.zig");

const Session = sessionLib.Session;
const Peer = sessionLib.Peer;

const PostHandlerAction = fsmLib.PostHandlerAction;
const Event = fsmLib.Event;

pub fn handleStop(peer: *Peer) !PostHandlerAction {
    const session = &peer.sessionInfo;
    session.mutex.lock();
    defer session.mutex.lock();

    // TODO: If the DelayOpenTimer is running and the
    // SendNOTIFICATIONwithoutOPEN session attribute is set, the
    // local system sends a NOTIFICATION with a Cease,

    session.delayOpenTimer.cancel();
    session.closeConnection();
    session.connectionRetryCount = 0;
    session.connectionRetryTimer.cancel();

    return .{
        .Transition = .IDLE,
    };
}

fn handleRetryExpired(peer: *Peer) !PostHandlerAction {
    const session = &peer.sessionInfo;
    session.mutex.lock();
    defer session.mutex.lock();

    session.connectionRetryTimer.reschedule();
    session.startConnection() catch |err| {
        std.log.err("Error attempting to start connection to peer: {}", .{err});

        if (session.delayOpenTimer.isActive()) {
            try session.connectionRetryTimer.reschedule();
            session.delayOpenTimer.cancel();

            return .transition(.ACTIVE);
        } else {
            session.connectionRetryTimer.cancel();
            session.closeConnection();

            return .transition(.IDLE);
        }
    };

    if (peer.delayOpen) {
        try session.delayOpenTimer.start(peer.delayOpen_ms);
        return .transition(.CONNECT);
    }

    const openMsg: model.BgpMessage = .{ .OPEN = .{ .version = 4, .asNumber = peer.localAsn, .holdTime = peer.holdTime, .peerRouterId = 0, .parameters = null } };

    std.debug.assert(session.peerConnection != null);
    try session.messageEncoder.writeMessage(openMsg, session.peerConnection.?.writer().any());

    try session.holdTimer.start(4 * std.time.ms_per_min);

    return .transition(.OPEN_SENT);
}

fn handleDelayOpenExpired(peer: *Peer) !PostHandlerAction {
    const session = &peer.sessionInfo;
    session.mutex.lock();
    defer session.mutex.lock();

    session.connectionRetryTimer.cancel();
    session.delayOpenTimer.cancel();

    const openMsg: model.BgpMessage = .{ .OPEN = .{ .version = 4, .asNumber = peer.localAsn, .holdTime = peer.holdTime, .peerRouterId = 0, .parameters = null } };
    try session.messageEncoder.writeMessage(openMsg, session.peerConnection.?.writer().any());
    try session.holdTimer.start(4 * std.time.ms_per_min);

    return .transition(.OPEN_SENT);
}

fn handleNewTcpConnection(peer: *Peer, connection: std.net.Stream) !PostHandlerAction {
    const session = &peer.sessionInfo;
    session.mutex.lock();
    defer session.mutex.lock();

    session.replacePeerConnection(connection);

    if (peer.delayOpen) {
        session.connectionRetryTimer.cancel();
        try session.delayOpenTimer.start(peer.delayOpen_ms);
        return .keep;

    } else {
        session.connectionRetryTimer.cancel();

        const openMsg: model.BgpMessage = .{ .OPEN = .{ .version = 4, .asNumber = peer.localAsn, .holdTime = peer.holdTime, .peerRouterId = 0, .parameters = null } };
        try session.messageEncoder.writeMessage(openMsg, session.peerConnection.?.writer().any());
        try session.holdTimer.start(4 * std.time.ms_per_min);

        return .transition(.OPEN_SENT);
    }
}

fn handleTcpFailed(peer: *Peer) !PostHandlerAction {
    const session = &peer.sessionInfo;
    session.mutex.lock();
    defer session.mutex.lock();

    try session.connectionRetryTimer.reschedule();
    session.delayOpenTimer.cancel();

    session.connectionRetryCount += 1;

    // TODO: peer oscillation

    return .transition(.IDLE);
}

fn handleOpenReceived(peer: *Peer, msg: model.OpenMessage) !PostHandlerAction {
    const session = &peer.sessionInfo;
    session.mutex.lock();
    defer session.mutex.lock();

    std.debug.assert(session.delayOpenTimer.isActive());

    session.connectionRetryTimer.cancel();
    session.delayOpenTimer.cancel();

    // TODO extract peer information from the message:
    // - router ID
    // - remote ASN
    // - holdTimer
    // - Internal/External connection
    // - etc.
    const peerHoldTimer = msg.holdTime;

    const negotiatedHoldTimer = @min(peer.holdTime, peerHoldTimer);

    const openResponse: model.BgpMessage = .{ .OPEN = .{ .version = 4, .asNumber = peer.localAsn, .holdTime = negotiatedHoldTimer, .peerRouterId = 0, .parameters = null } };
    try session.messageEncoder.writeMessage(openResponse, session.peerConnection.?.writer().any());

    const keepalive: model.BgpMessage = .{ .KEEPALIVE = .{} };
    try session.messageEncoder.writeMessage(keepalive, session.peerConnection.?.writer().any());

    try session.holdTimer.start(negotiatedHoldTimer);
    try session.keepAliveTimer.start(negotiatedHoldTimer / 3);

    return .transition(.OPEN_CONFIRM);
}

pub fn handleOtherEvents(peer: *Peer) !PostHandlerAction {
    const session = &peer.sessionInfo;
    session.mutex.lock();
    defer session.mutex.lock();

    session.killAllTimers();

    session.closeConnection();
    session.connectionRetryCount += 1;

    // TODO: Peer Oscillation goes here, if ever

    return .transition(.IDLE);
}

pub fn handleEvent(peer: *Peer, event: Event) !PostHandlerAction {
    switch (event) {
        .Stop => return try handleStop(peer),
        .ConnectionRetryTimerExpired => return try handleRetryExpired(peer),
        .TcpConnectionSuccessful => |connection| return try handleNewTcpConnection(peer, connection),
        .TcpConnectionFailed => return try handleTcpFailed(peer),
        .OpenReceived => |openMsg| return try handleOpenReceived(peer, openMsg),
        // Start events are ignored
        .Start => return .keep,
        // TODO handle message checking error events
        // TODO handle notification msg event
        else => return try handleOtherEvents(peer),
    }
}
