const std = @import("std");
const model = @import("../model.zig");

const NotificationParsingError = error{ InvalidErrorSubCode, DataLengthMismatch };

pub fn getErrorKindFromMessageValue(errorCode: model.ErrorCode, msgValue: u8) !model.ErrorKind {
    switch(errorCode) {
        .HeaderError => {
            return switch(msgValue) {
                1 => model.ErrorKind.ConnectionNotSynchronized,
                2 => model.ErrorKind.BadMessageLength,
                3 => model.ErrorKind.BadMessageType,
                else => NotificationParsingError.InvalidErrorSubCode,
            };
        },
        .OpenMessageError => {
            return switch(msgValue) {
                1 => model.ErrorKind.UnsupportedVersionNumber,
                2 => model.ErrorKind.BadPeerAS,
                3 => model.ErrorKind.BadBGPIdentifier,
                4 => model.ErrorKind.UnsupportedOptionalParameter,
                6 => model.ErrorKind.UnacceptableHoldTime,
                else => NotificationParsingError.InvalidErrorSubCode,
            };
        },
        .UpdateMessageError => {
            return switch (msgValue) {
                1 => model.ErrorKind.MalformedAttributeList,
                2 => model.ErrorKind.UnrecognizedWellKnownAttribute,
                3 => model.ErrorKind.MissingWellKnownAttribute,
                4 => model.ErrorKind.AttributeFlagsError,
                5 => model.ErrorKind.AttributeLengthError,
                6 => model.ErrorKind.InvalidORIGINAttribute,
                8 => model.ErrorKind.InvalidNEXT_HOPAttribute,
                9 => model.ErrorKind.OptionalAttributeError,
                10 => model.ErrorKind.InvalidNetworkField,
                11 => model.ErrorKind.MalformedAS_PATH,
                else => NotificationParsingError.InvalidErrorSubCode,
            };
        },
        else => return model.ErrorKind.Default
    }
}

pub fn readNotificationMessage(r: std.io.AnyReader, dataLength: usize, allocator: std.mem.Allocator) !model.NotificationMessage {
    const errorCode: model.ErrorCode = @enumFromInt(try r.readInt(u8, .big));
    const errorSubCode = try r.readInt(u8, .big);

    const msg: model.NotificationMessage = try .init(errorCode, try getErrorKindFromMessageValue(errorCode, errorSubCode), dataLength, allocator);
    if (dataLength > 0) {
        std.debug.assert(msg.data != null);
        const readBytes = try r.readAll(msg.data.?);
        if (readBytes != dataLength) {
            return NotificationParsingError.DataLengthMismatch;
        }
    }

    return msg;
}
