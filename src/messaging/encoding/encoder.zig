const std = @import("std");
const Allocator = std.mem.Allocator;
const model = @import("../model.zig");
const messageHeader = @import("header.zig");
const openMessage = @import("open.zig");
const notificationMessage = @import("notification.zig");

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

    pub fn writeMessage(self: *Self, msg: model.BgpMessage, messageWriter: std.io.AnyWriter) !void {
        if (msg == .KEEPALIVE) {
            try messageHeader.writeHeader(messageWriter, 0, .KEEPALIVE);
            return;
        }

        var bodyBuffer = std.ArrayList(u8).init(self.allocator);
        // TODO implement message size limits
        defer bodyBuffer.deinit();

        const bodyWriter = bodyBuffer.writer().any();

        switch (msg) {
            .OPEN => |openMsg| {
                try openMessage.writeOpenBody(openMsg, bodyWriter);
            },
            .NOTIFICATION => |notification| {
                try notificationMessage.writeNotification(notification, bodyWriter);
            },
            .KEEPALIVE => unreachable,
            else => return EncodingError.UnsupportedMsgType,
        }

        try messageHeader.writeHeader(messageWriter, @intCast(bodyBuffer.items.len), msg);
        _ = try messageWriter.writeAll(bodyBuffer.items);
    }
};
