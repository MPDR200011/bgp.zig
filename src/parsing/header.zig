const std = @import("std");

const HEADER_LENGTH = 19;
const MARKER_LENGTH = 16;
const MSG_LENGTH_POS = 16;
const MSG_TYPE_POS = 18;

const HeaderParsingError = error{ InvalidMarker, MessageLengthTooShort, UnrecognisedMessageType };

const BgpMessageType = enum(u8) {
    // 1 - OPEN
    OPEN = 1,
    // 2 - UPDATE
    UPDATE = 2,
    // 3 - NOTIFICATION
    NOTIFICATION = 3,
    // 4 - KEEPALIVE
    KEEPALIVE = 4,
};

const BgpMessageHeader = struct { messageLength: u16, messageType: BgpMessageType };

pub fn readHeader(r: anytype) !BgpMessageHeader {

    var header_buffer: [HEADER_LENGTH]u8 = undefined;
    const read_bytes = try r.readAll(&header_buffer);

    if (read_bytes != HEADER_LENGTH) {
        return error.EndOfStream;
    }

    inline for (header_buffer[0..MARKER_LENGTH]) |byte| {
        if (byte != 0xff) {
            return HeaderParsingError.InvalidMarker;
        }
    }

    const message_length = std.mem.readInt(u16, header_buffer[MSG_LENGTH_POS..MSG_TYPE_POS], .big);

    if (message_length < 19) {
        return HeaderParsingError.MessageLengthTooShort;
    }

    const message_type = std.mem.readInt(u8, header_buffer[MSG_TYPE_POS..], .big);

    return .{ .messageLength = message_length, .messageType = switch (message_type) {
        1 => BgpMessageType.OPEN,
        2 => BgpMessageType.UPDATE,
        3 => BgpMessageType.NOTIFICATION,
        4 => BgpMessageType.KEEPALIVE,
        else => return HeaderParsingError.UnrecognisedMessageType,
    } };
}

test "eos error" {
    const testing = std.testing;

    try testing.expectError(error.EndOfStream, readHeader(std.io.fixedBufferStream({}).reader()));
}
