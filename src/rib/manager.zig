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
    add: std.meta.Tuple([_]type{Route, ip.IpAddress, PathAttributes}),
    remove: std.meta.Tuple([_]type{Route, ip.IpAddress})
};

const TaskArgs = std.meta.Tuple([_]type{*RibManager, Operation});

const RibUpdateTask = debounced.AccumulatingDebouncedTask(TaskArgs);

pub const RibManager = struct {
    const Self = @This();

    allocator: Allocator,
    rib: Rib,
    updateTask: RibUpdateTask,

    // subcribers (sessions that need to announce updates)
    // worker (processing updates should be async)

    pub fn init(alloc: Allocator) Self {
        return Self{
            .allocator = alloc,
            .rib = .init(alloc),
            .updateTask = .init(alloc, Self.update, .{}),
        };
    }

    pub fn deinit(self: Self) Self {
        self.rib.deinit();
    }

    pub fn update(argsList: []TaskArgs) void {
        for (argsList) |args| {
            const self, const op = args;

            switch (op) {
                .add => |addOp| {
                    @call(.auto, self.rib.setPath, addOp);
                    _, _, const attrs = addOp;
                    attrs.deinit();
                },
                .remove => |removeOp| {
                    @call(.auto, self.rib.removePath, removeOp);
                }
            }
        }

        // Best Path Selection
        
        // Subscriber Notification
    }

    pub fn setPath(self: *Self, route: Route, advertiser: ip.IpAddress, attrs: PathAttributes) !void {
        self.updateTask.call(.{self, .{.add = .{route, advertiser, attrs.clone(self.allocator)}}});
    }

    pub fn removePath(self: *Self, route: Route, advertiser: ip.IpAddress) bool {
        self.updateTask.call(.{self, .{.remove = .{route, advertiser}}});
    }
};
