const std = @import("std");
const model = @import("../model.zig");
const messageHeader = @import("header.zig");
const openMessage = @import("open.zig");

const EncodingError = error{
    UnsupportedMsgType,
};

pub const MessageEncoder = struct {
    pub fn init() MessageEncoder {
        return .{};
    }

    pub fn deinit() void {}

    pub fn writeMessage(comptime _: MessageEncoder, msg: model.BgpMessage, messageWriter: std.io.AnyWriter) !void {
        var bodyBuffer = std.ArrayList(u8).init(std.heap.page_allocator);
        defer bodyBuffer.deinit();

        const bodyWriter = bodyBuffer.writer().any();

        switch (msg) {
            .OPEN => {
                try openMessage.writeOpenBody(msg.OPEN, bodyWriter);
            },
            else => return EncodingError.UnsupportedMsgType,
        }

        try messageHeader.writeHeader(messageWriter, @intCast(bodyBuffer.items.len), msg);
    }
};
