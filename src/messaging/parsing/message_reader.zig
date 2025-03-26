const std = @import("std");
const model = @import("../model.zig");
const consts = @import("../consts.zig");

const headerReader = @import("header.zig");
const openReader = @import("open.zig");
const notificationReader = @import("notification.zig");

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

        return switch (messageHeader.messageType) {
            .OPEN => .{ .OPEN = try openReader.readOpenMessage(self.reader)},
            .KEEPALIVE => .{ .KEEPALIVE = .{} },
            .NOTIFICATION => .{ .NOTIFICATION = try notificationReader.readNotificationMessage(self.reader, messageHeader.messageLength - consts.HEADER_LENGTH - 2, self.allocator) },
            .UPDATE => .{ .KEEPALIVE = .{} },
        };

    }
};
