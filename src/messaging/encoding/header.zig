const std = @import("std");
const consts = @import("../consts.zig");
const model = @import("../model.zig");

pub fn writeHeader(writer: std.io.AnyWriter, msgLength: u16, msgType: model.BgpMessageType) !void {
    try writer.writeByteNTimes(0xff, consts.MARKER_LENGTH);
    try writer.writeInt(u16, msgLength, .big);
    try writer.writeInt(u8, @intFromEnum(msgType), .big);
}
