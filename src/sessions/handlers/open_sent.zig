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

    const msg: model.NotificationMessage = .{
        .errorKind = .Cease,
    };
    session.messageEncoder.writeMessage(.{.NOTIFICATION = msg}, session.peerConnection.?.writer().any());

    session.connectionRetryTimer.cancel();
    session.closeConnection();
    session.connectionRetryCount = 0;

    // TODO handle the automatic stop event

    return .{
        .Transition = .IDLE,
    };
}

pub fn handleHoldTimerExpires(peer: *Peer) !PostHandlerAction {
    const session = &peer.sessionInfo;
    session.mutex.lock();
    defer session.mutex.lock();

    const msg: model.NotificationMessage = .{
        .errorKind = .HoldTimerExpired,
    };
    session.messageEncoder.writeMessage(.{.NOTIFICATION = msg}, session.peerConnection.?.writer().any());

    session.connectionRetryTimer.cancel();
}

pub fn handleEvent(peer: *Peer, event: Event) !PostHandlerAction {
    switch (event) {
        .Stop => return try handleStop(peer),
        .HoldTimerExpired => return try handleHoldTimerExpires(peer),
        // Start events are ignored
        .Start => return .keep,
        // TODO handle message checking error events
        // TODO handle notification msg event
        else => return .keep, //try handleOtherEvents(peer),
    }
}
