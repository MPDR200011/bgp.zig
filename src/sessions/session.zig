const std = @import("std");
const zul = @import("zul");
const ip = @import("ip");
const timer = @import("../utils/timer.zig");

const bgpParsing = @import("../messaging/parsing/message_reader.zig");

const connections = @import("connections.zig");
const encoder = @import("../messaging/encoding/encoder.zig");
const messageModel = @import("../messaging/model.zig");
const idleHandler = @import("handlers/idle.zig");
const connectHandler = @import("handlers/connect.zig");
const activeHandler = @import("handlers/active.zig");
const openSentHandler = @import("handlers/open_sent.zig");
const openConfirmHandler = @import("handlers/open_confirm.zig");
const establishedHandler = @import("handlers/established.zig");

const ribManager = @import("../rib/main_rib_manager.zig");
const adjRibManager = @import("../rib/adj_rib_manager.zig");

const Allocator = std.mem.Allocator;

const RibManager = ribManager.RibManager;
const OutAdjRibCallback = ribManager.OutAdjRibCallback;
const MainRibOperation = ribManager.Operation;
const SubHandle = ribManager.RibManager.CallbackHandle;

const AdjRibManager = adjRibManager.AdjRibManager;
const AdjRibSubscription = adjRibManager.Subscription;
const AdjRibOperation = adjRibManager.Operation;

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

pub const CollisionContext = struct { newConnection: std.net.Stream, openMsg: messageModel.OpenMessage };

pub const Event = union(enum) {
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

pub const PostHandlerAction = union(enum) {
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
    p.session.submitEvent(.{ .ConnectionRetryTimerExpired = {} }) catch {
        std.log.err("Error event", .{});
    };
}

fn sendKeepAliveEvent(p: *Peer) void {
    p.lock();
    defer p.unlock();
    p.session.submitEvent(.{ .KeepAliveTimerExpired = {} }) catch {
        std.log.err("Error event", .{});
    };
}

fn sendHoldTimerEvent(p: *Peer) void {
    p.lock();
    defer p.unlock();
    p.session.submitEvent(.{ .HoldTimerExpired = {} }) catch {
        std.log.err("Error event", .{});
    };
}

fn sendDelayOpenEvent(p: *Peer) void {
    p.lock();
    defer p.unlock();
    p.session.submitEvent(.{ .DelayOpenTimerExpired = {} }) catch {
        std.log.err("Error event", .{});
    };
}

pub const ConnectionState = enum(u8) {
    Open = 1,
    Closing = 2,
};

const StartConnContext = struct { session: *Session, allocator: std.mem.Allocator };

fn connectionStartThread(ctx: StartConnContext) void {
    if (!ctx.session.connectionMutex.tryLock()) {
        std.log.err("Competing threads are trying to start a TCP connection on the same session!!!", .{});
        return;
    }
    defer ctx.session.connectionMutex.unlock();

    std.debug.assert(ctx.session.peerConnection == null);

    const peerAddress = std.net.Address.initIp4(ctx.session.parent.sessionAddresses.peerAddress.address, ctx.session.parent.sessionPorts.peerPort);
    const peerConnection = std.net.tcpConnectToAddress(peerAddress) catch |err| {
        std.log.err("Failed to establish TCP connection with peer: {}", .{err});

        ctx.session.connectionState = .Closing;
        ctx.session.submitEvent(.{ .TcpConnectionFailed = {} }) catch {
            return;
        };

        return;
    };

    ctx.session.connectionState = .Open;

    ctx.session.peerConnection = peerConnection;
    const connContext: connections.ConnectionHandlerContext = .{ .session = ctx.session, .allocator = ctx.allocator };
    ctx.session.peerConnectionThread = std.Thread.spawn(.{}, connections.connectionHandler, .{connContext}) catch |err| {
        std.log.err("Failed to start connection connection thread: {}", .{err});

        ctx.session.connectionState = .Closing;

        ctx.session.peerConnection.?.close();
        ctx.session.peerConnection = null;

        ctx.session.submitEvent(.{ .TcpConnectionFailed = {} }) catch {
            return;
        };

        return;
    };

    ctx.session.submitEvent(.{ .TcpConnectionSuccessful = ctx.session.peerConnection.? }) catch {
        return;
    };
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

    connectionMutex: std.Thread.Mutex,
    peerConnection: ?std.net.Stream,
    peerConnectionThread: ?std.Thread,

    messageReader: bgpParsing.MessageReader,
    messageEncoder: encoder.MessageEncoder,

    allocator: std.mem.Allocator,

    eventQueue: *zul.ThreadPool(Self.handleEvent),

    adjRibInManager: ?AdjRibManager,
    adjRibOutManager: ?AdjRibManager,

    pub fn init(parent: *Peer, alloc: Allocator) !Self {
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
            .connectionMutex = .{},
            .peerConnection = null,
            .peerConnectionThread = null,
            .messageReader = .init(alloc),
            .messageEncoder = .init(alloc),
            .allocator = alloc,
            .eventQueue = try .init(alloc, .{ .count = 1, .backlog = 1 }),
            .adjRibInManager = null,
            .adjRibOutManager = null,
        };
    }

    pub fn deinit(self: *Self) void {
        self.releaseBgpResources();
        self.closeConnection();

        self.messageReader.deinit();

        self.messageEncoder.deinit();

        self.connectionRetryTimer.deinit();
        self.holdTimer.deinit();
        self.keepAliveTimer.deinit();
        self.delayOpenTimer.deinit();

        self.eventQueue.deinit(self.allocator);
    }

    pub fn initBgpResourcesFromOpenMessage(self: *Self, msg: messageModel.OpenMessage) !void {
        self.info = .{
            .peerId = msg.peerRouterId,
            .peerAsn = msg.asNumber,
        };
        self.adjRibOutManager = try .init(self.allocator, .{ .V4 = self.parent.sessionAddresses.peerAddress });
        self.adjRibInManager = try .init(self.allocator, .{ .V4 = self.parent.sessionAddresses.peerAddress });
    }

    pub fn releaseBgpResources(self: *Self) void {
        self.info = null;

        if (self.adjRibInManager) |*adjRibInManager| {
            adjRibInManager.deinit();
            self.adjRibInManager = null;
        }

        if (self.adjRibOutManager) |*adjRibOutManager| {
            adjRibOutManager.deinit();
            self.adjRibOutManager = null;
        }
    }

    pub fn createOpenMessage(self: *Self, holdTimerValue: u16) messageModel.OpenMessage {
        return .{ .version = 4, .asNumber = self.parent.localAsn, .holdTime = holdTimerValue, .peerRouterId = self.parent.localRouterId, .parameters = null };
    }

    pub fn sendMessage(self: *Self, msg: messageModel.BgpMessage) !void {
        self.connectionMutex.lock();
        defer self.connectionMutex.unlock();

        std.debug.assert(self.peerConnection != null);
        const connection = self.peerConnection orelse {
            return error.ConnectionNotUp;
        };

        try self.messageEncoder.writeMessage(msg, connection.writer().any());

        if (msg == .UPDATE) {
            try self.keepAliveTimer.reschedule();
        }
    }

    pub fn shutdownFatal(self: *Self) void {
        std.log.info("Initiated fatal shutdown!", .{});

        switch (self.state) {
            .OPEN_SENT, .OPEN_CONFIRM, .ESTABLISHED => {
                const msg: messageModel.NotificationMessage = .initNoData(.FSMError, .Default);
                self.sendMessage(.{ .NOTIFICATION = msg }) catch |err| {
                    std.log.err("Failed to send notification during fatal shutdown: {}", .{err});
                };
            },
            .IDLE, .CONNECT, .ACTIVE => {},
        }

        self.closeConnection();
        self.killAllTimers();
        self.releaseBgpResources();
        self.connectionRetryCount += 1;
    }

    fn killAllTimers(self: *Self) void {
        self.connectionRetryTimer.cancel();
        self.holdTimer.cancel();
        self.keepAliveTimer.cancel();
        self.delayOpenTimer.cancel();
    }

    pub fn setPeerConnection(self: *Self, connection: std.net.Stream) !void {
        std.debug.assert(self.peerConnection == null);
        std.debug.assert(self.peerConnectionThread == null);

        self.connectionMutex.lock();
        defer self.connectionMutex.unlock();

        self.connectionState = .Open;
        self.peerConnection = connection;
        const connContext: connections.ConnectionHandlerContext = .{ .session = self, .allocator = self.allocator };
        self.peerConnectionThread = std.Thread.spawn(.{}, connections.connectionHandler, .{connContext}) catch |err| {
            self.connectionState = .Closing;

            self.peerConnection.?.close();
            self.peerConnection = null;
            self.peerConnectionThread = null;

            return err;
        };
    }

    pub fn startConnection(self: *Self) !void {
        self.connectionState = .Open;

        const startContext: StartConnContext = .{ .session = self, .allocator = self.allocator };
        const t = try std.Thread.spawn(.{}, connectionStartThread, .{startContext});
        t.detach();
    }

    pub fn closeConnection(self: *Self) void {
        std.log.info("Closing connection", .{});
        self.connectionMutex.lock();
        defer self.connectionMutex.unlock();

        self.connectionState = .Closing;

        if (self.peerConnection) |conn| {
            conn.close();
        }
        if (self.peerConnectionThread) |t| {
            t.join();
        }
        self.peerConnection = null;
        self.peerConnectionThread = null;
    }

    fn switchState(self: *Self, nextState: SessionState) void {
        std.log.info("Session switching state: {s} => {s}", .{ @tagName(self.parent.session.state), @tagName(nextState) });

        self.parent.session.state = nextState;
    }

    pub fn submitEvent(self: *Self, event: Event) !void {
        try self.eventQueue.spawn(.{ self, event });
    }

    inline fn invokeHandler(self: *Self, event: Event) !PostHandlerAction {
        const nextAction: PostHandlerAction = switch (self.state) {
            .IDLE => try idleHandler.handleEvent(self, event),
            .CONNECT => try connectHandler.handleEvent(self, event),
            .ACTIVE => try activeHandler.handleEvent(self, event),
            .OPEN_SENT => try openSentHandler.handleEvent(self, event),
            .OPEN_CONFIRM => try openConfirmHandler.handleEvent(self, event),
            .ESTABLISHED => try establishedHandler.handleEvent(self, event),
        };

        return nextAction;
    }

    pub fn handleEvent(self: *Self, event: Event) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        std.log.debug(">>>>>>>>Handling event: {s}", .{@tagName(event)});

        const nextAction = self.invokeHandler(event) catch |err| {
            std.log.err("Failed to handle event {s} with error: {}", .{ @tagName(event), err });
            return;
        };

        switch (nextAction) {
            .Transition => |nextState| self.switchState(nextState),
            .Keep => return,
        }

        std.log.debug("<<<<<<<<Finished handling event: {s}", .{@tagName(event)});

        switch (event) {
            .OpenReceived => |msg| {self.messageReader.deInitMessage(.{ .OPEN = msg });},
            .UpdateReceived => |msg| {self.messageReader.deInitMessage(.{ .UPDATE = msg });},
            .NotificationReceived => |msg| {self.messageReader.deInitMessage(.{ .NOTIFICATION = msg });},
            .OpenCollisionDump => |ctx| {self.messageReader.deInitMessage(.{ .OPEN = ctx.openMsg });},
            else => {}
        }
    }

    pub fn processUpdateMsg(self: *Self, msg: messageModel.UpdateMessage) !void {
        for (msg.withdrawnRoutes) |route| {
            self.adjRibInManager.?.removePath(route);
        }

        for (msg.advertisedRoutes) |route| {
            try self.adjRibInManager.?.setPath(route, msg.pathAttributes);
        }
    }
};

pub fn PeerSessionAddresses(comptime afi: type) type {
    if (afi != ip.IpV4Address and afi != ip.IpV6Address) {
        @compileError("Invalid Ip Address Type");
    }

    return struct {
        localAddress: afi,
        peerAddress: afi,
    };
}

pub const v4PeerSessionAddresses = PeerSessionAddresses(ip.IpV4Address);

pub const PeerSessionPorts = struct {
    localPort: u16,
    peerPort: u16,
};

pub const PeerConfig = struct {
    localAsn: u16,
    holdTime: u16,
    localRouterId: u32,
    peeringMode: Mode,
    delayOpen: bool,
    delayOpen_ms: u32 = 0,

    sessionAddresses: v4PeerSessionAddresses,
    sessionPorts: PeerSessionPorts,
};
pub const Peer = struct {
    const Self = @This();

    localAsn: u16,
    holdTime: u16,
    localRouterId: u32,
    mode: Mode,
    delayOpen: bool,
    delayOpen_ms: u32 = 0,

    sessionAddresses: v4PeerSessionAddresses,
    sessionPorts: PeerSessionPorts,
    session: Session,

    mutex: std.Thread.Mutex,

    pub fn init(cfg: PeerConfig, self: *Self, alloc: std.mem.Allocator) !Self {
        return .{
            .localAsn = cfg.localAsn,
            .holdTime = cfg.holdTime,
            .localRouterId = cfg.localRouterId,
            .mode = cfg.peeringMode,
            .delayOpen = cfg.delayOpen,
            .delayOpen_ms = cfg.delayOpen_ms,
            .sessionAddresses = cfg.sessionAddresses,
            .sessionPorts = cfg.sessionPorts,
            .session = try .init(self, alloc),
            .mutex = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.session.deinit();
    }

    pub fn lock(self: *Self) void {
        self.mutex.lock();
    }

    pub fn unlock(self: *Self) void {
        self.mutex.unlock();
    }
};
