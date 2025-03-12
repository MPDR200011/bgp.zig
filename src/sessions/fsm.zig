const std = @import("std");
const session_lib = @import("session.zig");
const messageModel = @import("../messaging/model.zig");
const Session = session_lib.Session;
const Mode = session_lib.Mode;
const SessionState = session_lib.SessionState;

const EventTag = enum(u8) {
    Start           = 1,
    Stop            = 2,
    OpenReceived    = 3,
};

pub const Event = union(EventTag) {
    Start: void,
    Stop: void,
    OpenReceived: messageModel.OpenMessage,
};

const PostHandlerActionTag = enum(u8) {
    Keep        = 1,
    Transition  = 2,
};

const PostHandlerAction = union(PostHandlerActionTag) {
    Keep: void,
    Transition: SessionState,
};

// Event handler interface
const EventHandler = struct {
  ptr: *anyopaque,
  handleFunc: *const fn (ptr: *anyopaque, event: Event) anyerror!PostHandlerAction,

  const Self = @This();

  fn init(ptr: anytype) Self {
    const T = @TypeOf(ptr);
    const ptr_info = @typeInfo(T);

    const gen = struct {
      pub fn handleEvent(pointer: *anyopaque, event: Event) anyerror!PostHandlerAction {
        const self: T = @ptrCast(@alignCast(pointer));
        return ptr_info.Pointer.child.handleEvent(self, event);
      }
    };

    return .{
      .ptr = ptr,
      .handleFunc = gen.handleEvent,
    };
  }

  pub fn handleEvent(self: Self, event: Event) !PostHandlerAction {
    return self.handleFunc(self.ptr, event);
  }
};

const IdleStateEventHandler = struct {
    fn handleStart(session: *Session) !PostHandlerAction {
        session.mutex.lock();
        defer session.mutex.unlock();

        if (session.mode == .PASSIVE) {
            // TODO: Setup resources:
            //   - Open socket
            //   - Set Connection retry timer
            session.connectionRetryCount = 0;
            return .{
                .Transition = .ACTIVE,
            };
        }

        // Start Connection Thread

        return .{
            .Transition = .CONNECT
        };
    }

    fn handleEvent(session: *Session, event: Event) !PostHandlerAction {
        switch (event) {
            .Start => return try handleStart(session),
            else => return .{ .KEEP },
        }
    }
};

pub const SessionFSM = struct {
    const Self = @This();

    mutex: std.Thread.Mutex,

    session: *Session,

    pub fn init(session: *Session) Self {
        return .{
            .mutex = .{},
            .session = session,
        };
    }

    fn switchState(self: *Self, nextState: SessionState) !void {
        self.session.mutex.lock();
        defer self.session.mutex.unlock();

        self.session.state = nextState;

        switch (nextState) {
            else => return,
        }
    }

    pub fn handleEvent(self: *Self, event: Event) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const nextAction: PostHandlerAction = switch (self.session.state) {
            .IDLE => try IdleStateEventHandler.handleEvent(self.session, event),
            else => .{.Keep}
        };

        switch (nextAction) {
            .Transition => |nextState| try self.switchState(nextState),
            .Keep => return,
        }
    }
};
