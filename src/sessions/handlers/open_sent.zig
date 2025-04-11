const std = @import("std");
const connections = @import("../connections.zig");
const sessionLib = @import("../session.zig");
const model = @import("../../messaging/model.zig");

const common = @import("common.zig");

const Session = sessionLib.Session;

const PostHandlerAction = sessionLib.PostHandlerAction;
const Event = sessionLib.Event;
const CollisionContext = sessionLib.CollisionContext;

pub fn handleStop(session: *Session) !PostHandlerAction {
    const msg: model.NotificationMessage = .initNoData(.Cease, .Default);
    try session.sendMessage(.{ .NOTIFICATION = msg });

    session.connectionRetryTimer.cancel();
    session.releaseResources();
    session.closeConnection();
    session.connectionRetryCount = 0;

    // TODO handle the automatic stop event

    return .{
        .Transition = .IDLE,
    };
}

pub fn handleHoldTimerExpires(session: *Session) !PostHandlerAction {
    const msg: model.NotificationMessage = .initNoData(.HoldTimerExpired, .Default);
    try session.sendMessage(.{ .NOTIFICATION = msg });

    session.connectionRetryTimer.cancel();
    session.releaseResources();
    session.closeConnection();
    session.connectionRetryCount += 1;

    return .transition(.IDLE);
}

fn handleTcpFailed(session: *Session) !PostHandlerAction {
    session.closeConnection();

    try session.connectionRetryTimer.reschedule();

    return .transition(.ACTIVE);
}

fn handleOpenReceived(session: *Session, msg: model.OpenMessage) !PostHandlerAction {
    session.connectionRetryTimer.cancel();
    session.delayOpenTimer.cancel();

    session.extractInfoFromOpenMessage(msg);

    const negotiatedHoldTimer = common.getNegotiatedHoldTimer(session, msg.holdTime);

    const keepalive: model.BgpMessage = .{ .KEEPALIVE = .{} };
    try session.sendMessage(keepalive);

    session.holdTimer.cancel();
    try session.holdTimer.start(negotiatedHoldTimer);
    try session.keepAliveTimer.start(negotiatedHoldTimer / 3);

    return .transition(.OPEN_CONFIRM);
}

fn handleConnectionCollision(session: *Session) !PostHandlerAction {
    const msg: model.NotificationMessage = .initNoData(.Cease, .Default);
    try session.sendMessage(.{ .NOTIFICATION = msg });

    session.connectionRetryTimer.cancel();
    session.releaseResources();
    session.closeConnection();

    session.connectionRetryCount += 1;

    // TODO oscillation damping

    return .transition(.IDLE);
}

pub fn handleNotification(session: *Session, notif: model.NotificationMessage) !PostHandlerAction {
    if (notif.errorKind != .UnsupportedVersionNumber) {
        return .keep;
    }

    session.connectionRetryTimer.cancel();

    session.releaseResources();
    session.closeConnection();
    session.connectionRetryCount += 1;

    // TODO peer oscillation dampening here

    return .transition(.IDLE);
}

pub fn handleOtherEvents(session: *Session) !PostHandlerAction {
    const msg: model.NotificationMessage = .initNoData(.FSMError, .Default);
    try session.messageEncoder.writeMessage(.{ .NOTIFICATION = msg }, session.peerConnection.?.writer().any());

    session.killAllTimers();
    session.closeConnection();
    session.connectionRetryCount += 1;

    // TODO: Peer Oscillation goes here, if ever

    return .transition(.IDLE);
}

pub fn handleEvent(session: *Session, event: Event) !PostHandlerAction {
    switch (event) {
        .Stop => return try handleStop(session),
        .HoldTimerExpired => return try handleHoldTimerExpires(session),
        .TcpConnectionFailed => return try handleTcpFailed(session),
        .OpenReceived => |openMsg| return try handleOpenReceived(session, openMsg),
        .OpenCollisionDump => return try handleConnectionCollision(session),
        // Start events are ignored
        .Start => return .keep,
        // TODO handle message checking error events
        .NotificationReceived => |notif| return try handleNotification(session, notif),
        else => return try handleOtherEvents(session),
    }
}
