const std = @import("std");

const Allocator = std.mem.Allocator;

pub const ParameterType = enum(u8) {};

pub const Parameter = union(ParameterType) {};

pub const OpenMessage = struct { version: u8, asNumber: u16, holdTime: u16, peerRouterId: u32, parameters: ?[]Parameter };

pub const KeepAliveMessage = struct {};

pub const UpdateMessage = struct {};


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

pub const BgpMessage = union(BgpMessageType) { OPEN: OpenMessage, UPDATE: UpdateMessage, NOTIFICATION: NotificationMessage, KEEPALIVE: KeepAliveMessage };
