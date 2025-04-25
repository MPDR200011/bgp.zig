const std = @import("std");
const ip = @import("ip");

const model = @import("../messaging/model.zig");

const Route = model.Route;
const PathAttributes = model.PathAttributes;

const RoutePath = struct {
    advertiser: ?void,

    attrs: PathAttributes,
};

pub const PathMapCtx = struct {
    const Self = @This();

    pub fn hash(_: Self, r: ip.IpAddress) u64 {
        const hashFn = std.hash_map.getAutoHashFn(Route, void);
        return hashFn({}, r);
    }

    pub fn eql(_: Self, r1: ip.IpAddress, r2: ip.IpAddress) bool {
        return r1.equals(r2);
    }
};

const PathMap = std.HashMap(ip.IpAddress, RoutePath, void, std.hash_map.default_max_load_percentage);

const RibEntry = struct {
    const Self = @This();

    route: Route,

    paths: PathMap,
};

pub const RouteMapCtx = struct {
    const Self = @This();

    pub fn hash(_: Self, r: Route) u64 {
        const hashFn = std.hash_map.getAutoHashFn(Route, void);
        return hashFn({}, r);
    }

    pub fn eql(_: Self, r1: Route, r2: Route) bool {
        return (r1.prefixLength == r2.prefixLength) and (std.mem.eql(u8, r1.prefixData, r2.prefixData));
    }
};

const PrefixMap = std.HashMap(Route, RibEntry, RouteMapCtx, std.hash_map.default_max_load_percentage);

pub const Rib = struct {
    const Self = @This();

    mutex: std.Thread.Mutex,

    prefixes: PrefixMap,

    pub fn init(alloc: std.mem.Allocator) Self {
        return Self{
            .mutex = .{},
            .prefixes = .init(alloc),
        };
    }

    pub fn deinit(self: Self) void {
        self.prefixes.deinit();
    }

    pub fn setPath(self: Self, route: Route, path: ip.IpAddress, attrs: PathAttributes) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const ribEntry = self.prefixes.getPtr(route) orelse {
            self.prefixes.put(route, RibEntry{
                .route = route,
            });
            self.prefixes.getPtr(route) orelse unreachable;
        };

        if (ribEntry.paths.get(path)) |routePath| {
            routePath.attrs = attrs;
        } else {
            ribEntry.paths.put(path, RoutePath{
                .advertiser = path,
                .attrs = attrs,
            });
        }
    }

    pub fn removeRoute(self: Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
    }
};
