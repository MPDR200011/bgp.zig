const std = @import("std");
const connections = @import("../connections.zig");
const sessionLib = @import("../session.zig");
const model = @import("../../messaging/model.zig");

const common = @import("common.zig");

const Session = sessionLib.Session;

const PostHandlerAction = sessionLib.PostHandlerAction;
const Event = sessionLib.Event;

pub fn handleStop(session: *Session) !PostHandlerAction {

    // TODO: If the DelayOpenTimer is running and the
    // SendNOTIFICATIONwithoutOPEN session attribute is set, the
    // local system sends a NOTIFICATION with a Cease,

    session.delayOpenTimer.cancel();
    session.closeConnection();
    session.connectionRetryCount = 0;
    session.connectionRetryTimer.cancel();

    return .transition(.IDLE);
}

fn handleRetryExpired(session: *Session) !PostHandlerAction {
    try session.connectionRetryTimer.reschedule();

    try session.startConnection();

    return .transition(.CONNECT);
}

fn handleDelayOpenExpired(session: *Session) !PostHandlerAction {
    session.connectionRetryTimer.cancel();
    session.delayOpenTimer.cancel();

    try session.sendMessage(.{ .OPEN = session.createOpenMessage(session.parent.holdTime) });
    try session.holdTimer.start(4 * std.time.ms_per_min);

    return .transition(.OPEN_SENT);
}

fn handleSuccessfulTcpConnection(session: *Session, connection: std.net.Stream) !PostHandlerAction {
    try session.setPeerConnection(connection);

    const peer = session.parent;

    session.connectionRetryTimer.cancel();

    if (peer.delayOpen) {
        try session.delayOpenTimer.start(peer.delayOpen_ms);
        return .keep;
    } else {
        try session.sendMessage(.{ .OPEN = session.createOpenMessage(session.parent.holdTime) });
        try session.holdTimer.start(4 * std.time.ms_per_min);

        return .transition(.OPEN_SENT);
    }
}

fn handleTcpFailed(session: *Session) !PostHandlerAction {
    try session.connectionRetryTimer.reschedule();
    session.delayOpenTimer.cancel();
    session.releaseResources();

    session.connectionRetryCount += 1;

    // TODO: peer oscillation

    return .transition(.IDLE);
}

fn handleOpenReceived(session: *Session, msg: model.OpenMessage) !PostHandlerAction {
    std.debug.assert(session.delayOpenTimer.isActive());
    session.delayOpenTimer.cancel();

    session.connectionRetryTimer.cancel();

    session.extractInfoFromOpenMessage(msg);

    const negotiatedHoldTimer = common.getNegotiatedHoldTimer(session, msg.holdTime);

    const peer = session.parent;
    try session.sendMessage(.{ .OPEN = session.createOpenMessage(peer.holdTime) });
    try session.sendMessage(.{ .KEEPALIVE = .{} });

    try session.holdTimer.start(negotiatedHoldTimer);
    try session.keepAliveTimer.start(negotiatedHoldTimer / 3);

    return .transition(.OPEN_CONFIRM);
}

pub fn handleNotification(session: *Session, notif: model.NotificationMessage) !PostHandlerAction {
    if (notif.errorKind != .UnsupportedVersionNumber) {
        return .keep;
    }

    session.connectionRetryTimer.cancel();

    if (session.delayOpenTimer.isActive()) {
        session.delayOpenTimer.cancel();

        session.releaseResources();
        session.closeConnection();

        return .transition(.IDLE);
    }

    session.releaseResources();
    session.closeConnection();
    session.connectionRetryCount += 1;

    // TODO peer oscillation dampening here

    return .transition(.IDLE);
}

pub fn handleOtherEvents(session: *Session) !PostHandlerAction {
    session.killAllTimers();

    session.closeConnection();
    session.connectionRetryCount += 1;

    // TODO: Peer Oscillation goes here, if ever

    return .transition(.IDLE);
}

pub fn handleEvent(session: *Session, event: Event) !PostHandlerAction {
    switch (event) {
        .Stop => return try handleStop(session),
        .ConnectionRetryTimerExpired => return try handleRetryExpired(session),
        .TcpConnectionSuccessful => |connection| return try handleSuccessfulTcpConnection(session, connection),
        .TcpConnectionFailed => return try handleTcpFailed(session),
        .DelayOpenTimerExpired => return try handleDelayOpenExpired(session),
        .OpenReceived => |openMsg| return try handleOpenReceived(session, openMsg),
        // Start events are ignored
        .Start => return .keep,
        // TODO handle message checking error events
        .NotificationReceived => |notif| return try handleNotification(session, notif),
        else => return try handleOtherEvents(session),
    }
}
