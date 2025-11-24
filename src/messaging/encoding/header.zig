const std = @import("std");
const consts = @import("../consts.zig");
const model = @import("../model.zig");

pub fn writeHeader(writer: *std.io.Writer, msgBodyLength: u16, msgType: model.BgpMessageType) !void {
    inline for (0..consts.MARKER_LENGTH) |_| {
        try writer.writeByte(0xff);
    }
    try writer.writeInt(u16, consts.HEADER_LENGTH + msgBodyLength, .big);
    try writer.writeInt(u8, @intFromEnum(msgType), .big);
}
