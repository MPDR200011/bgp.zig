const std = @import("std");
const connections = @import("../connections.zig");
const sessionLib = @import("../session.zig");
const model = @import("../../messaging/model.zig");

const Session = sessionLib.Session;

const PostHandlerAction = sessionLib.PostHandlerAction;
const Event = sessionLib.Event;
const CollisionContext = sessionLib.CollisionContext;

fn handleStop(session: *Session) !PostHandlerAction {
    const msg: model.NotificationMessage = .initNoData(.Cease, .Default);
    try session.sendMessage(.{ .NOTIFICATION = msg });

    session.releaseResources();
    session.closeConnection();

    session.connectionRetryTimer.cancel();
    session.connectionRetryCount = 0;

    // TODO handle the automatic stop event

    return .transition(.IDLE);
}

fn handleHoldTimerExpires(session: *Session) !PostHandlerAction {
    const msg: model.NotificationMessage = .initNoData(.HoldTimerExpired, .Default);
    try session.sendMessage(.{ .NOTIFICATION = msg });

    session.releaseResources();
    session.closeConnection();

    session.connectionRetryTimer.cancel();
    session.connectionRetryCount += 1;

    // TODO peer oscillation here

    return .transition(.IDLE);
}

fn handleKeepAliveTimerExpires(session: *Session) !PostHandlerAction {
    std.log.debug("Sending KEEPALIVE", .{});

    try session.sendMessage(.{ .KEEPALIVE = .{} });

    try session.keepAliveTimer.reschedule();

    return .keep;
}

fn handleTcpFailed(session: *Session) !PostHandlerAction {
    session.connectionRetryTimer.cancel();

    session.releaseResources();
    session.closeConnection();

    session.connectionRetryCount += 1;

    return .transition(.IDLE);
}

fn handleConnectionCollision(session: *Session) !PostHandlerAction {
    const msg: model.NotificationMessage = .initNoData(.Cease, .Default);
    try session.sendMessage(.{ .NOTIFICATION = msg });

    session.connectionRetryTimer.cancel();
    session.releaseResources();

    session.connectionRetryCount += 1;

    // Peer Oscillation here

    return .transition(.IDLE);
}

fn handleKeepAliveReceived(session: *Session) !PostHandlerAction {
    std.log.debug("KEEPALIVE Received", .{});

    try session.holdTimer.reschedule();

    return .transition(.ESTABLISHED);
}

pub fn handleNotification(session: *Session, notif: model.NotificationMessage) !PostHandlerAction {
    if (notif.errorKind != .UnsupportedVersionNumber) {
        // TODO: I'm sure we should handle this differently
        return .keep;
    }

    session.connectionRetryTimer.cancel();

    session.releaseResources();
    session.closeConnection();

    // TODO peer oscillation dampening here

    return .transition(.IDLE);
}

fn handleOtherEvents(session: *Session) !PostHandlerAction {
    session.shutdownFatal();

    // TODO: Peer Oscillation goes here, if ever

    return .transition(.IDLE);
}

pub fn handleEvent(session: *Session, event: Event) !PostHandlerAction {
    switch (event) {
        .Stop => return try handleStop(session),
        .HoldTimerExpired => return try handleHoldTimerExpires(session),
        .KeepAliveTimerExpired => return try handleKeepAliveTimerExpires(session),
        .TcpConnectionFailed => return try handleTcpFailed(session),
        .OpenCollisionDump => return try handleConnectionCollision(session),
        .KeepAliveReceived => return try handleKeepAliveReceived(session),
        // Start events are ignored
        .Start => return .keep,
        // TODO handle message checking error events
        .NotificationReceived => |notif| return try handleNotification(session, notif),
        else => return try handleOtherEvents(session),
    }
}
