const std = @import("std");
const builtin = @import("builtin");
const net = std.net;
const posix = std.posix;
const process = std.process;
const clap = @import("clap");
const ip = @import("ip");
const zul = @import("zul");
const xev = @import("xev");

const Allocator = std.mem.Allocator;

const config = @import("config/json.zig");

const session = @import("sessions/session.zig");
const connections = @import("sessions/connections.zig");

const model = @import("messaging/model.zig");
const headerReader = @import("messaging/parsing/header.zig");
const openReader = @import("messaging/parsing/open.zig");
const bgpEncoding = @import("messaging/encoding/encoder.zig");

const Server = @import("accepter.zig");
const PeerMap = @import("peer_map.zig").PeerMap;

const v4PeerSessionAddresses = session.v4PeerSessionAddresses;
const Peer = session.Peer;

const ribManager = @import("rib/main_rib_manager.zig");

const Barrier = @import("utils/barrier.zig");

pub const std_options: std.Options = .{
    // Set the log level to info
    .log_level = .debug,

    // Define logFn to override the std implementation
    .logFn = myLogFn,
};

pub var shutdownBarrier: Barrier = .init(true);

pub fn getStdErrWriter() *std.Io.Writer {
    const S = struct {
        var stdErrBuffer: [1024]u8 = undefined;
        var writer: ?std.fs.File.Writer = null;
        var interface: ?*std.Io.Writer = null;
    };

    if (S.interface) |i| {
        return i;
    }

    S.writer = std.fs.File.stderr().writer(&S.stdErrBuffer);
    S.interface = &S.writer.?.interface;
    return S.interface.?;
}

pub fn myLogFn(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    // Ignore all non-error logging from sources other than
    // .my_project, .nice_library and the default
    const scope_prefix = "(" ++ @tagName(scope) ++ "): ";

    comptime var upperLevel = [_]u8{0};
    comptime _ = std.ascii.upperString(&upperLevel, level.asText()[0..1]);
    const prefix = comptime upperLevel ++ " " ++ scope_prefix;

    // Print the message to stderr, silently ignoring any errors
    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();
    var stderr = getStdErrWriter();
    stderr.print(prefix ++ format ++ "\n", args) catch return;
    stderr.flush() catch return;
}


pub fn main() !void {
    std.log.info("Hello World!", .{});
    std.log.info("Initializing BGP Listener", .{});

    // Initializing GPA for the process
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const gpa, const is_debug = gpa: {
        if (builtin.os.tag == .wasi) {
            break :gpa .{ std.heap.wasm_allocator, false };
        }

        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };
    defer if (is_debug) {
        switch (debug_allocator.deinit()) {
            .leak => std.debug.print("UNFREE'D MEMORY DETECTED!!!! CHECK YOUR ALLOCS!!! >:(\n", .{}),
            .ok => std.debug.print("No memory leaks detected :)\n", .{}),
        }
    };

    const params = comptime clap.parseParamsComptime(
        \\-h, --help     Display this help and exit.
        \\-c, --config  <str>   Configuration path
    );

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
        .allocator = gpa,
    }) catch |err| {
        // Report useful error and exit.
        const stderr = getStdErrWriter();
        diag.report(stderr, err) catch {};
        return err;
    };
    defer res.deinit();

    const configPath = res.args.config orelse {
        std.log.err("Missing configuration filepath!!!", .{});
        std.process.abort();
    };

    const managedProcessConfig = try config.loadConfig(gpa, configPath);
    defer managedProcessConfig.deinit();

    const processConfig = managedProcessConfig.value;
    const localPort = processConfig.localConfig.localPort orelse 179;

    _ = try ribManager.RibManager.init(gpa);

    std.log.info("Initializing peer map", .{});

    var peerMap = PeerMap.init(gpa);
    defer {
        var it = peerMap.valueIterator();
        while (it.next()) |peer| {
            peer.*.deinit();
            gpa.destroy(peer.*);
        }
        peerMap.deinit();
    }

    for (processConfig.peers) |peerConfig| {
        const peeringMode: session.Mode = modeBlock: {
            if (std.mem.eql(u8, peerConfig.peeringMode, "PASSIVE")) {
                break :modeBlock .PASSIVE;
            } else if (std.mem.eql(u8, peerConfig.peeringMode, "ACTIVE")) {
                break :modeBlock .ACTIVE;
            } else  {
                std.log.err("Invalid Peering Mode: {s}", .{peerConfig.peeringMode});
                std.process.abort();
            }
        };

        const delayOpenAmount = peerConfig.delayOpen_s orelse 0;

        const peer = try gpa.create(Peer);
        peer.* = session.Peer.init(.{
            .localAsn = processConfig.localConfig.asn,
            .holdTime = 15,
            .localRouterId = processConfig.localConfig.routerId,
            .peeringMode = peeringMode,
            .delayOpen = delayOpenAmount > 0,
            .delayOpen_ms = delayOpenAmount * std.time.ms_per_s,
            .sessionAddresses = .{
                .localAddress = try .parse(peerConfig.localAddress),
                .peerAddress = try .parse(peerConfig.peerAddress),
            },
            .sessionPorts = .{
                .localPort = localPort,
                .peerPort = peerConfig.peerPort orelse 179,
            },
            }, peer, gpa) catch |err| {
            std.log.err("Failed to initialize peer memory: {}", .{err});
            return err;
        };

        try peerMap.put(peer.sessionAddresses, peer);
    }

    std.log.info("Starting peer state machines", .{});

    var it = peerMap.valueIterator();
    while (it.next()) |peer| {
        peer.*.session.submitEvent(.{ .Start = {} }) catch |err| {
            std.log.err("Error submitting start event: {}\n", .{err});
            return err;
        };
    }

    std.log.debug("Registering signals", .{});

    const sigHandler = std.posix.Sigaction{
        .handler = .{ 
            .handler = struct { 
                pub fn handler(sig: i32) callconv(.c) void {
                    std.log.info("Received signal {}", .{sig});
                    shutdownBarrier.open();
                }
            }.handler
        },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };

    std.posix.sigaction(std.posix.SIG.INT, &sigHandler, null);
    std.posix.sigaction(std.posix.SIG.TERM, &sigHandler, null);
    std.posix.sigaction(std.posix.SIG.ABRT, &sigHandler, null);

    std.log.debug("Registered signals", .{});

    var server = Server.init(gpa, localPort, &processConfig) catch |err| {
        std.log.err("Error initializing server {}", .{err});
        return err;
    };
    var serverThread = server.start(&peerMap) catch |err| {
        std.log.err("Error starting server {}", .{err});
        return err;
    };

    std.log.info("Waiting for shutdown signal", .{});
    shutdownBarrier.wait();
    std.log.info("Shutdown initiated", .{});

    // Shutdown checklist
    // 1 - Stop accepting more connections
    std.log.info("Shutting down server", .{});
    server.stop() catch |err| {
        std.log.err("Error shutting down server {}", .{err});
        std.process.abort();
    };
    serverThread.join();
    std.log.info("Server shutdown", .{});

    // 2 - Shutdown all sessions
}

test {
 _ =   @import("messaging/parsing/update.zig");
 _ =   @import("messaging/encoding/update.zig");
 _ =   @import("rib/main_rib.zig");
 _ =   @import("rib/adj_rib.zig");
}
