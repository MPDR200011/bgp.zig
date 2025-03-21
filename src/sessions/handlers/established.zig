const std = @import("std");
const connections = @import("../connections.zig");
const sessionLib = @import("../session.zig");
const fsmLib = @import("../fsm.zig");
const model = @import("../../messaging/model.zig");

const Session = sessionLib.Session;
const Peer = sessionLib.Peer;

const PostHandlerAction = fsmLib.PostHandlerAction;
const Event = fsmLib.Event;
const CollisionContext = fsmLib.CollisionContext;

fn handleStop(peer: *Peer) !PostHandlerAction {
    const session = &peer.sessionInfo;
    session.mutex.lock();
    defer session.mutex.lock();

    const msg: model.NotificationMessage = .initNoData(.Cease, .Default);
    try session.messageEncoder.writeMessage(.{.NOTIFICATION = msg}, session.peerConnection.?.writer().any());

    session.connectionRetryTimer.cancel();

    // TODO: delete all routes

    session.closeConnection();
    session.connectionRetryCount = 0;

    // TODO handle the automatic stop event

    return .{
        .Transition = .IDLE,
    };
}

fn handleHoldTimerExpires(peer: *Peer) !PostHandlerAction {
    const session = &peer.sessionInfo;
    session.mutex.lock();
    defer session.mutex.lock();

    const msg: model.NotificationMessage = .initNoData(.HoldTimerExpired, .Default);
    try session.messageEncoder.writeMessage(.{.NOTIFICATION = msg}, session.peerConnection.?.writer().any());

    session.connectionRetryTimer.cancel();
    session.closeConnection();
    session.connectionRetryCount += 1;

    // TODO peer oscillation here

    return .transition(.IDLE);
}

fn handleKeepAliveTimerExpires(peer: *Peer) !PostHandlerAction {
    const session = &peer.sessionInfo;
    session.mutex.lock();
    defer session.mutex.lock();

    try session.messageEncoder.writeMessage(.{.KEEPALIVE = .{}}, session.peerConnection.?.writer().any());

    // TODO if hold time is 0, don't do this
    try session.keepAliveTimer.reschedule();

    return .keep;
}

fn handleTcpFailed(peer: *Peer) !PostHandlerAction {
    const session = &peer.sessionInfo;
    session.mutex.lock();
    defer session.mutex.lock();

    session.connectionRetryTimer.cancel();
    session.closeConnection();
    session.connectionRetryCount += 1;

    return .transition(.IDLE);
}

fn handleConnectionCollision(peer: *Peer, ctx: CollisionContext) !PostHandlerAction {
    // Very different from what the RFC prescribes
    // In the RFC, a new FSM should be started for the colliding Open message comming in.
    // However I'm choosing to just reuse the current FSM, replacing the TCP stream
    // used by the session, and handling the OPEN message as if I was in the connect state.

    const session = &peer.sessionInfo;
    session.mutex.lock();
    defer session.mutex.lock();

    const msg: model.NotificationMessage = .initNoData(.Cease, .Default);
    try session.messageEncoder.writeMessage(.{.NOTIFICATION = msg}, session.peerConnection.?.writer().any());

    try session.replacePeerConnection(ctx.newConnection);

    session.connectionRetryTimer.cancel();
    session.delayOpenTimer.cancel();

    // TODO extract peer information from the message:
    // - router ID
    // - remote ASN
    // - holdTimer
    // - Internal/External connection
    // - etc.
    const peerHoldTimer = ctx.openMsg.holdTime;

    const negotiatedHoldTimer = @min(peer.holdTime, peerHoldTimer);

    const openResponse: model.BgpMessage = .{ .OPEN = .{ .version = 4, .asNumber = peer.localAsn, .holdTime = negotiatedHoldTimer, .peerRouterId = 0, .parameters = null } };
    try session.messageEncoder.writeMessage(openResponse, session.peerConnection.?.writer().any());

    const keepalive: model.BgpMessage = .{ .KEEPALIVE = .{} };
    try session.messageEncoder.writeMessage(keepalive, session.peerConnection.?.writer().any());

    try session.holdTimer.start(negotiatedHoldTimer);
    try session.keepAliveTimer.start(negotiatedHoldTimer / 3);

    return .keep;
}

fn handleKeepAliveReceived(peer: *Peer) !PostHandlerAction {
    const session = &peer.sessionInfo;
    session.mutex.lock();
    defer session.mutex.lock();

    try session.holdTimer.reschedule();

    return .keep;
}

fn handleUpdateReceived(peer: *Peer, msg: model.UpdateMessage) !PostHandlerAction {
    const session = &peer.sessionInfo;
    session.mutex.lock();
    defer session.mutex.lock();

    _ = msg;

    try session.holdTimer.reschedule();

    return .keep;
}

fn handleOtherEvents(peer: *Peer) !PostHandlerAction {
    const session = &peer.sessionInfo;
    session.mutex.lock();
    defer session.mutex.lock();

    const msg: model.NotificationMessage = .initNoData(.FSMError, .Default);
    try session.messageEncoder.writeMessage(.{.NOTIFICATION = msg}, session.peerConnection.?.writer().any());

    session.killAllTimers();
    session.closeConnection();
    session.connectionRetryCount += 1;

    // TODO: Peer Oscillation goes here, if ever

    return .transition(.IDLE);
}


pub fn handleEvent(peer: *Peer, event: Event) !PostHandlerAction {
    switch (event) {
        .Stop => return try handleStop(peer),
        .HoldTimerExpired => return try handleHoldTimerExpires(peer),
        .KeepAliveTimerExpired => return try handleKeepAliveTimerExpires(peer),
        .TcpConnectionFailed => return try handleTcpFailed(peer),
        .KeepAliveReceived => return try handleKeepAliveReceived(peer),
        .UpdateReceived => |msg| return try handleUpdateReceived(peer, msg),
        // TODO: in case I want, implement collision handling for this state,
        // It is not required though

        // Start events are ignored
        .Start => return .keep,
        // TODO handle message checking error events
        // TODO handle notification msg event
        else => return try handleOtherEvents(peer),
    }
}
