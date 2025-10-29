const std = @import("std");
const model = @import("../model.zig");
const consts = @import("../consts.zig");

const headerReader = @import("header.zig");
const openReader = @import("open.zig");
const notificationReader = @import("notification.zig");
const updateReader = @import("update.zig");

pub const MessageReader = struct {
    const Self = @This();

    allocator: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{
            .allocator = alloc,
        };
    }

    pub fn deinit(_: *Self) void {}

    pub fn deInitMessage(_: *Self, m: model.BgpMessage) void {
        switch (m) {
            .NOTIFICATION => |msg| {
                msg.deinit();
            },
            .UPDATE => |msg| {
                msg.deinit();
            },
            else => {}
        }
    }

    pub fn readMessage(self: *Self, stream: *std.Io.Reader) !model.BgpMessage {
        const messageHeader = try headerReader.readHeader(stream);

        const messageLength = messageHeader.messageLength - consts.HEADER_LENGTH;

        return switch (messageHeader.messageType) {
            .OPEN => .{ .OPEN = try openReader.readOpenMessage(stream)},
            .KEEPALIVE => .{ .KEEPALIVE = .{} },
            .NOTIFICATION => .{ .NOTIFICATION = try notificationReader.readNotificationMessage(stream, messageLength, self.allocator) },
            .UPDATE => .{ .UPDATE = try (updateReader.UpdateMsgParser{
                .allocator = self.allocator,
                .reader = stream
            }).readUpdateMessage(messageLength)
        },
        };

    }
};
