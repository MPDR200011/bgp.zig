const sessionLib = @import("../session.zig");
const fsmLib = @import("../fsm.zig");

const Session = sessionLib.Session;

const PostHandlerAction = fsmLib.PostHandlerAction;
const Event = fsmLib.Event;

fn handleStart(session: *Session) !PostHandlerAction {
    session.mutex.lock();
    defer session.mutex.unlock();

    if (session.mode == .PASSIVE) {
        // TODO: Setup resources:
        //   - Open socket
        //   - Set Connection retry timer
        session.connectionRetryCount = 0;
        try session.connectionRetryTimer.start(Session.CONNECTION_RETRY_TIMER_DEFAULT);

        return .{
            .Transition = .ACTIVE,
        };
    } 

    // Start Connection Thread

    return .{ .Transition = .CONNECT };
}

pub fn handleEvent(session: *Session, event: Event) !PostHandlerAction {
    switch (event) {
        .Start => return try handleStart(session),
        else => return .{ .Keep = {} },
    }
}

