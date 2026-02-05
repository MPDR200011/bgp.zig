const std = @import("std");
const ip = @import("ip");
const xev = @import("xev");

const adjRib = @import("adj_rib.zig");
const debounced = @import("../utils/debounced.zig");
const model = @import("../messaging/model.zig");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;

const AdjRib = adjRib.AdjRib;
const Advertiser = common.Advertiser;

const Route = model.Route;
const PathAttributes = model.PathAttributes;

const TaskCounter = common.TaskCounter;

pub const AdjRibInManager = struct {
    const Self = @This();

    allocator: Allocator,
    ribMutex: std.Thread.Mutex,

    neighbor: ip.IpAddress,

    adjRib: AdjRib,

    pub fn init(alloc: Allocator, neighbor: ip.IpAddress) !Self {
        return Self{
            .allocator = alloc,
            .ribMutex = .{},
            .neighbor = neighbor,
            .adjRib = .init(alloc),
        };
    }

    pub fn deinit(self: *Self) void {
        self.ribMutex.lock();
        defer self.ribMutex.unlock();

        self.adjRib.deinit();
    }

    pub fn setPath(self: *Self, route: Route, attrs: PathAttributes) !void {
        self.ribMutex.lock();
        defer self.ribMutex.unlock();

        try self.adjRib.setPath(route, .{ .neighbor = self.neighbor }, attrs);
    }

    pub fn removePath(self: *Self, route: Route) void {
        self.ribMutex.lock();
        defer self.ribMutex.unlock();

        self.adjRib.removePath(route);
    }
};

pub const AdjRibOutManager = struct {
    const Self = @This();

    allocator: Allocator,
    ribMutex: std.Thread.Mutex,

    neighbor: ip.IpAddress,

    adjRib: AdjRib,

    pub fn init(alloc: Allocator, neighbor: ip.IpAddress) !Self {
        return Self{
            .allocator = alloc,
            .ribMutex = .{},
            .neighbor = neighbor,
            .adjRib = .init(alloc),
        };
    }

    pub fn deinit(self: *Self) void {
        self.ribMutex.lock();
        defer self.ribMutex.unlock();

        self.adjRib.deinit();
    }

    pub fn setPath(self: *Self, route: Route, advertiser: Advertiser, attrs: PathAttributes) !void {
        self.ribMutex.lock();
        defer self.ribMutex.unlock();

        try self.adjRib.setPath(route, advertiser, attrs);
    }

    pub fn removePath(self: *Self, route: Route) void {
        self.ribMutex.lock();
        defer self.ribMutex.unlock();

        self.adjRib.removePath(route);
    }
};
