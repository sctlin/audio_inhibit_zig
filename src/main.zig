const std = @import("std");
const Io = std.Io;
const Config = @import("config.zig");
const res = @import("resolver.zig");

const c = @import("c");
const audio_inhibit_zig = @import("audio_inhibit_zig");
const pwContext = @import("pipewire.zig");

const lockfile = "/tmp/audio_inhibit_zig.lock";
fn is_running(io: std.Io) !bool {
    _ = std.Io.Dir.createFileAbsolute(io, lockfile, .{
        .read = true,
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
    }) catch |err| {
        switch (err) {
            std.Io.File.OpenError.WouldBlock => {
                return true;
            },
            else => {
                std.log.err("Failed to create lock file: {}\n", .{err});
                return error.FailedToCreateLockFile;
            },
        }
    };
    return false;
}

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();

    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    var i: usize = 0;
    var resolve_target: res.ResolveTarget = .Idle;
    var config_file_path: ?[]const u8 = null;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--config")) {
            if (i + 1 < args.len) {
                config_file_path = args[i + 1];
                i += 1; // Skip the next argument since it's the config file path
            } else {
                fatal("Expected a file path after --config, but none was provided.");
            }
        } else if (std.mem.eql(u8, args[i], "--dry-run")) {
            resolve_target = .Print;
        } else if (std.mem.eql(u8, args[i], "--waybar")) {
            resolve_target = .Waybar;
        }
    }
    if (resolve_target == .Idle and try is_running(io)) {
        var stderr_writer = std.Io.File.stderr().writer(io, &.{});
        stderr_writer.interface.writeAll("Another instance is already running. Exiting.\n") catch {};
        return error.AlreadyRunning;
    }
    const config = try Config.init(arena, io, init.environ_map, config_file_path);

    const ctx = try pwContext.init(arena, io, config, resolve_target);
    defer ctx.deinit();
    try ctx.runLoop();
}

fn fatal(msg: []const u8) noreturn {
    std.log.err("{s}", .{msg});
    std.process.exit(1);
}
