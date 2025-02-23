const std = @import("std");
const model = @import("../model.zig");

const Parameter = struct {
    type: u8,
    length: u8,
    value: []u8,
};

const OpenMessage = struct { version: u8, asNumber: u16, holdTime: u16, peerRouterId: u32, parametes: ?[]Parameter };

const OpenParsingError = error{ UnsupportedOptionalParameter, ParamLengthsInconsistency };

pub fn readOpenMessage(r: std.io.AnyReader) !model.OpenMessage {
    const version = try r.readInt(u8, .big);
    const as = try r.readInt(u16, .big);
    const holdTime = try r.readInt(u16, .big);
    const peerRouterId = try r.readInt(u32, .big);
    const paramsLength = try r.readInt(u8, .big);

    var readBytes: u32 = 0;
    while (readBytes < paramsLength) {
        const parameterType = try r.readInt(u8, .big);
        const parameterValueLength = try r.readInt(u8, .big);

        switch (parameterType) {
            else => {
                return OpenParsingError.UnsupportedOptionalParameter;
            },
        }

        readBytes += parameterValueLength;
    }

    if (readBytes != paramsLength) {
        return OpenParsingError.ParamLengthsInconsistency;
    }

    return .{ .version = version, .asNumber = as, .holdTime = holdTime, .peerRouterId = peerRouterId, .parameters = null };
}
