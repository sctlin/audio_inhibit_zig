const std = @import("std");
const pipewire_c = @import("pipewire_c");
const systemd_c = @import("systemd_c");

pub const IdleTarget = enum {
    None,
    Sleep,
    Idle,

    pub fn str(self: IdleTarget) []const u8 {
        return switch (self) {
            .None => "none",
            .Sleep => "sleep",
            .Idle => "idle",
        };
    }

    pub fn mostRestrictive(self: IdleTarget, other: IdleTarget) IdleTarget {
        return switch (self) {
            .None => other,
            .Sleep => if (other == .Idle) .Idle else .Sleep,
            .Idle => .Idle,
        };
    }
};

pub const IdleManager = struct {
    io: std.Io,

    bus: ?*systemd_c.sd_bus = null,
    fd: i32 = -1,

    fn connect_to_bus(self: *IdleManager) !void {
        if (self.bus != null) {
            _ = systemd_c.sd_bus_flush_close_unref(self.bus);
            self.bus = null;
        }
        const ret = systemd_c.sd_bus_default_system(&self.bus);
        if (ret < 0) {
            std.log.err("Failed to connect to system bus: {s}", .{pipewire_c.strerror(-ret)});
            self.bus = null;
            return error.FailedToConnect;
        }
    }

    fn release(self: *IdleManager) void {
        std.log.info("Releasing inhibition", .{});
        if (self.fd >= 0) {
            const ret = std.os.linux.close(self.fd);
            const errno = std.os.linux.errno(ret);
            switch (errno) {
                .SUCCESS => {},
                else => {
                    std.log.err("Failed to close file descriptor: {}\n", .{errno});
                },
            }
            self.fd = -1;
        }
    }

    fn inhibit(self: *IdleManager, what: []const u8) !void {
        std.log.info("Inhibiting {s}", .{what});
        if (self.bus == null) {
            self.connect_to_bus() catch |err| {
                std.log.err("Failed to connect to system bus: {}", .{err});
                return;
            };
        }
        if (self.fd >= 0) {
            std.log.info("Releasing previous inhibition before applying new one", .{});
            self.release();
        }
        var msg: ?*systemd_c.sd_bus_message = null;
        const err: ?*systemd_c.sd_bus_error = null;
        const what_ptr: [*c]const u8 = what.ptr;
        var ret = systemd_c.sd_bus_call_method(self.bus.?, "org.freedesktop.login1", "/org/freedesktop/login1", "org.freedesktop.login1.Manager", "Inhibit", err, &msg, "ssss", what_ptr, "audio_inhibit_zig", "Audio is playing", "block");
        if (ret < 0) {
            if (err) |e| {
                std.log.err("Failed to call Inhibit method, got error {s}: {s}\n", .{ e.name, e.message });
                systemd_c.sd_bus_error_free(err);
            } else {
                std.log.err("Failed to call Inhibit method, got error: {s}\n", .{pipewire_c.strerror(-ret)});
            }
            self.connect_to_bus() catch |connect_err| {
                std.log.err("Failed to reconnect to system bus: {}\n", .{connect_err});
            };
            return error.FailedToInhibit;
        }
        ret = systemd_c.sd_bus_message_read(msg, "h", &self.fd);
        if (ret < 0) {
            std.log.err("Failed to read file descriptor from Inhibit method: {s}\n", .{pipewire_c.strerror(-ret)});
            _ = systemd_c.sd_bus_message_unref(msg);
            return error.FailedToInhibit;
        }
        const min_fd: usize = 3; // Minimum file descriptor number to avoid stdin, stdout, stderr
        self.fd = std.c.fcntl(self.fd, systemd_c.F_DUPFD_CLOEXEC, min_fd);
        if (self.fd < 0) {
            std.log.err("Failed to duplicate file descriptor\n", .{});
        }
        systemd_c.sd_bus_error_free(err);
        _ = systemd_c.sd_bus_message_unref(msg);
    }

    pub fn update(self: *IdleManager, target: IdleTarget) void {
        switch (target) {
            .None => self.release(),
            .Sleep => self.inhibit("sleep") catch |err| {
                std.log.err("Failed to inhibit sleep: {}\n", .{err});
            },
            .Idle => self.inhibit("idle") catch |err| {
                std.log.err("Failed to inhibit idle: {}\n", .{err});
            },
        }
    }

    pub fn init(io: std.Io) !IdleManager {
        var idle_manager = IdleManager{ .io = io };
        idle_manager.connect_to_bus() catch |err| {
            std.log.err("Failed to connect to system bus: {}\n", .{err});
            return err;
        };
        return idle_manager;
    }

    pub fn deinit(self: *IdleManager) void {
        if (self.bus) |bus| {
            self.release();
            _ = systemd_c.sd_bus_flush_close_unref(bus);
            self.bus = null;
        }
    }
};
