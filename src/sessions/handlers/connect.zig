const std = @import("std");
const connections = @import("../connections.zig");
const sessionLib = @import("../session.zig");
const model = @import("../../messaging/model.zig");

const common = @import("common.zig");

const Session = sessionLib.Session;

const PostHandlerAction = sessionLib.PostHandlerAction;
const Event = sessionLib.Event;

fn handleStop(session: *Session) !PostHandlerAction {
    session.closeConnection();
    session.connectionRetryCount = 0;
    session.connectionRetryTimer.cancel();

    return .transition(.IDLE);
}

fn handleRetryExpired(session: *Session) !PostHandlerAction {
    session.closeConnection();

    try session.connectionRetryTimer.reschedule();
    session.delayOpenTimer.cancel();

    try session.startConnection();

    return .keep;
}

fn handleDelayOpenExpired(session: *Session) !PostHandlerAction {
    try session.sendMessage(.{ .OPEN = session.createOpenMessage(session.parent.holdTime) });
    try session.holdTimer.start(4 * std.time.ms_per_min);

    return .transition(.OPEN_SENT);
}

fn handleTcpSuccessful(session: *Session) !PostHandlerAction {
    session.connectionRetryTimer.cancel();

    if (session.parent.delayOpen) {
        try session.delayOpenTimer.start(session.parent.delayOpen_ms);
        return .keep;
    }

    try session.sendMessage(.{ .OPEN = session.createOpenMessage(session.parent.holdTime) });
    try session.holdTimer.start(4 * std.time.ms_per_min);

    return .transition(.OPEN_SENT);
}

fn handleTcpFailed(session: *Session) !PostHandlerAction {
    if (session.delayOpenTimer.isActive()) {
        session.delayOpenTimer.cancel();
        try session.connectionRetryTimer.reschedule();

        return .transition(.ACTIVE);
    } else {
        session.connectionRetryTimer.cancel();

        session.closeConnection();

        return .transition(.IDLE);
    }
}

fn handleOpenReceived(session: *Session, msg: model.OpenMessage) !PostHandlerAction {
    std.debug.assert(session.delayOpenTimer.isActive());
    session.delayOpenTimer.cancel();

    session.connectionRetryTimer.cancel();

    try session.initBgpResourcesFromOpenMessage(msg);

    const negotiatedHoldTimer = common.getNegotiatedHoldTimer(session, msg.holdTime);

    const peer = session.parent;
    try session.sendMessage(.{ .OPEN = session.createOpenMessage(peer.holdTime) });
    try session.sendMessage(.{ .KEEPALIVE = .{} });

    try session.holdTimer.start(negotiatedHoldTimer);
    try session.keepAliveTimer.start(negotiatedHoldTimer / 3);

    return .transition(.OPEN_CONFIRM);
}

fn handleNotification(session: *Session, notif: model.NotificationMessage) !PostHandlerAction {
    if (notif.errorKind != .UnsupportedVersionNumber) {
        return .keep;
    }

    session.connectionRetryTimer.cancel();

    if (session.delayOpenTimer.isActive()) {
        session.delayOpenTimer.cancel();

        session.releaseBgpResources();
        session.closeConnection();

        return .transition(.IDLE);
    }

    session.releaseBgpResources();
    session.closeConnection();
    session.connectionRetryCount += 1;

    // TODO peer oscillation dampening here

    return .transition(.IDLE);
}

pub fn handleOtherEvents(session: *Session) !PostHandlerAction {
    session.shutdownFatal();

    // TODO: Peer Oscillation goes here, if ever

    return .transition(.IDLE);
}

pub fn handleEvent(session: *Session, event: Event) !PostHandlerAction {
    switch (event) {
        .Stop => return try handleStop(session),
        .ConnectionRetryTimerExpired => return try handleRetryExpired(session),
        .DelayOpenTimerExpired => return try handleDelayOpenExpired(session),
        .TcpConnectionFailed => return try handleTcpFailed(session),
        .TcpConnectionSuccessful => return try handleTcpSuccessful(session),
        .OpenReceived => |openMsg| return try handleOpenReceived(session, openMsg),
        // Start events are skipped
        .Start => return .keep,
        // TODO handle message checking error events
        .NotificationReceived => |notif| return try handleNotification(session, notif),
        else => return try handleOtherEvents(session),
    }
}
