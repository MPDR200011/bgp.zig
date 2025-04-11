const std = @import("std");
const sessionLib = @import("../session.zig");
const model = @import("../../messaging/model.zig");

const Session = sessionLib.Session;

pub fn getNegotiatedHoldTimer(session: *Session, msgHoldTimer: u16) u64 {
    const peer = session.parent;
    return @min(@as(u64, @intCast(peer.holdTime)), @as(u64, @intCast(msgHoldTimer))) * std.time.ms_per_s;
}
