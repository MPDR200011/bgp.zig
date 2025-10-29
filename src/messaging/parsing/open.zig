const std = @import("std");
const model = @import("../model.zig");

const OpenParsingError = error{ UnsupportedOptionalParameter, ParamLengthsInconsistency };

pub fn readOpenMessage(r: *std.Io.Reader) !model.OpenMessage {
    const version = try r.takeInt(u8, .big);
    const as = try r.takeInt(u16, .big);
    const holdTime = try r.takeInt(u16, .big);
    const peerRouterId = try r.takeInt(u32, .big);
    const paramsLength = try r.takeInt(u8, .big);

    var readBytes: u32 = 0;
    while (readBytes < paramsLength) {
        const parameterType = try r.takeInt(u8, .big);
        const parameterValueLength = try r.takeInt(u8, .big);

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
