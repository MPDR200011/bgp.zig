const std = @import("std");
const sessionLib = @import("session.zig");
const messageModel = @import("../messaging/model.zig");
const idleHandler = @import("handlers/idle.zig");

const Session = sessionLib.Session;
const Peer = sessionLib.Peer;
const Mode = sessionLib.Mode;
const SessionState = sessionLib.SessionState;

const EventTag = enum(u8) {
    Start = 1,
    Stop = 2,
    OpenReceived = 3,
    ConnectionRetryTimerExpired = 4,
    HoldTimerExpired = 5,
    KeepAliveTimerExpired = 6,
    KeepAliveReceived = 7,
    DelayopenTimerExpired = 8,
};

pub const Event = union(EventTag) {
    Start: void,
    Stop: void,
    OpenReceived: messageModel.OpenMessage,
    ConnectionRetryTimerExpired: void,
    HoldTimerExpired: void,
    KeepAliveTimerExpired: void,
    KeepAliveReceived: void,
    DelayopenTimerExpired: void,
};

const PostHandlerActionTag = enum(u8) {
    Keep = 1,
    Transition = 2,
};

pub const PostHandlerAction = union(PostHandlerActionTag) {
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

pub const SessionFSM = struct {
    const Self = @This();

    mutex: std.Thread.Mutex,

    parent: *Peer,

    pub fn init(parent: *Peer) Self {
        return .{
            .mutex = .{},
            .parent = parent,
        };
    }

    fn switchState(self: *Self, nextState: SessionState) !void {
        self.parent.sessionInfo.mutex.lock();
        defer self.parent.sessionInfo.mutex.unlock();

        self.parent.sessionInfo.state = nextState;

        switch (nextState) {
            else => return,
        }
    }

    pub fn handleEvent(self: *Self, event: Event) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const nextAction: PostHandlerAction = switch (self.parent.sessionInfo.state) {
            .IDLE => try idleHandler.handleEvent(self.parent, event),
            else => .{ .Keep = {} },
        };

        switch (nextAction) {
            .Transition => |nextState| try self.switchState(nextState),
            .Keep => return,
        }
    }
};
