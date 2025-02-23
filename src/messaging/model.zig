pub const ParameterType = enum(u8) {};

pub const Parameter = union(ParameterType) {};

pub const OpenMessage = struct { version: u8, asNumber: u16, holdTime: u16, peerRouterId: u32, parameters: ?[]Parameter };

pub const KeepAliveMessage = struct {};

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

pub const BgpMessage = union(BgpMessageType) { OPEN: OpenMessage, UPDATE: void, NOTIFICATION: void, KEEPALIVE: KeepAliveMessage };
