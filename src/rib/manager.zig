const std = @import("std");
const ip = @import("ip");

const rib = @import("table.zig");
const debounced = @import("../utils/debounced.zig");
const model = @import("../messaging/model.zig");

const Allocator = std.mem.Allocator;

const Rib = rib.Rib;

const Route = model.Route;
const PathAttributes = model.PathAttributes;

const Operation = union(enum) {
    add: std.meta.Tuple(&[_]type{*Rib, Route, ip.IpAddress, PathAttributes}),
    remove: std.meta.Tuple(&[_]type{*Rib, Route, ip.IpAddress})
};

const TaskArgs = std.meta.Tuple(&[_]type{*RibManager, Operation});

const RibUpdateTask = debounced.AccumulatingDebouncedTask(TaskArgs);

pub const RibManager = struct {
    const Self = @This();

    allocator: Allocator,
    rib: *Rib,
    updateTask: *RibUpdateTask,

    // subcribers (sessions that need to announce updates)
    // worker (processing updates should be async)

    pub fn init(alloc: Allocator) !Self {
        const targetRib = try alloc.create(Rib);
        errdefer alloc.destroy(targetRib);

        targetRib.* = .init(alloc);
        return Self{
            .allocator = alloc,
            .rib = targetRib,
            .updateTask = try .init(alloc, Self.update, .{.debounceDelay_ms = 2 * std.time.ms_per_s}),
        };
    }

    pub fn deinit(self: Self) Self {
        self.rib.deinit();
        self.allocator.destroy(self.rib);

        self.updateTask.deinit(self.allocator);
    }

    pub fn update(argsList: []TaskArgs) void {
        for (argsList) |args| {
            const self, const op = args;

            switch (op) {
                .add => |addOp| {
                    @call(.auto, Rib.setPath, addOp) catch |err| {
                        // FIXME
                        std.debug.print("RibManager: ERROR RUNNING setPath {}\n", .{err});
                        std.process.abort();
                    };
                    _, _, _, const attrs = addOp;
                    attrs.deinit(self.allocator);
                },
                .remove => |removeOp| {
                    _ = @call(.auto, Rib.removePath, removeOp);
                }
            }
        }

        // Best Path Selection
        
        // Subscriber Notification
    }

    pub fn setPath(self: *Self, route: Route, advertiser: ip.IpAddress, attrs: PathAttributes) !void {
        try self.updateTask.call(.{self, .{.add = .{self.rib, route, advertiser, try attrs.clone(self.allocator)}}});
    }

    pub fn removePath(self: *Self, route: Route, advertiser: ip.IpAddress) !void {
        try self.updateTask.call(.{self, .{.remove = .{self.rib, route, advertiser}}});
    }
};
