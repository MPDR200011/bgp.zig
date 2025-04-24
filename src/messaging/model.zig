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

    const default: Route = .{
        .prefixLength = 0,
        .prefixData = []u8{0} ** 4
    };
};

pub const Origin = enum {
    IGP,EGP,INCOMPLETE,
};

pub const ASPathSegment = union(enum) {
    AS_Set: []u16,
    AS_Sequence: []u16,
};

pub const ASPath = []ASPathSegment;

pub const Aggregator = struct {
    as: u16,
    address: ip.IpV4Address,
};

pub const PathAttribute = struct {
    ORIGIN: Origin,
    AS_PATH: ASPath,
    NEXTHOP: ip.IpV4Address,
    MULTI_EXIT_DISC: u32,
    LOCAL_PREF: u32,
    ATOMIC_AGGREGATE: void,
    AGGREGATOR: Aggregator,
};

pub const UpdateMessage = struct {
    const Self = @This();

    alloc: std.mem.Allocator,
    withdrawnRoutes: []const Route,
    advertisedRoutes: []const Route,
    pathAttributes: []PathAttribute,

    pub fn init(allocator: std.mem.Allocator, withdrawnRoutes: []const Route, advertisedRoutes: []const Route, pathAttributes: []PathAttribute) !Self {

        const wR = try allocator.alloc(Route, withdrawnRoutes.len);
        errdefer allocator.free(wR);
        std.mem.copyForwards(Route, wR, withdrawnRoutes);

        const aR = try allocator.alloc(Route, advertisedRoutes.len);
        errdefer allocator.free(aR);
        std.mem.copyForwards(Route, aR, advertisedRoutes);

        const pA = try allocator.alloc(PathAttribute, pathAttributes.len);
        errdefer allocator.free(pA);
        std.mem.copyForwards(PathAttribute, pA, pathAttributes);

        return Self{
            .alloc = allocator,
            .withdrawnRoutes = wR,
            .advertisedRoutes = aR,
            .pathAttributes = pA,
        };
    }

    pub fn deinit(self: *const Self) void {
        self.alloc.free(self.withdrawnRoutes);
        self.alloc.free(self.advertisedRoutes);
        self.alloc.free(self.pathAttributes);
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
