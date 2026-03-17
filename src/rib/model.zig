const std = @import("std");
const ip = @import("ip");

const Allocator = std.mem.Allocator;

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

pub const ASPathSegmentType = enum(u8) { AS_Set = 1, AS_Sequence = 2 };
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
        std.hash.autoHash(hasher, self.contents.len);
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

    pub fn initEmpty(alloc: Allocator) !Self {
        return .{
            .allocator = alloc,
            .segments = try alloc.alloc(ASPathSegment, 0),
        };
    }

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
        std.hash.autoHash(hasher, self.segments.len);
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

    pub fn prependASN(self: *Self, asn: u16) !void {
        // FIXME: Missing overflow protection (prevent segment length from
        // going over 255)
        if (self.segments.len == 0) {
            const newSegments = try self.allocator.alloc(ASPathSegment, 1);

            const contents = try self.allocator.alloc(u16, 1);
            contents[0] = asn;
            newSegments[0] = ASPathSegment{
                .allocator = self.allocator,
                .contents = contents,
                .segType = .AS_Sequence,
            };

            self.allocator.free(self.segments);
            self.segments = newSegments;
            return;
        }

        switch (self.segments[0].segType) {
            .AS_Sequence => {
                var firstSegment = self.segments[0];
                const newContents = try firstSegment.allocator.alloc(u16, firstSegment.contents.len + 1);
                newContents[0] = asn;
                std.mem.copyForwards(u16, newContents[1..], firstSegment.contents);
                firstSegment.allocator.free(firstSegment.contents);
                firstSegment.contents = newContents;
                @constCast(self.segments)[0] = firstSegment;
            },
            .AS_Set => {
                const newSegments = try self.allocator.alloc(ASPathSegment, self.segments.len + 1);
                std.mem.copyForwards(ASPathSegment, newSegments[1..], self.segments);

                const contents = try self.allocator.alloc(u16, 1);
                contents[0] = asn;
                newSegments[0] = ASPathSegment{
                    .allocator = self.allocator,
                    .contents = contents,
                    .segType = .AS_Sequence,
                };

                self.allocator.free(self.segments);
                self.segments = newSegments;
            },
        }
    }

    pub fn format(
        self: *const Self,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("[", .{});
        for (self.segments, 0..) |segment, segi| {
            if (segment.segType == .AS_Sequence) {
                try writer.print("seq{{", .{});
            } else {
                try writer.print("set{{", .{});
            }
            for (segment.contents, 0..) |asn, asni| {
                try writer.print("{d}", .{asn});
                if (asni < segment.contents.len-1) {
                    try writer.print(", ", .{});
                }
            }
            try writer.print("}}", .{});
            if (segi < self.segments.len-1) {
                try writer.print(", ", .{});
            }
        }
        try writer.print("]", .{});
    }
};

pub const Nexthop = union(enum) {
    Self: void,
    Address: ip.IpV4Address,

    pub fn equals(self: @This(), other: @This()) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) {
            return false;
        }
        switch (self) {
            .Self => return true,
            .Address => |addr| {
                return addr.equals(other.Address);
            }
        }
    }
};

pub const Aggregator = struct {
    const Self = @This();

    as: u16,
    address: ip.IpV4Address,

    pub fn equal(self: *const Self, other: *const Self) bool {
        return self.as == other.as and self.address.equals(other.address);
    }

    pub fn hash(self: Self, hasher: anytype) void {
        std.hash.autoHash(hasher, self.as);
        std.hash.autoHash(hasher, self.address);
    }
};

pub const Unknown = struct {
    allocator: Allocator,
    typeCode: u8,
    value: []u8,

    pub fn deinit(self: *@This()) void {
        self.allocator.free(self.value);
    }

    pub fn clone(self: @This(), allocator: Allocator) !@This() {
        return .{
            .allocator = allocator,
            .typeCode = self.typeCode,
            .value = try allocator.dupe(u8, self.value),
        };
    }
    pub fn equal(self: *const @This(), other: *const @This()) bool {
        return self.typeCode == other.typeCode and std.mem.eql(u8, self.value, other.value);
    }
};


pub const ATTR_OPTIONAL_FLAG: u8 = 0x80;
pub const ATTR_TRANSITIVE_FLAG: u8 = 0x40;
pub const ATTR_PARTIAL_FLAG: u8 = 0x20;
pub const ATTR_EXTENDED_LENGTH_FLAG: u8 = 0x10;
pub fn Attribute(comptime AttrType: type) type {
    return struct {
        const Self = @This();

        // Flags
        flags: u8,

        // Value
        value: AttrType,

        pub fn init(value: AttrType) Self {
            return Self{
                .flags = 0x00,
                .value = value
            };
        }

        pub fn isOptional(self: *const Self) bool {
            return (self.flags & ATTR_OPTIONAL_FLAG) > 0;
        }

        pub fn isTransitive(self: *const Self) bool {
            return (self.flags & ATTR_TRANSITIVE_FLAG) > 0;
        }

        pub fn isExtendedLength(self: *const Self) bool {
            return (self.flags & ATTR_EXTENDED_LENGTH_FLAG) > 0;
        }   

        pub fn isPartial(self: *const Self) bool {
            return (self.flags & ATTR_PARTIAL_FLAG) > 0;
        }
    };
}

fn areOptionalAttrsEqual(comptime Type: type, attr1: ?Attribute(Type), attr2: ?Attribute(Type)) bool {
    if (attr1) |a1| {
        if (attr2) |a2| {
            if (@typeInfo(Type) == .@"struct" and @hasDecl(Type, "equal")) {
                if (!a1.value.equal(&a2.value)) {
                    return false;
                }
            } else {
                if (a1.value != a2.value) {
                    return false;
                }
            }
        }
    } else {
        if (attr2 != null) {
            return false;
        }
    }

    return true;
}

pub const OriginAttr = Attribute(Origin);
pub const AsPathAttr = Attribute(ASPath);
pub const NexthopAttr = Attribute(Nexthop);
pub const LocalPrefAttr = Attribute(u32);
pub const AtomicAggregateAttr = Attribute(bool);
pub const MultiExitDiscriminatorAttr = Attribute(u32);
pub const AggregatorAttr = Attribute(Aggregator);
pub const UnknownAttr = Attribute(Unknown);

pub const PathAttributes = struct {
    const Self = @This();

    allocator: Allocator,

    // Well known, Mandatory
    origin: OriginAttr,
    asPath: AsPathAttr,
    nexthop: NexthopAttr,

    // Well known
    // Mandatory for internal peers or confeds
    localPref: LocalPrefAttr = .init(100),

    // Well known, discretionary
    atomicAggregate: ?AtomicAggregateAttr = null,

    // Optional, non-transitive
    multiExitDiscriminator: ?MultiExitDiscriminatorAttr = null,

    // Optional, transitive
    aggregator: ?AggregatorAttr = null,

    unknownAttributes: []UnknownAttr = &[_]UnknownAttr{},

    pub const empty: Self = .{
        .allocator = undefined,
        .origin = undefined,
        .asPath = undefined,
        .nexthop = undefined,
        .localPref = .init(100),
        .atomicAggregate = null,
        .multiExitDiscriminator = null,
        .aggregator = null,
        .unknownAttributes = &[_]UnknownAttr{},
    };

    pub fn deinit(self: Self) void {
        self.asPath.value.deinit();
        
        for (self.unknownAttributes) |*uk| {
            uk.value.deinit();
        }
        self.allocator.free(self.unknownAttributes);
    }

    pub fn clone(self: Self, allocator: std.mem.Allocator) !Self {
        var copy = Self{
            .allocator = allocator,
            .origin = self.origin,
            .asPath = self.asPath,
            .nexthop = self.nexthop,
            .localPref = self.localPref,
            .atomicAggregate = self.atomicAggregate,
            .multiExitDiscriminator = self.multiExitDiscriminator,
            .aggregator = self.aggregator,
            .unknownAttributes = undefined,
        };
        copy.asPath.value = try self.asPath.value.clone(allocator);
        {
            copy.unknownAttributes = try allocator.alloc(UnknownAttr, self.unknownAttributes.len);
            for (self.unknownAttributes, 0..) |uk, i| {
                copy.unknownAttributes[i] = .{
                    .flags = uk.flags,
                    .value = try uk.value.clone(allocator),
                };
            }
        }
        return copy;
    }

    pub fn equal(self: *const Self, other: *const Self) bool {
        if (self.origin.value != other.origin.value) return false;
        if (!self.asPath.value.equal(&other.asPath.value)) return false;
        if (!self.nexthop.value.equals(other.nexthop.value)) return false;
        if (self.localPref.value != other.localPref.value) return false;

        if (!areOptionalAttrsEqual(bool, self.atomicAggregate, other.atomicAggregate)) {
            return false;
        }

        if (!areOptionalAttrsEqual(u32, self.multiExitDiscriminator, other.multiExitDiscriminator)) {
            return false;
        }

        if (!areOptionalAttrsEqual(Aggregator, self.aggregator, other.aggregator)) {
            return false;
        }

        // This assume the unknown attributes are sorted by type code
        if (self.unknownAttributes.len != other.unknownAttributes.len) return false;
        for (self.unknownAttributes, 0..) |uk, i| {
            if (!uk.value.equal(&other.unknownAttributes[i].value)) return false;
        }

        return true;
    }

    pub fn hash(self: Self, hasher: anytype) void {
        std.hash.autoHash(hasher, self.origin.value);
        self.asPath.value.hash(hasher);
        std.hash.autoHash(hasher, self.nexthop.value);
        std.hash.autoHash(hasher, self.localPref.value);
        if (self.atomicAggregate) |v| {
            std.hash.autoHash(hasher, v.value);
        }
        if (self.multiExitDiscriminator) |v| {
            std.hash.autoHash(hasher, v.value);
        }
        if (self.aggregator) |agg| {
            agg.value.hash(hasher);
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
        .origin = .init(.IGP),
        .asPath = .init(try as_path.clone(allocator)),
        .nexthop = .init(.{ .Address = ip.IpV4Address.parse("1.1.1.1") catch unreachable }),
        .localPref = .init(100),
        .atomicAggregate = .init(false),
        .multiExitDiscriminator = .init(0),
        .aggregator = .init(.{
            .as = 65001,
            .address = ip.IpV4Address.parse("2.2.2.2") catch unreachable,
        }),
    };
    defer attrs1.deinit();

    const attrs2 = try attrs1.clone(allocator);
    defer attrs2.deinit();

    try std.testing.expect(attrs1.equal(&attrs2));

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
    attrs3.localPref.value = 200;
    try std.testing.expect(!attrs1.equal(&attrs3));

    var hasher3 = std.hash.Wyhash.init(0);
    attrs3.hash(&hasher3);
    try std.testing.expect(h1 != hasher3.final());

    // Test ASPath difference
    var attrs4 = try attrs1.clone(allocator);
    defer attrs4.deinit();
    attrs4.asPath.value.deinit();
    const new_seg = ASPathSegment{
        .allocator = allocator,
        .segType = .AS_Sequence,
        .contents = try allocator.dupe(u16, &[_]u16{ 1, 2, 4 }),
    };
    attrs4.asPath.value = ASPath{
        .allocator = allocator,
        .segments = try allocator.dupe(ASPathSegment, &[_]ASPathSegment{new_seg}),
    };
    try std.testing.expect(!attrs1.equal(&attrs4));

    var hasher4 = std.hash.Wyhash.init(0);
    attrs4.hash(&hasher4);
    try std.testing.expect(h1 != hasher4.final());
}

test "ASPath.prependASN" {
    const allocator = std.testing.allocator;

    // 1. Test empty ASPath
    var as_path = ASPath.createEmpty(allocator);
    defer as_path.deinit();

    try as_path.prependASN(100);
    try std.testing.expectEqual(@as(usize, 1), as_path.segments.len);
    try std.testing.expectEqual(ASPathSegmentType.AS_Sequence, as_path.segments[0].segType);
    try std.testing.expectEqual(@as(usize, 1), as_path.segments[0].contents.len);
    try std.testing.expectEqual(@as(u16, 100), as_path.segments[0].contents[0]);

    // 2. Test prepending to existing AS_Sequence
    try as_path.prependASN(200);
    try std.testing.expectEqual(@as(usize, 1), as_path.segments.len);
    try std.testing.expectEqual(ASPathSegmentType.AS_Sequence, as_path.segments[0].segType);
    try std.testing.expectEqual(@as(usize, 2), as_path.segments[0].contents.len);
    try std.testing.expectEqual(@as(u16, 200), as_path.segments[0].contents[0]);
    try std.testing.expectEqual(@as(u16, 100), as_path.segments[0].contents[1]);

    // 3. Test prepending to AS_Set (should create new AS_Sequence)
    var as_set_path = ASPath{
        .allocator = allocator,
        .segments = try allocator.alloc(ASPathSegment, 1),
    };
    @constCast(as_set_path.segments)[0] = ASPathSegment{
        .allocator = allocator,
        .segType = .AS_Set,
        .contents = try allocator.dupe(u16, &[_]u16{ 300, 400 }),
    };
    defer as_set_path.deinit();

    try as_set_path.prependASN(500);
    try std.testing.expectEqual(@as(usize, 2), as_set_path.segments.len);
    try std.testing.expectEqual(ASPathSegmentType.AS_Sequence, as_set_path.segments[0].segType);
    try std.testing.expectEqual(@as(usize, 1), as_set_path.segments[0].contents.len);
    try std.testing.expectEqual(@as(u16, 500), as_set_path.segments[0].contents[0]);
    try std.testing.expectEqual(ASPathSegmentType.AS_Set, as_set_path.segments[1].segType);
}
