const std = @import("std");
const model = @import("../model.zig");
const consts = @import("../consts.zig");

const headerReader = @import("header.zig");
const openReader = @import("open.zig");
const notificationReader = @import("notification.zig");
const updateReader = @import("update.zig");

pub const MessageReader = struct {
    const Self = @This();

    reader: std.io.AnyReader,
    allocator: std.mem.Allocator,

    pub fn init(reader: std.io.AnyReader, alloc: std.mem.Allocator) Self {
        return .{
            .reader = reader,
            .allocator = alloc,
        };
    }

    pub fn deinit(_: *Self) void {}

    pub fn deInitMessage(_: *Self, m: model.BgpMessage) void {
        switch (m) {
            .NOTIFICATION => |msg| {
                msg.deinit();
            },
            else => {}
        }
    }

    pub fn readMessage(self: *Self) !model.BgpMessage {
        const messageHeader = try headerReader.readHeader(self.reader);

        const messageLength = messageHeader.messageLength - consts.HEADER_LENGTH;

        return switch (messageHeader.messageType) {
            .OPEN => .{ .OPEN = try openReader.readOpenMessage(self.reader)},
            .KEEPALIVE => .{ .KEEPALIVE = .{} },
            .NOTIFICATION => .{ .NOTIFICATION = try notificationReader.readNotificationMessage(self.reader, messageLength, self.allocator) },
            .UPDATE => .{ .UPDATE = try (updateReader.UpdateMsgParser{
                .allocator = self.allocator,
                .reader = self.reader
            }).readUpdateMessage(messageLength)
        },
        };

    }
};
