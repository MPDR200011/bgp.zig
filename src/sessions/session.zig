const std = @import("std");
const timer = @import("../utils/timer.zig");
const fsm = @import("fsm.zig");
const connections = @import("connections.zig");
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
    p.sessionFSM.handleEvent(.{ .DelayOpenTimerExpired = {} }) catch {
        std.log.err("Error event", .{});
    };
}

pub const Session = struct {
    const Self = @This();
    pub const CONNECTION_RETRY_TIMER_DEFAULT = 30 * std.time.ms_per_s;

    state: SessionState,
    parent: *Peer,

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
            .parent = parent,
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

    pub fn killAllTimers(self: *Self) void {
        self.connectionRetryTimer.cancel();
        self.holdTimer.cancel();
        self.keepAliveTimer.cancel();
        self.delayOpenTimer.cancel();
    }

    pub fn deinit(self: *Self) void {
        self.closeConnection();
    }

    pub fn replacePeerConnection(self: *Self, connection: std.net.Stream) !void {
        const currentPeerConnection = self.peerConnection;

        self.peerConnection = connection;
        currentPeerConnection.?.close();

        if (self.peerConnectionThread != null) {
            return;
        }

        const connContext: connections.ConnectionHandlerContext = .{ .peer = self.parent };
        self.peerConnectionThread = std.Thread.spawn(.{}, connections.connectionHandler, .{connContext}) catch |err| {
            self.peerConnection.?.close();
            self.peerConnectionThread.?.join();
            self.peerConnection = null;
            self.peerConnectionThread = null;

            return err;
        };
    }

    pub fn startConnection(self: *Self) !void {
        std.debug.assert(self.peerConnection == null);
        std.debug.assert(self.peerConnectionThread == null);

        // Start Connection Thread
        const peerAddress = std.net.Address.parseIp(self.parent.sessionAddresses.peerAddress, 179) catch unreachable;
        const peerConnection = try std.net.tcpConnectToAddress(peerAddress);

        // Seet connection data in the session
        self.peerConnection = peerConnection;
        const connContext: connections.ConnectionHandlerContext = .{ .peer = self.parent };
        self.peerConnectionThread = std.Thread.spawn(.{}, connections.connectionHandler, .{connContext}) catch |err| {
            self.peerConnection.?.close();
            self.peerConnectionThread.?.join();
            self.peerConnection = null;
            self.peerConnectionThread = null;

            return err;
        };
    }

    pub fn closeConnection(self: *Self) void {
        self.peerConnection.?.close();
        self.peerConnectionThread.?.join();
        self.peerConnection = null;
        self.peerConnectionThread = null;
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
