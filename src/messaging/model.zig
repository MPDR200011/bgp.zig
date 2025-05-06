const std = @import("std");
const ip = @import("ip");

const Allocator = std.mem.Allocator;

pub const ParameterType = enum(u8) {};

pub const Parameter = union(ParameterType) {};

pub const OpenMessage = struct { version: u8, asNumber: u16, holdTime: u16, peerRouterId: u32, parameters: ?[]Parameter };

pub const KeepAliveMessage = struct {};


pub const ErrorCode = enum(u8) {
    HeaderError = 1,
    OpenMessageError = 2,
    UpdateMessageError = 3,
    HoldTimerExpired = 4,
    FSMError = 5,      
    Cease = 6,        
};

pub const ErrorKind = enum(u8) {
    Default = 0,
    // Header Message Error subcodes:
    ConnectionNotSynchronized=1,
    BadMessageLength=2,
    BadMessageType=3,
    // OPEN Message Error subcodes:
    UnsupportedVersionNumber=4,
    BadPeerAS=5,
    BadBGPIdentifier=6,
    UnsupportedOptionalParameter=7,
    UnacceptableHoldTime=8,
    // UPDATE Message Error subcodes:
    MalformedAttributeList=9,
    UnrecognizedWellKnownAttribute=10,
    MissingWellKnownAttribute=11,
    AttributeFlagsError=12,
    AttributeLengthError=13,
    InvalidORIGINAttribute=14,
    InvalidNEXT_HOPAttribute=15,
    OptionalAttributeError=16,
    InvalidNetworkField=17,
    MalformedAS_PATH=18,
};

pub const NotificationMessage = struct {
    const Self = @This();

    errorCode: ErrorCode,
    errorKind: ErrorKind,
    data: ?[]u8,

    allocator: ?Allocator,

    pub fn initNoData(errorCode: ErrorCode, errorKind: ErrorKind) Self {
        return .{
            .errorCode = errorCode,
            .errorKind = errorKind,
            .data = null,
            .allocator = null,
        };
    }

    pub fn init(errorCode: ErrorCode, errorKind: ErrorKind, dataLength: usize, allocator: Allocator) !Self {
        const data = if (dataLength > 0) null else try allocator.alloc(u8, dataLength);

        return .{
            .errorCode = errorCode,
            .errorKind = errorKind,
            .data = data,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: Self) void {
        if (self.data != null) {
            std.debug.assert(self.allocator != null);
            self.allocator.?.free(self.data.?);
        }
    }
};

pub const Route = struct {
    prefixLength: u8,
    prefixData: [4]u8,

    pub const default: Route = .{
        .prefixLength = 0,
        .prefixData = [_]u8{0} ** 4
    };
};

pub const Origin = enum {
    IGP,EGP,INCOMPLETE,
};

pub const ASPathSegment = union(enum) {
    const Self = @This();

    AS_Set: []u16,
    AS_Sequence: []u16,

    pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
        switch (self) {
            .AS_Set => |e| return allocator.free(e),
            .AS_Sequence => |e| return allocator.free(e),
        }
    }

    pub fn clone(self: Self, allocator: std.mem.Allocator) !Self {
        switch (self) {
            .AS_Set => |e| return .{.AS_Set = try allocator.dupe(u16, e)},
            .AS_Sequence => |e| return .{.AS_Sequence = try allocator.dupe(u16, e)},
        }
    }
};

pub const ASPath = struct {
    const Self = @This();

    segments: []const ASPathSegment,

    pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
        for (self.segments) |seg| {
            seg.deinit(allocator);
        }
        allocator.free(self.segments);
    }

    pub fn clone(self: Self, allocator: std.mem.Allocator) !Self {
        const newASPath = try allocator.alloc(ASPathSegment, self.segments.len);

        for (0..newASPath.len) |i| {
            newASPath[i] = try self.segments[i].clone(allocator);
        }

        return Self{.segments = newASPath};
    }
};

pub const Aggregator = struct {
    as: u16,
    address: ip.IpV4Address,
};

pub const PathAttributes = struct {
    const Self = @This();
    // Well known, Mandatory
    origin: Origin,
    asPath: ASPath,
    nexthop: ip.IpV4Address,

    // Well known
    // Mandatory for internal peers or confeds
    localPref: u32,

    // Well known, discretionary
    atomicAggregate: bool,

    // Optional, non-transitive
    multiExitDiscriminator: ?u32,

    // Optional, transitive
    aggregator: ?Aggregator,

    pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
        self.asPath.deinit(allocator);
    }

    pub fn clone(self: Self, allocator: std.mem.Allocator) !Self {
        return Self{
            .origin = self.origin,
            .asPath = try self.asPath.clone(allocator),
            .nexthop = self.nexthop,
            .localPref = self.localPref,
            .atomicAggregate = self.atomicAggregate,
            .multiExitDiscriminator = self.multiExitDiscriminator,
            .aggregator = self.aggregator,
        };
    }
};

pub const UpdateMessage = struct {
    const Self = @This();

    alloc: std.mem.Allocator,
    withdrawnRoutes: []const Route,
    advertisedRoutes: []const Route,
    pathAttributes: PathAttributes,

    pub fn init(allocator: std.mem.Allocator, withdrawnRoutes: []const Route, advertisedRoutes: []const Route, pathAttributes: PathAttributes) !Self {

        const wR = try allocator.alloc(Route, withdrawnRoutes.len);
        errdefer allocator.free(wR);
        std.mem.copyForwards(Route, wR, withdrawnRoutes);

        const aR = try allocator.alloc(Route, advertisedRoutes.len);
        errdefer allocator.free(aR);
        std.mem.copyForwards(Route, aR, advertisedRoutes);

        return Self{
            .alloc = allocator,
            .withdrawnRoutes = wR,
            .advertisedRoutes = aR,
            .pathAttributes = try pathAttributes.clone(allocator),
        };
    }

    pub fn deinit(self: *const Self) void {
        self.alloc.free(self.withdrawnRoutes);
        self.alloc.free(self.advertisedRoutes);
        self.pathAttributes.deinit(self.alloc);
    }
};


pub const BgpMessageType = enum(u8) {
    // 1 - OPEN
    OPEN = 1,
    // 2 - UPDATE
    UPDATE = 2,
    // 3 - NOTIFICATION
    NOTIFICATION = 3,
    // 4 - KEEPALIVE
    KEEPALIVE = 4,
};

pub const BgpMessage = union(BgpMessageType) {
    const Self = @This();

    OPEN: OpenMessage, UPDATE: UpdateMessage, NOTIFICATION: NotificationMessage, KEEPALIVE: KeepAliveMessage,

    pub fn deinit(self: Self) void {
        switch (self) {
            .UPDATE => |msg| msg.deinit(),
            .NOTIFICATION => |msg| msg.deinit(),
            else => {},
        }
    }
};
