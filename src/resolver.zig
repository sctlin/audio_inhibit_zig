const std = @import("std");
const idle = @import("idle.zig");
const pipewire = @import("pipewire.zig");

pub const Resolver = @This();

pub const ResolveTarget = enum {
    Print,
    Waybar,
    Idle,
};

io: std.Io,
target: ResolveTarget,
idle_target: idle.IdleTarget = .None,
idle_manager: ?idle.IdleManager = null,
lines_printed: usize = 0,

pub fn init(io: std.Io, target: ResolveTarget) !Resolver {
    var resolver = Resolver{
        .io = io,
        .target = target,
    };
    switch (target) {
        .Idle => {
            resolver.idle_manager = try idle.IdleManager.init(io);
        },
        else => {},
    }
    return resolver;
}

pub fn deinit(self: Resolver) void {
    switch (self.target) {
        .Print => {},
        .Waybar => {},
        .Idle => {
            self.idle_manager.?.deinit();
        },
    }
}

fn clear_lines(self: *Resolver, writer: *std.Io.Writer) !void {
    if (self.lines_printed > 0) {
        for (0..self.lines_printed) |_| {
            try writer.writeAll("\x1b[1A\x1b[2K");
        }
        self.lines_printed = 0;
    }
}
fn print(self: *Resolver, io: std.Io, target: idle.IdleTarget, apps: AppActivityList) !void {
    var writer = std.Io.File.stdout().writer(io, &.{});
    try self.clear_lines(&writer.interface);
    if (target == .None) {
        try writer.interface.writeAll("Inhibition released\n");
    } else {
        try writer.interface.writeAll("Inhibiting ");
        try writer.interface.writeAll(target.str());
        try writer.interface.writeAll("\n");
    }
    for (apps.items) |app| {
        try writer.interface.writeAll("  - ");
        try writer.interface.writeAll(app.name);
        if (app.sink) {
            try writer.interface.writeAll(" (sink)");
        }
        if (app.source) {
            try writer.interface.writeAll(" (source)");
        }
        try writer.interface.writeAll(" -> ");
        try writer.interface.writeAll(app.idle_target.str());
        try writer.interface.writeAll("\n");
    }
    try writer.interface.flush();
    self.lines_printed = 1 + apps.items.len;
}

fn print_waybar(io: std.Io, target: idle.IdleTarget) !void {
    var writer = std.Io.File.stdout().writer(io, &.{});
    const target_str = target.str();
    try writer.interface.writeAll("{\"text\": \"\", \"alt\": \"");
    try writer.interface.writeAll(target_str);
    try writer.interface.writeAll("\", \"tooltip\": \"\", \"class\": \"");
    try writer.interface.writeAll(target_str);
    try writer.interface.writeAll("\"}\n");
    try writer.interface.flush();
}

pub const AppActivity = struct {
    name: []const u8,

    sink: bool,
    source: bool,

    idle_target: idle.IdleTarget,
};

pub const AppActivityList = std.ArrayList(AppActivity);
pub fn update(
    self: *Resolver,
    new_target: idle.IdleTarget,
    apps: AppActivityList,
) void {
    switch (self.target) {
        .Print => {
            self.print(self.io, new_target, apps) catch |err| {
                std.log.err("Failed to print inhibition status: {}\n", .{err});
            };
        },
        .Waybar => {
            if (self.idle_target != new_target) {
                print_waybar(self.io, new_target) catch |err| {
                    std.log.err("Failed to print inhibition status for Waybar: {}\n", .{err});
                };
            }
        },
        .Idle => {
            if (self.idle_target != new_target) {
                self.idle_manager.?.update(new_target);
            }
        },
    }
    self.idle_target = new_target;
}
