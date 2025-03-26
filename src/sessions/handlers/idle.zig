const std = @import("std");
const connections = @import("../connections.zig");
const sessionLib = @import("../session.zig");
const model = @import("../../messaging/model.zig");

const Session = sessionLib.Session;

const PostHandlerAction = sessionLib.PostHandlerAction;
const Event = sessionLib.Event;

fn handleStart(session: *Session) !PostHandlerAction {
    session.connectionRetryCount = 0;
    try session.connectionRetryTimer.start(Session.CONNECTION_RETRY_TIMER_DEFAULT);

    if (session.parent.mode == .PASSIVE) {
        return .transition(.ACTIVE);
    }

    try session.startConnection();

    return .transition(.CONNECT);
}

pub fn handleEvent(session: *Session, event: Event) !PostHandlerAction {
    switch (event) {
        .Start => return try handleStart(session),
        else => return .{ .Keep = {} },
    }
}
