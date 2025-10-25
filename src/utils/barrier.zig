//! Simple implementation of a re-settable Thread barrier using the standard
//! library's Futex functions.
const std = @import("std");

const Thread = std.Thread;

pub const Barrier = @This();
const Self = Barrier;

const CLOSED_VALUE: u8 = 1;
const OPEN_VALUE: u8 = 2;

futex: std.atomic.Value(u32),
waitingCount: std.atomic.Value(u32),

pub fn init(closed: bool) Self {
    return .{
        .futex = .init(if (closed) CLOSED_VALUE else OPEN_VALUE),
        .waitingCount = .init(0)
    };
}

// Check if the barrier is closed and block if it is
pub fn wait(self: *const Self) void {
    self.waitingCount.fetchAdd(1, .monotonic);
    std.Thread.Futex.wait(&self.futex, CLOSED_VALUE);
    self.waitingCount.fetchSub(1, .monotonic);
}

// Check if the barrier is closed and block if it is. Returns error if blocked 
// past timeout
pub fn timedWait(self: *const Self, timeout_ns: u64) error{Timeout}!void {
    try std.Thread.Futex.timedWait(&self.futex, CLOSED_VALUE, timeout_ns);
}

// Open barrier and unblock all waiting threads
pub fn open(self: *Self) void {
    self.futex.store(OPEN_VALUE, .monotonic);
    std.Thread.Futex.wake(&self.futex, self.waitingCount.load(.monotonic));
}

// Close the barrier
pub fn close(self: *Self) void {
    self.futex.store(CLOSED_VALUE, .monotonic);
}
