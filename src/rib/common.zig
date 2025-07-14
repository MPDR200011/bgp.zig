const std = @import("std");
const ip = @import("ip");

const model = @import("../messaging/model.zig");

const Allocator = std.mem.Allocator;

const PathAttributes = model.PathAttributes;
const Route = model.Route;

pub const RoutePath = struct {
    const Self = @This();

    advertiser: ?ip.IpAddress,

    attrs: PathAttributes,

    pub fn deinit(self: Self) void {
        self.attrs.deinit();
    }
};

pub const RouteHashFns = struct {
    const Self = @This();

    pub fn hash(_: Self, r: Route) u64 {
        const hashFn = std.hash_map.getAutoHashFn(Route, void);
        return hashFn({}, r);
    }

    pub fn eql(_: Self, r1: Route, r2: Route) bool {
        return (r1.prefixLength == r2.prefixLength) and (std.mem.eql(u8, &r1.prefixData, &r2.prefixData));
    }
};


pub const TaskCounter = struct {
    const Self = @This();

    taskCountMutex: std.Thread.Mutex,
    taskCountCond: std.Thread.Condition,
    inFlightTaskCount: u32,
    shutdown: bool,

    pub const default: Self = .{
        .taskCountMutex = .{},
        .taskCountCond = .{},
        .inFlightTaskCount = 0,
        .shutdown = false,
    };

    pub fn incrementTasks(self: *Self) void {
        self.taskCountMutex.lock();
        defer self.taskCountMutex.unlock();

        std.debug.assert(!self.shutdown);

        self.inFlightTaskCount += 1;
    }

    pub fn decrementTasks(self: *Self) void {
        self.taskCountMutex.lock();
        defer self.taskCountMutex.unlock();

        std.debug.assert(self.inFlightTaskCount > 0);

        self.inFlightTaskCount -= 1;

        self.taskCountCond.signal();
    }

    pub fn waitForDrainAndShutdown(self: *Self) void {
        self.taskCountMutex.lock();
        defer self.taskCountMutex.unlock();

        while (self.inFlightTaskCount > 0) {
            self.taskCountCond.wait(&self.taskCountMutex);
        }
        self.shutdown = true;
    }
};
