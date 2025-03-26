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
    try session.sendMessage(.{.NOTIFICATION = msg});

    session.connectionRetryTimer.cancel();

    // TODO: delete all routes

    session.releaseResources();
    session.closeConnection();
    session.connectionRetryCount = 0;

    // TODO handle the automatic stop event

    return .{
        .Transition = .IDLE,
    };
}

fn handleHoldTimerExpires(session: *Session) !PostHandlerAction {
    const msg: model.NotificationMessage = .initNoData(.HoldTimerExpired, .Default);
    try session.sendMessage(.{.NOTIFICATION = msg});

    session.connectionRetryTimer.cancel();
    session.releaseResources();
    session.closeConnection();
    session.connectionRetryCount += 1;

    // TODO peer oscillation here

    return .transition(.IDLE);
}

fn handleKeepAliveTimerExpires(session: *Session) !PostHandlerAction {
    try session.sendMessage(.{.KEEPALIVE = .{}});

    // TODO if hold time is 0, don't do this
    try session.keepAliveTimer.reschedule();

    return .keep;
}

fn handleTcpFailed(session: *Session) !PostHandlerAction {
    session.connectionRetryTimer.cancel();

    // TODO delete all routes

    session.releaseResources();
    session.closeConnection();
    session.connectionRetryCount += 1;

    return .transition(.IDLE);
}

fn handleConnectionCollision(session: *Session) !PostHandlerAction {
    const msg: model.NotificationMessage = .initNoData(.Cease, .Default);
    try session.sendMessage(.{.NOTIFICATION = msg});

    session.connectionRetryTimer.cancel();

    // TODO delete all routes

    session.releaseResources();
    session.closeConnection();

    session.connectionRetryCount += 1;

    // TODO oscillation damping

    return .transition(.IDLE);
}

fn handleKeepAliveReceived(session: *Session) !PostHandlerAction {
    try session.holdTimer.reschedule();

    return .keep;
}

fn handleUpdateReceived(session: *Session, msg: model.UpdateMessage) !PostHandlerAction {
    _ = msg;

    try session.holdTimer.reschedule();

    return .keep;
}

fn handleOtherEvents(session: *Session) !PostHandlerAction {
    const msg: model.NotificationMessage = .initNoData(.FSMError, .Default);
    try session.messageEncoder.writeMessage(.{.NOTIFICATION = msg}, session.peerConnection.?.writer().any());

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
        .KeepAliveTimerExpired => return try handleKeepAliveTimerExpires(session),
        .TcpConnectionFailed => return try handleTcpFailed(session),
        .KeepAliveReceived => return try handleKeepAliveReceived(session),
        .UpdateReceived => |msg| return try handleUpdateReceived(session, msg),
        // TODO: in case I want, implement collision handling for this state,
        // It is not required though

        // Start events are ignored
        .Start => return .keep,
        // TODO handle message checking error events
        .NotificationReceived => return try handleTcpFailed(session),
        else => return try handleOtherEvents(session),
    }
}
