const std = @import("std");
const timer = @import("../utils/timer.zig");
const fsm = @import("fsm.zig");
const model = @import("../messaging/model.zig");
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
    p.lock();
    defer p.unlock();
    p.sessionFSM.handleEvent(.{ .ConnectionRetryTimerExpired = {} }) catch {
        std.log.err("Error event", .{});
    };
}

fn sendKeepAliveEvent(p: *Peer) void {
    p.lock();
    defer p.unlock();
    p.sessionFSM.handleEvent(.{ .KeepAliveTimerExpired = {} }) catch {
        std.log.err("Error event", .{});
    };
}

fn sendHoldTimerEvent(p: *Peer) void {
    p.lock();
    defer p.unlock();
    p.sessionFSM.handleEvent(.{ .HoldTimerExpired = {} }) catch {
        std.log.err("Error event", .{});
    };
}

fn sendDelayOpenEvent(p: *Peer) void {
    p.lock();
    defer p.unlock();
    p.sessionFSM.handleEvent(.{ .DelayOpenTimerExpired = {} }) catch {
        std.log.err("Error event", .{});
    };
}

pub const ConnectionState = enum(u8) {
    Open = 1,
    Closing = 2,
};

pub const Session = struct {

    const Info = struct {
        peerId: u32,
        peerAsn: u16,
    };

    const Self = @This();
    pub const CONNECTION_RETRY_TIMER_DEFAULT = 30 * std.time.ms_per_s;

    state: SessionState,
    parent: *Peer,
    info: ?Info,

    mutex: std.Thread.Mutex,

    connectionRetryCount: u32 = 0,
    connectionRetryTimer: timer.Timer(*Peer),
    holdTimer: timer.Timer(*Peer),
    keepAliveTimer: timer.Timer(*Peer),
    delayOpenTimer: timer.Timer(*Peer),

    connectionState: ConnectionState,
    peerConnection: ?std.net.Stream,
    peerConnectionThread: ?std.Thread,

    messageEncoder: encoder.MessageEncoder,

    allocator: std.mem.Allocator,

    pub fn init(parent: *Peer, alloc: std.mem.Allocator) Self {
        return .{
            .state = .IDLE,
            .parent = parent,
            .info = null,
            .mutex = .{},
            .connectionRetryTimer = .init(sendConnectionRetryEvent, parent),
            .holdTimer = .init(sendHoldTimerEvent, parent),
            .keepAliveTimer = .init(sendKeepAliveEvent, parent),
            .delayOpenTimer = .init(sendDelayOpenEvent, parent),
            .connectionState = .Closing,
            .peerConnection = null,
            .peerConnectionThread = null,
            .messageEncoder = .init(alloc),
            .allocator = alloc,
        };
    }

    pub fn extractInfoFromOpenMessage(self: *Self, msg: model.OpenMessage) void {
        self.info = .{
            .peerId = msg.peerRouterId,
            .peerAsn = msg.asNumber,
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

        self.messageEncoder.deinit();

        self.connectionRetryTimer.deinit();
        self.holdTimer.deinit();
        self.keepAliveTimer.deinit();
        self.delayOpenTimer.deinit();
    }

    pub fn replacePeerConnection(self: *Self, connection: std.net.Stream) !void {
        self.connectionState = .Closing;
        self.peerConnection.?.close();
        self.peerConnectionThread.?.join();

        self.connectionState = .Open;

        self.peerConnection = connection;
        const connContext: connections.ConnectionHandlerContext = .{ .peer = self.parent, .allocator = self.allocator };
        self.peerConnectionThread = std.Thread.spawn(.{}, connections.connectionHandler, .{connContext}) catch |err| {
            self.peerConnection.?.close();
            self.peerConnectionThread.?.join();
            self.peerConnection = null;
            self.peerConnectionThread = null;

            self.connectionState = .Closing;
            return err;
        };
    }

    pub fn startConnection(self: *Self) !void {
        std.debug.assert(self.peerConnection == null);
        std.debug.assert(self.peerConnectionThread == null);

        self.connectionState = .Open;

        const peerAddress = std.net.Address.parseIp(self.parent.sessionAddresses.peerAddress, 179) catch unreachable;
        const peerConnection = try std.net.tcpConnectToAddress(peerAddress);

        self.peerConnection = peerConnection;
        const connContext: connections.ConnectionHandlerContext = .{ .peer = self.parent, .allocator = self.allocator };
        self.peerConnectionThread = std.Thread.spawn(.{}, connections.connectionHandler, .{connContext}) catch |err| {
            self.peerConnection.?.close();
            self.peerConnectionThread.?.join();
            self.peerConnection = null;
            self.peerConnectionThread = null;

            self.connectionState = .Closing;

            return err;
        };
    }

    pub fn closeConnection(self: *Self) void {
        self.connectionState = .Closing;

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

    mutex: std.Thread.Mutex,

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
            .mutex = .{},
        };
    }

    pub fn lock(self: *Self) void {
        self.mutex.lock();
    }

    pub fn unlock(self: *Self) void {
        self.mutex.unlock();
    }
};
