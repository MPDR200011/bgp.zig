const std = @import("std");
const Allocator = std.mem.Allocator;
const model = @import("../model.zig");
const messageHeader = @import("header.zig");
const openMessage = @import("open.zig");
const notificationMessage = @import("notification.zig");
const updateMessage = @import("update.zig");

const EncodingError = error{
    UnsupportedMsgType,
};

pub const MessageEncoder = struct {
    allocator: Allocator,

    const Self = @This();

    pub fn init(allocator: Allocator) MessageEncoder {
        return .{ .allocator = allocator };
    }

    pub fn deinit(_: Self) void {}

    pub fn writeMessage(_: *Self, msg: model.BgpMessage, messageWriter: *std.Io.Writer) !void {
        switch (msg) {
            .OPEN => |openMsg| {
                try openMessage.writeOpenBody(openMsg, messageWriter);
            },
            .NOTIFICATION => |notification| {
                try notificationMessage.writeNotification(notification, messageWriter);
            },
            .UPDATE => |update| {
                try updateMessage.writeUpdateBody(update, messageWriter);
            },
            .KEEPALIVE => {},
        }

        try messageWriter.flush();
    }
};
