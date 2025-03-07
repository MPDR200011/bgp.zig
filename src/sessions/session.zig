const std = @import("std");

pub const SessionState = enum(u8) {
    IDLE            = 1,
    CONNECT         = 2,
    ACTIVE          = 3,
    OPEN_SENT       = 4,
    OPEN_CONFIRM    = 5,
    ESTABLISHED     = 6,
};

pub const Mode = enum(u8) {
    PASSIVE     = 1,
    ACTIVE      = 2,
};

pub const Session = struct {
    const Self = @This();

    state: SessionState,
    mode: Mode,

    mutex: std.Thread.Mutex,

    connectionRetryCount: u32 = 0,
    connectionRetryTimer: void,
    holdTimer: void,
    keepAliveTimer: void,

    pub fn init(mode: Mode) Self {
        return .{
            .state = .IDLE,
            .mode = mode,
            .mutex = .{},
        };
    }

};

