const std = @import("std");
const timer = @import("../utils/timer.zig");
const fsm = @import("fsm.zig");
const encoder = @import("../messaging/encoding/encoder.zig");

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

fn sendDelayOpenEvent(p: *Peer) void {
    p.sessionFSM.handleEvent(.{ .DelayopenTimerExpired = {} }) catch {
        std.log.err("Error event", .{});
    };
}

pub const Session = struct {
    const Self = @This();
    pub const CONNECTION_RETRY_TIMER_DEFAULT = 30 * std.time.ms_per_s;

    state: SessionState,

    mutex: std.Thread.Mutex,

    connectionRetryCount: u32 = 0,
    connectionRetryTimer: timer.Timer(*Peer),
    holdTimer: timer.Timer(*Peer),
    keepAliveTimer: timer.Timer(*Peer),
    delayOpenTimer: timer.Timer(*Peer),

    peerConnection: ?std.net.Stream,
    peerConnectionThread: ?std.Thread,

    messageEncoder: encoder.MessageEncoder,

    pub fn init(parent: *Peer, alloc: std.mem.Allocator) Self {
        return .{
            .state = .IDLE,
            .mutex = .{},
            .connectionRetryTimer = .init(sendConnectionRetryEvent, parent),
            .holdTimer = .init(sendHoldTimerEvent, parent),
            .keepAliveTimer = .init(sendKeepAliveEvent, parent),
            .delayOpenTimer = .init(sendDelayOpenEvent, parent),
            .peerConnection = null,
            .peerConnectionThread = null,
            .messageEncoder = .init(alloc),
        };
    }

    pub fn deinit(self: *Self) void {
        self.peerConnection.?.stream.close();
        self.peerConnectionThread.?.join();
    }
};

pub const PeerSessionAddresses = struct {
    localAddress: []const u8,
    peerAddress: []const u8,
};

pub const PeerConfig = struct {
    localAsn: u16,
    holdTime: u16,
    localRouterId: u32,
    mode: Mode,
    delayOpen: bool,
    delayOpen_ms: u32 = 0,

    sessionAddresses: PeerSessionAddresses,
};
pub const Peer = struct {
    const Self = @This();

    localAsn: u16,
    holdTime: u16,
    localRouterId: u32,
    mode: Mode,
    delayOpen: bool,
    delayOpen_ms: u32 = 0,

    sessionAddresses: PeerSessionAddresses,
    sessionInfo: Session,
    sessionFSM: fsm.SessionFSM,

    pub fn init(cfg: PeerConfig, self: *Self, alloc: std.mem.Allocator) Self {
        return .{
            .localAsn = cfg.localAsn,
            .holdTime = cfg.holdTime,
            .localRouterId = cfg.localRouterId,
            .mode = cfg.mode,
            .delayOpen = cfg.delayOpen,
            .delayOpen_ms = cfg.delayOpen_ms,
            .sessionAddresses = cfg.sessionAddresses,
            .sessionInfo = .init(self, alloc),
            .sessionFSM = .init(self),
        };
    }
};
