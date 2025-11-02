const std = @import("std");
const model = @import("../model.zig");

const OpenEncondingError = error{
    UnsupportedParameter,
};

fn writeParameters(parameters: []model.Parameter) !void {
    for (parameters) |parameter| {
        switch (parameter) {
            //else => return OpenEncondingError.UnsupportedParameter,
        }
    }
}

pub fn writeOpenBody(msg: model.OpenMessage, writer: *std.Io.Writer) !void {
    try writer.writeInt(u8, msg.version, .big);
    try writer.writeInt(u16, msg.asNumber, .big);
    try writer.writeInt(u16, msg.holdTime, .big);
    try writer.writeInt(u32, msg.peerRouterId, .big);

    if (msg.parameters) |parameters| {
        try writer.writeInt(u8, @intCast(parameters.len), .big);
        try writeParameters(parameters);
    } else {
        try writer.writeInt(u8, 0, .big);
    }
}
