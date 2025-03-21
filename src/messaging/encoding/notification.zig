const std = @import("std");
const consts = @import("../consts.zig");
const model = @import("../model.zig");

fn getErrorSubCodeValue(errorKind: model.ErrorKind) u8 {
    return switch(errorKind) {
    };
}

pub fn writeNotification(notification: model.NotificationMessage, writer: std.io.AnyWriter) !void {
    try writer.writeInt(u8, @intFromEnum(notification.errorCode), .big);
    try writer.writeInt(u8, getErrorSubCodeValue(notification.errorKind), .big);

    // TODO: notification data
}
