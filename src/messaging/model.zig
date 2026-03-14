const std = @import("std");
const ip = @import("ip");

const sessions = @import("../sessions/session.zig");

const ribModel = @import("../rib/model.zig");

const Allocator = std.mem.Allocator;

const Route = ribModel.Route;

const OriginAttr = ribModel.OriginAttr;
const AsPathAttr = ribModel.AsPathAttr;
const NexthopAttr = ribModel.NexthopAttr;
const LocalPrefAttr = ribModel.LocalPrefAttr;
const AtomicAggregateAttr = ribModel.AtomicAggregateAttr;
const MultiExitDiscriminatorAttr = ribModel.MultiExitDiscriminatorAttr;
const AggregatorAttr = ribModel.AggregatorAttr;
const UnknownAttr = ribModel.UnknownAttr;

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
    ConnectionNotSynchronized = 1,
    BadMessageLength = 2,
    BadMessageType = 3,
    // OPEN Message Error subcodes:
    UnsupportedVersionNumber = 4,
    BadPeerAS = 5,
    BadBGPIdentifier = 6,
    UnsupportedOptionalParameter = 7,
    UnacceptableHoldTime = 8,
    // UPDATE Message Error subcodes:
    MalformedAttributeList = 9,
    UnrecognizedWellKnownAttribute = 10,
    MissingWellKnownAttribute = 11,
    AttributeFlagsError = 12,
    AttributeLengthError = 13,
    InvalidORIGINAttribute = 14,
    InvalidNEXT_HOPAttribute = 15,
    OptionalAttributeError = 16,
    InvalidNetworkField = 17,
    MalformedAS_PATH = 18,
};

pub const NotificationMessage = struct {
    const Self = @This();

    allocator: ?Allocator,

    errorCode: ErrorCode,
    errorKind: ErrorKind,
    data: ?[]u8,

    pub fn initNoData(errorCode: ErrorCode, errorKind: ErrorKind) Self {
        return .{
            .allocator = null,
            .errorCode = errorCode,
            .errorKind = errorKind,
            .data = null,
        };
    }

    pub fn init(errorCode: ErrorCode, errorKind: ErrorKind, dataLength: usize, allocator: Allocator) !Self {
        const data = try allocator.alloc(u8, dataLength);
        errdefer allocator.free(data);

        return .{
            .allocator = allocator,
            .errorCode = errorCode,
            .errorKind = errorKind,
            .data = data,
        };
    }

    pub fn deinit(self: Self) void {
        const data = self.data orelse return;

        std.debug.assert(self.allocator != null);
        self.allocator.?.free(data);
    }
};

pub const PathAttribute = union(enum) {
    Origin: OriginAttr,
    AsPath: AsPathAttr,
    Nexthop: NexthopAttr,

    // Well known
    // Mandatory for internal peers or confeds
    LocalPref: LocalPrefAttr,

    // Well known, discretionary
    AtomicAggregate: AtomicAggregateAttr,

    // Optional, non-transitive
    MultiExitDiscriminator: MultiExitDiscriminatorAttr,

    // Optional, transitive
    Aggregator: AggregatorAttr,

    Unknown: UnknownAttr,


    pub fn deinit(self: *@This()) void {
        switch (self.*) {
            .AsPath => |*asPath| {
                asPath.value.deinit();
            },
            .Unknown => |*unknown| {
                unknown.value.deinit();
            },
            .Origin,
            .Nexthop,
            .LocalPref,
            .AtomicAggregate,
            .MultiExitDiscriminator,
            .Aggregator => {}
        }
    }

    pub fn clone(self: *@This(), allocator: Allocator) !@This() {
        switch (self.*) {
            .AsPath => |asPath| {
                var tmp: AsPathAttr = asPath;
                tmp.value = try asPath.value.clone(allocator);
                return .{ .AsPath = tmp };
            },
            .Origin,
            .Nexthop,
            .LocalPref,
            .AtomicAggregate,
            .MultiExitDiscriminator,
            .Aggregator => { return self.*; },
            .Unknown => |unknown| {
                var tmp: UnknownAttr = unknown;
                tmp.value.value = try allocator.dupe(u8, unknown.value.value);
                tmp.value.allocator = allocator;
                return .{ .Unknown = tmp };
            },
        }
    }
};

pub const AttributeList = struct {
    alloc: Allocator,
    list: std.ArrayListUnmanaged(PathAttribute),

    pub fn deinit(self: *@This()) void {
        for (self.list.items) |*attr| {
            attr.deinit();
        }
        self.list.deinit(self.alloc);
    }
};

pub const UpdateMessage = struct {
    const Self = @This();

    allocator: Allocator,

    withdrawnRoutes: []const Route,
    advertisedRoutes: []const Route,
    pathAttributes: AttributeList,

    pub fn init(allocator: Allocator, withdrawnRoutes: []const Route, advertisedRoutes: []const Route, pathAttributes: AttributeList) !Self {
        // If attributes is null, advertisedRoutes must be empty
        std.debug.assert(pathAttributes.list.items.len > 0 or advertisedRoutes.len == 0);
        std.debug.assert(pathAttributes.list.items.len == 0 or advertisedRoutes.len > 0);

        const wR = try allocator.dupe(Route, withdrawnRoutes);
        errdefer allocator.free(wR);

        const aR = try allocator.dupe(Route, advertisedRoutes);
        errdefer allocator.free(aR);

        return Self{
            .allocator = allocator,
            .withdrawnRoutes = wR,
            .advertisedRoutes = aR,
            .pathAttributes = pathAttributes,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.withdrawnRoutes);
        self.allocator.free(self.advertisedRoutes);
        self.pathAttributes.deinit();
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

    OPEN: OpenMessage,
    UPDATE: UpdateMessage,
    NOTIFICATION: NotificationMessage,
    KEEPALIVE: KeepAliveMessage,

    pub fn deinit(self: *Self) void {
        switch (self.*) {
            .UPDATE => |*msg| msg.deinit(),
            .NOTIFICATION => |*msg| msg.deinit(),
            else => {},
        }
    }
};

