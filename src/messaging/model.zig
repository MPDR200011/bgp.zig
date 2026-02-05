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
        const data = if (dataLength > 0) null else try allocator.alloc(u8, dataLength);
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

pub const Route = struct {
    prefixLength: u8,
    prefixData: [4]u8,

    pub const default: Route = .{ .prefixLength = 0, .prefixData = [_]u8{0} ** 4 };
};

pub const Origin = enum(u8) {
    IGP = 0,
    EGP = 1,
    INCOMPLETE = 2,
};

pub const ASPathSegmentType = enum { AS_Set, AS_Sequence };
pub const ASPathSegment = struct {
    const Self = @This();

    allocator: Allocator,

    segType: ASPathSegmentType,
    contents: []const u16,

    pub fn deinit(self: Self) void {
        self.allocator.free(self.contents);
    }

    pub fn clone(self: Self, allocator: std.mem.Allocator) !Self {
        return Self{
            .allocator = allocator,
            .segType = self.segType,
            .contents = try allocator.dupe(u16, self.contents),
        };
    }

    pub inline fn equal(self: Self, other: Self) bool {
        if (self.segType != other.segType) {
            return false;
        }

        return std.mem.eql(u16, self.contents, other.contents);
    }

    pub fn hash(self: Self, hasher: anytype) void {
        std.hash.autoHash(hasher, self.segType);
        for (self.contents) |item| {
            std.hash.autoHash(hasher, item);
        }
    }
};

pub const ASPath = struct {
    // FIXME: Cloning logic should really be tested to ensure stuff lands on separate buffers
    const Self = @This();

    allocator: Allocator,
    segments: []const ASPathSegment,

    pub fn deinit(self: Self) void {
        for (self.segments) |seg| {
            seg.deinit();
        }
        self.allocator.free(self.segments);
    }

    pub fn clone(self: Self, allocator: std.mem.Allocator) !Self {
        const newASPath = try allocator.alloc(ASPathSegment, self.segments.len);
        errdefer allocator.free(newASPath);

        for (0..newASPath.len) |i| {
            newASPath[i] = try self.segments[i].clone(allocator);
        }

        return Self{ .allocator = allocator, .segments = newASPath };
    }

    pub inline fn equal(self: *const Self, other: *const Self) bool {
        if (self.segments.len != other.segments.len) {
            return false;
        }

        for (0..self.segments.len) |i| {
            if (!self.segments[i].equal(other.segments[i])) {
                return false;
            }
        }

        return true;
    }

    pub fn hash(self: Self, hasher: anytype) void {
        for (self.segments) |seg| {
            seg.hash(hasher);
        }
    }

    pub fn createEmpty(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            .segments = allocator.dupe(ASPathSegment, &[_]ASPathSegment{}) catch {
                std.debug.print("ERROR ALLOCATING EMPTY SLICE, WTF!!!!!", .{});
                std.process.abort();
            },
        };
    }

    pub fn len(self: *const Self) usize {
        var size: usize = 0;
        for (self.segments) |segment| {
            switch (segment.segType) {
                .AS_Sequence => size += segment.contents.len,
                .AS_Set => size += 1,
            }
        }
        return size;
    }
};

pub const Aggregator = struct {
    const Self = @This();

    as: u16,
    address: ip.IpV4Address,

    pub fn equal(self: Self, other: Self) bool {
        return self.as == other.as and self.address.equals(other.address);
    }

    pub fn hash(self: Self, hasher: anytype) void {
        std.hash.autoHash(hasher, self.as);
        std.hash.autoHash(hasher, std.mem.asBytes(&self.address));
    }
};

pub const PathAttributes = struct {
    const Self = @This();

    allocator: Allocator,

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

    pub fn deinit(self: Self) void {
        self.asPath.deinit();
    }

    pub fn clone(self: Self, allocator: std.mem.Allocator) !Self {
        return Self{
            .allocator = allocator,
            .origin = self.origin,
            .asPath = try self.asPath.clone(allocator),
            .nexthop = self.nexthop,
            .localPref = self.localPref,
            .atomicAggregate = self.atomicAggregate,
            .multiExitDiscriminator = self.multiExitDiscriminator,
            .aggregator = self.aggregator,
        };
    }

    pub fn equal(self: Self, other: Self) bool {
        if (self.origin != other.origin) return false;
        if (!self.asPath.equal(&other.asPath)) return false;
        if (!self.nexthop.equals(other.nexthop)) return false;
        if (self.localPref != other.localPref) return false;
        if (self.atomicAggregate != other.atomicAggregate) return false;
        if (self.multiExitDiscriminator != other.multiExitDiscriminator) return false;
        if (self.aggregator == null) {
            if (other.aggregator != null) return false;
        } else {
            if (other.aggregator == null) return false;
            if (!self.aggregator.?.equal(other.aggregator.?)) return false;
        }

        return true;
    }

    pub fn hash(self: Self, hasher: anytype) void {
        std.hash.autoHash(hasher, self.origin);
        self.asPath.hash(hasher);
        std.hash.autoHash(hasher, std.mem.asBytes(&self.nexthop));
        std.hash.autoHash(hasher, self.localPref);
        std.hash.autoHash(hasher, self.atomicAggregate);
        std.hash.autoHash(hasher, self.multiExitDiscriminator);
        if (self.aggregator) |agg| {
            agg.hash(hasher);
        }
    }
};

pub const UpdateMessage = struct {
    const Self = @This();

    allocator: Allocator,

    withdrawnRoutes: []const Route,
    advertisedRoutes: []const Route,
    pathAttributes: PathAttributes,

    pub fn init(allocator: Allocator, withdrawnRoutes: []const Route, advertisedRoutes: []const Route, pathAttributes: PathAttributes) !Self {
        const wR = try allocator.alloc(Route, withdrawnRoutes.len);
        errdefer allocator.free(wR);
        std.mem.copyForwards(Route, wR, withdrawnRoutes);

        const aR = try allocator.alloc(Route, advertisedRoutes.len);
        errdefer allocator.free(aR);
        std.mem.copyForwards(Route, aR, advertisedRoutes);

        return Self{
            .allocator = allocator,
            .withdrawnRoutes = wR,
            .advertisedRoutes = aR,
            .pathAttributes = try pathAttributes.clone(pathAttributes.allocator),
        };
    }

    pub fn deinit(self: *const Self) void {
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

    pub fn deinit(self: Self) void {
        switch (self) {
            .UPDATE => |msg| msg.deinit(),
            .NOTIFICATION => |msg| msg.deinit(),
            else => {},
        }
    }
};

test "PathAttributes hash and equal" {
    const allocator = std.testing.allocator;

    const as_path_seg = ASPathSegment{
        .allocator = allocator,
        .segType = .AS_Sequence,
        .contents = try allocator.dupe(u16, &[_]u16{ 1, 2, 3 }),
    };
    defer as_path_seg.deinit();

    const as_path = ASPath{
        .allocator = allocator,
        .segments = try allocator.dupe(ASPathSegment, &[_]ASPathSegment{try as_path_seg.clone(allocator)}),
    };
    defer as_path.deinit();

    const attrs1 = PathAttributes{
        .allocator = allocator,
        .origin = .IGP,
        .asPath = try as_path.clone(allocator),
        .nexthop = ip.IpV4Address.parse("1.1.1.1") catch unreachable,
        .localPref = 100,
        .atomicAggregate = false,
        .multiExitDiscriminator = 0,
        .aggregator = .{
            .as = 65001,
            .address = ip.IpV4Address.parse("2.2.2.2") catch unreachable,
        },
    };
    defer attrs1.deinit();

    const attrs2 = try attrs1.clone(allocator);
    defer attrs2.deinit();

    try std.testing.expect(attrs1.equal(attrs2));

    var hasher1 = std.hash.Wyhash.init(0);
    attrs1.hash(&hasher1);
    const h1 = hasher1.final();

    var hasher2 = std.hash.Wyhash.init(0);
    attrs2.hash(&hasher2);
    const h2 = hasher2.final();

    try std.testing.expectEqual(h1, h2);

    // Test differences
    var attrs3 = try attrs1.clone(allocator);
    defer attrs3.deinit();
    attrs3.localPref = 200;
    try std.testing.expect(!attrs1.equal(attrs3));

    var hasher3 = std.hash.Wyhash.init(0);
    attrs3.hash(&hasher3);
    try std.testing.expect(h1 != hasher3.final());

    // Test ASPath difference
    var attrs4 = try attrs1.clone(allocator);
    defer attrs4.deinit();
    attrs4.asPath.deinit();
    const new_seg = ASPathSegment{
        .allocator = allocator,
        .segType = .AS_Sequence,
        .contents = try allocator.dupe(u16, &[_]u16{ 1, 2, 4 }),
    };
    attrs4.asPath = ASPath{
        .allocator = allocator,
        .segments = try allocator.dupe(ASPathSegment, &[_]ASPathSegment{new_seg}),
    };
    try std.testing.expect(!attrs1.equal(attrs4));

    var hasher4 = std.hash.Wyhash.init(0);
    attrs4.hash(&hasher4);
    try std.testing.expect(h1 != hasher4.final());
}
