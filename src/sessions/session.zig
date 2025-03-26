const std = @import("std");
const timer = @import("../utils/timer.zig");

const connections = @import("connections.zig");
const encoder = @import("../messaging/encoding/encoder.zig");
const messageModel = @import("../messaging/model.zig");
const idleHandler = @import("handlers/idle.zig");
const connectHandler = @import("handlers/connect.zig");
const activeHandler = @import("handlers/active.zig");
const openSentHandler = @import("handlers/open_sent.zig");
const openConfirmHandler = @import("handlers/open_confirm.zig");
const establishedHandler = @import("handlers/established.zig");


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

const EventTag = enum(u8) {
    Start = 1,
    Stop = 2,
    OpenReceived = 3,
    ConnectionRetryTimerExpired = 4,
    HoldTimerExpired = 5,
    KeepAliveTimerExpired = 6,
    KeepAliveReceived = 7,
    DelayOpenTimerExpired = 8,
    TcpConnectionFailed = 9,
    TcpConnectionSuccessful = 10,
    OpenCollisionDump = 11,
    UpdateReceived = 12,
    NotificationReceived = 13,
};

pub const CollisionContext = struct {
    newConnection: std.net.Stream,
    openMsg: messageModel.OpenMessage
};

pub const Event = union(EventTag) {
    Start: void,
    Stop: void,
    OpenReceived: messageModel.OpenMessage,
    ConnectionRetryTimerExpired: void,
    HoldTimerExpired: void,
    KeepAliveTimerExpired: void,
    KeepAliveReceived: void,
    DelayOpenTimerExpired: void,
    TcpConnectionFailed: void,
    TcpConnectionSuccessful: std.net.Stream,
    OpenCollisionDump: CollisionContext,
    UpdateReceived: messageModel.UpdateMessage,
    NotificationReceived: messageModel.NotificationMessage,
};

const PostHandlerActionTag = enum(u8) {
    Keep = 1,
    Transition = 2,
};

pub const PostHandlerAction = union(PostHandlerActionTag) {
    Keep: void,
    Transition: SessionState,

    pub const keep: PostHandlerAction = .{ .Keep = {} };

    pub fn transition(state: SessionState) PostHandlerAction {
        return .{
            .Transition = state,
        };
    }
};


fn sendConnectionRetryEvent(p: *Peer) void {
    p.lock();
    defer p.unlock();
    p.session.handleEvent(.{ .ConnectionRetryTimerExpired = {} }) catch {
        std.log.err("Error event", .{});
    };
}

fn sendKeepAliveEvent(p: *Peer) void {
    p.lock();
    defer p.unlock();
    p.session.handleEvent(.{ .KeepAliveTimerExpired = {} }) catch {
        std.log.err("Error event", .{});
    };
}

fn sendHoldTimerEvent(p: *Peer) void {
    p.lock();
    defer p.unlock();
    p.session.handleEvent(.{ .HoldTimerExpired = {} }) catch {
        std.log.err("Error event", .{});
    };
}

fn sendDelayOpenEvent(p: *Peer) void {
    p.lock();
    defer p.unlock();
    p.session.handleEvent(.{ .DelayOpenTimerExpired = {} }) catch {
        std.log.err("Error event", .{});
    };
}

pub const ConnectionState = enum(u8) {
    Open = 1,
    Closing = 2,
};

const StartConnContext = struct {
    session: *Session,
    allocator: std.mem.Allocator
};

fn connectionStartThread(ctx: StartConnContext) !void {
    std.debug.assert(ctx.session.peerConnection == null);
    std.debug.assert(ctx.session.peerConnectionThread == null);

    const peerAddress = std.net.Address.parseIp(ctx.session.parent.sessionAddresses.peerAddress, 179) catch unreachable;
    const peerConnection = std.net.tcpConnectToAddress(peerAddress) catch |err| {
        std.log.err("Failed to establish TCP connection with peer: {}", .{err});

        ctx.session.connectionState = .Closing;

        ctx.session.peerConnection.?.close();
        ctx.session.peerConnectionThread.?.join();
        ctx.session.peerConnectionThread = null;
        ctx.session.peerConnection = null;

        try ctx.session.handleEvent(.{ .TcpConnectionFailed = {} });

        return err;
    };

    ctx.session.connectionState = .Open;

    ctx.session.peerConnection = peerConnection;
    const connContext: connections.ConnectionHandlerContext = .{ .session = ctx.session, .allocator = ctx.allocator };
    ctx.session.peerConnectionThread = std.Thread.spawn(.{}, connections.connectionHandler, .{connContext}) catch |err| {
        std.log.err("Failed to start connection connection thread: {}", .{err});

        ctx.session.connectionState = .Closing;

        ctx.session.peerConnection.?.close();
        ctx.session.peerConnectionThread.?.join();
        ctx.session.peerConnectionThread = null;
        ctx.session.peerConnection = null;

        try ctx.session.handleEvent(.{ .TcpConnectionFailed = {} });

        return err;
    };

    try ctx.session.handleEvent(.{ .TcpConnectionSuccessful = ctx.session.peerConnection orelse unreachable });
}

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

    connectionStartThread: ?std.Thread,

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
            .connectionStartThread = null,
            .messageEncoder = .init(alloc),
            .allocator = alloc,
        };
    }

    pub fn releaseResources(self: *Self) void {
        self.info = null;

        // TODO might want to release Adj Ribs in this spot?
    }

    pub fn createOpenMessage(self: *Self, holdTimerValue: u16) messageModel.OpenMessage {
        return .{ .version = 4, .asNumber = self.parent.localAsn, .holdTime = holdTimerValue, .peerRouterId = self.parent.localRouterId, .parameters = null };
    }

    pub fn sendMessage(self: *Self, msg: messageModel.BgpMessage) !void {
        std.debug.assert(self.peerConnection != null);
        const connection = self.peerConnection orelse unreachable;

        try self.messageEncoder.writeMessage(msg, connection.writer().any());

        if (msg == .UPDATE) {
            try self.keepAliveTimer.reschedule();
        }
    }

    pub fn extractInfoFromOpenMessage(self: *Self, msg: messageModel.OpenMessage) void {
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
        self.releaseResources();
        self.closeConnection();

        self.messageEncoder.deinit();

        self.connectionRetryTimer.deinit();
        self.holdTimer.deinit();
        self.keepAliveTimer.deinit();
        self.delayOpenTimer.deinit();

    }

    pub fn setPeerConnection(self: *Self, connection: std.net.Stream) !void {
        std.debug.assert(self.peerConnection == null);
        std.debug.assert(self.peerConnectionThread == null);

        self.connectionState = .Open;
        self.peerConnection = connection;
        const connContext: connections.ConnectionHandlerContext = .{ .session =  self, .allocator = self.allocator };
        self.peerConnectionThread = std.Thread.spawn(.{}, connections.connectionHandler, .{connContext}) catch |err| {
            self.connectionState = .Closing;

            self.peerConnection.?.close();
            self.peerConnectionThread.?.join();
            self.peerConnection = null;
            self.peerConnectionThread = null;

            return err;
        };
    }

    pub fn startConnection(self: *Self) !void {
        const startContext: StartConnContext = .{ .session = self, .allocator = self.allocator };
        self.connectionStartThread = try std.Thread.spawn(.{}, connectionStartThread, .{startContext});
    }

    pub fn closeConnection(self: *Self) void {
        self.connectionState = .Closing;

        self.peerConnection.?.close();
        self.peerConnectionThread.?.join();
        self.peerConnection = null;
        self.peerConnectionThread = null;
    }

    fn switchState(self: *Self, nextState: SessionState) !void {
        self.parent.session.mutex.lock();
        defer self.parent.session.mutex.unlock();

        std.log.info("Session switching state: {s} => {s}", .{ @tagName(self.parent.session.state), @tagName(nextState) });

        self.parent.session.state = nextState;

        switch (nextState) {
            else => return,
        }
    }

    pub fn handleEvent(self: *Self, event: Event) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const nextAction: PostHandlerAction = switch (self.state) {
            .IDLE => try idleHandler.handleEvent(self, event),
            .CONNECT => try connectHandler.handleEvent(self, event),
            .ACTIVE => try activeHandler.handleEvent(self, event),
            .OPEN_SENT => try openSentHandler.handleEvent(self, event),
            .OPEN_CONFIRM => try openConfirmHandler.handleEvent(self, event),
            .ESTABLISHED => try establishedHandler.handleEvent(self, event),
        };

        switch (nextAction) {
            .Transition => |nextState| try self.switchState(nextState),
            .Keep => return,
        }
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
    session: Session,

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
            .session = .init(self, alloc),
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

