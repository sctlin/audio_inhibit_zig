const std = @import("std");
const Config = @This();

const IdleBehavior = enum {
    Sleep,
    Idle,
};

const SleepConditions = struct {
    application_names: [][]const u8,
    media_types: [][]const u8,
    media_categories: [][]const u8,
    media_roles: [][]const u8,
};

default_idle_behavior: IdleBehavior = .Idle,
sleep_conditions: SleepConditions = .{
    .application_names = &[_][]const u8{},
    .media_types = &[_][]const u8{},
    .media_categories = &[_][]const u8{},
    .media_roles = &[_][]const u8{},
},

pub fn init(allocator: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, config_file_path: ?[]const u8) !Config {
    var config_file: std.Io.File = undefined;
    if (config_file_path) |path| {
        std.log.info("Loading config from: {s}", .{path});
        config_file = try std.Io.Dir.cwd().openFile(io, path, .{});
    } else {
        // try to load from ${XDG_CONFIG_HOME}/audio_inhibit_zig/config.json
        if (env.get("XDG_CONFIG_HOME")) |xdg_config_home| {
            const path = try std.fmt.allocPrint(allocator, "{s}/audio_inhibit_zig/config.json", .{xdg_config_home});
            defer allocator.free(path);
            std.log.info("Loading config from: {s}", .{path});
            config_file = try std.Io.Dir.cwd().openFile(io, path, .{});
        } else {
            return Config{};
        }
    }

    var reader = config_file.reader(io, &.{});
    const content = try reader.interface.allocRemaining(allocator, .limited(1024 * 1024));
    defer allocator.free(content);
    return try std.json.parseFromSliceLeaky(Config, allocator, content, .{ .allocate = .alloc_always });
}
