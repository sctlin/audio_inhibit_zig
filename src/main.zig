const std = @import("std");
const c = @import("c");
const config = @import("config.zig");
const action = @import("action_handler.zig");
const audio_inhibit_zig = @import("audio_inhibit_zig");
const pwContext = @import("pipewire.zig");
const Io = std.Io;

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
    var output_mode: action.OutputMode = .Idle;
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
            output_mode = .Print;
        } else if (std.mem.eql(u8, args[i], "--waybar")) {
            output_mode = .Waybar;
        }
    }
    if (output_mode == .Idle and try is_running(io)) {
        fatal("Another instance is already running. Exiting.");
    }
    const conf = try config.init(arena, io, init.environ_map, config_file_path);

    const ctx = try pwContext.init(arena, io, conf, output_mode);
    defer ctx.deinit();
    try ctx.runLoop();
}

fn fatal(msg: []const u8) noreturn {
    std.log.err("{s}", .{msg});
    std.process.exit(1);
}
