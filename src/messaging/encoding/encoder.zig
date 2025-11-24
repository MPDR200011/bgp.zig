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

    pub fn writeMessage(self: *Self, msg: model.BgpMessage, messageWriter: *std.io.Writer) !void {
        // TODO implement message size limits

        // TODO decide if I want to allocate a buffer everytime or just get a
        // pre-allocated one, or even pre-calculate the message length
        var bodyBuffer = std.array_list.Managed(u8).init(self.allocator);
        defer bodyBuffer.deinit();

        var bodyWriter = bodyBuffer.writer().adaptToNewApi(&[0]u8{});
        const bodyWriterItf = &bodyWriter.new_interface;

        switch (msg) {
            .OPEN => |openMsg| {
                try openMessage.writeOpenBody(openMsg, bodyWriterItf);
            },
            .NOTIFICATION => |notification| {
                try notificationMessage.writeNotification(notification, bodyWriterItf);
            },
            .UPDATE => |update| {
                try updateMessage.writeUpdateBody(update, bodyWriterItf);
            },
            .KEEPALIVE => {},
        }

        // FIXME: We might want to put an ultimate "write limit" to prevent 
        // messages that are to large from being sent
        try messageHeader.writeHeader(messageWriter, @intCast(bodyBuffer.items.len), msg);
        _ = try messageWriter.writeAll(bodyBuffer.items);

        try messageWriter.flush();
    }
};
