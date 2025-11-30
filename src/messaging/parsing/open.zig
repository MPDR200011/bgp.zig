const std = @import("std");
const model = @import("../model.zig");

const OpenParsingError = error{ UnsupportedOptionalParameter, ParamLengthsInconsistency };

pub fn readOpenMessage(r: *std.Io.Reader) !model.OpenMessage {
    const version = try r.takeInt(u8, .big);
    const as = try r.takeInt(u16, .big);
    const holdTime = try r.takeInt(u16, .big);
    const peerRouterId = try r.takeInt(u32, .big);
    const paramsLength = try r.takeInt(u8, .big);

    std.log.debug("Open Msg(Version={}, AS={}, hold={}, bodyLen={})", .{version, as, holdTime, paramsLength});

    var readBytes: u32 = 0;
    while (readBytes < paramsLength) {
        const parameterType = try r.takeInt(u8, .big);
        const parameterValueLength = try r.takeInt(u8, .big);

        std.log.debug("Open Msg Param(type={}, valueLen={}, readBytes={})", .{parameterType, parameterValueLength, readBytes});

        switch (parameterType) {
            else => {},
        }

        try r.discardAll(parameterValueLength);
        readBytes += parameterValueLength + 2;
    }

    std.log.debug("Open Msg(readBytes={})", .{readBytes});

    if (readBytes != paramsLength) {
        return OpenParsingError.ParamLengthsInconsistency;
    }

    return .{ .version = version, .asNumber = as, .holdTime = holdTime, .peerRouterId = peerRouterId, .parameters = null };
}
