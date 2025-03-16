const std = @import("std");
const timer = @import("../utils/timer.zig");
const fsm = @import("fsm.zig");

const Timer = timer.Timer;

pub const SessionState = enum(u8) {
    IDLE = 1,
    CONNECT = 2,
    ACTIVE = 3,
    OPEN_SENT = 4,
    OPEN_CONFIRM = 5,
    ESTABLISHED = 6,
};

pub const Mode = enum(u8) {
    PASSIVE = 1,
    ACTIVE = 2,
};

fn sendConnectionRetryEvent(p: *Peer) void {
    p.sessionFSM.handleEvent(.{ .ConnectionRetryTimerExpired = {} }) catch {
        std.log.err("Error event", .{});
};
}

fn sendKeepAliveEvent(p: *Peer) void {
    p.sessionFSM.handleEvent(.{ .KeepAliveTimerExpired = {} }) catch {
        std.log.err("Error event", .{});
};
}

fn sendHoldTimerEvent(p: *Peer) void {
    p.sessionFSM.handleEvent(.{ .HoldTimerExpired = {} }) catch {
        std.log.err("Error event", .{});
};
}

pub const Session = struct {
    const Self = @This();
    pub const CONNECTION_RETRY_TIMER_DEFAULT = 30 * std.time.ms_per_s;

    state: SessionState,
    mode: Mode,

    mutex: std.Thread.Mutex,

    connectionRetryCount: u32 = 0,
    connectionRetryTimer: timer.Timer(*Peer),
    holdTimer: timer.Timer(*Peer),
    keepAliveTimer: timer.Timer(*Peer),

    pub fn init(mode: Mode, parent: *Peer) Self {
        return .{
            .state = .IDLE,
            .mode = mode,
            .mutex = .{},
            .connectionRetryTimer = .init(sendConnectionRetryEvent, parent),
            .holdTimer = .init(sendHoldTimerEvent, parent),
            .keepAliveTimer = .init(sendKeepAliveEvent, parent),
        };
    }
};

pub const PeerSessionAddresses = struct {
    localAddress: []const u8,
    peerAddress: []const u8,
};

pub const Peer = struct {
    const Self = @This();

    sessionAddresses: PeerSessionAddresses,
    sessionInfo: Session,
    sessionFSM: fsm.SessionFSM,
};
