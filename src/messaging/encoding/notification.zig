const std = @import("std");
const consts = @import("../consts.zig");
const model = @import("../model.zig");

fn getErrorSubCodeValue(errorKind: ?model.ErrorKind) u8 {
    if (errorKind == null) {
        return 0;
    }

    return switch(errorKind.?) {
        else => 0,
    };
}

pub fn writeNotification(notification: model.NotificationMessage, writer: *std.Io.Writer) !void {
    try writer.writeInt(u8, @intFromEnum(notification.errorCode), .big);
    try writer.writeInt(u8, getErrorSubCodeValue(notification.errorKind), .big);

    // TODO: notification data
}
