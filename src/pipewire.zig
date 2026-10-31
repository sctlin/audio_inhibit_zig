const pipewire_c = @import("pipewire_c");
const systemd_c = @import("systemd_c");
const std = @import("std");
const Config = @import("config.zig");
const idle = @import("idle.zig");
const action = @import("action_handler.zig");

const PwContext = @This();

io: std.Io,
allocator: std.mem.Allocator,
config: Config,

action_handler: action.ActionHandler,

registry: *pipewire_c.struct_pw_registry = undefined,
registry_listener: *pipewire_c.struct_spa_hook = undefined,
core: *pipewire_c.struct_pw_core = undefined,
core_listener: *pipewire_c.struct_spa_hook = undefined,
context: *pipewire_c.struct_pw_context = undefined,
loop: *pipewire_c.struct_pw_main_loop = undefined,
pending_sync: i64 = -1,

nodes: std.AutoHashMap(u32, *Node),

fn sliceContains(haystack: [][]const u8, needle: []const u8) bool {
    for (haystack) |item| {
        if (std.mem.eql(u8, item, needle)) {
            return true;
        }
    }
    return false;
}

fn idleTargetFromNode(node: *Node, config: Config) idle.IdleTarget {
    if (node.application_name) |app| {
        if (sliceContains(config.sleep_conditions.application_names, app)) {
            return .Sleep;
        }
    }
    if (node.media_type) |media_type| {
        if (sliceContains(config.sleep_conditions.media_types, media_type)) {
            return .Sleep;
        }
    }
    if (node.media_category) |media_category| {
        if (sliceContains(config.sleep_conditions.media_categories, media_category)) {
            return .Sleep;
        }
    }
    if (node.media_role) |media_role| {
        if (sliceContains(config.sleep_conditions.media_roles, media_role)) {
            return .Sleep;
        }
    }
    return .Idle;
}
fn evaluateStreams(ctx: *PwContext) void {
    const config = ctx.config;
    var idle_target: idle.IdleTarget = .None;
    var iterator = ctx.nodes.valueIterator();
    var apps: action.AppActivityList = action.AppActivityList.initCapacity(ctx.allocator, 5) catch blk: {
        break :blk action.AppActivityList.empty;
    };
    defer apps.deinit(ctx.allocator);
    while (iterator.next()) |node_ptr| {
        const node = node_ptr.*;
        if (node.state != pipewire_c.PW_NODE_STATE_RUNNING) {
            continue;
        }
        const node_idle_target = idleTargetFromNode(node, config);
        idle_target = idle_target.mostRestrictive(node_idle_target);
        apps.append(ctx.allocator, action.AppActivity{
            .name = node.node_name orelse "Unknown",
            .sink = node.node_type == .OuputAudio,
            .source = node.node_type == .InputAudio,
            .idle_target = node_idle_target,
        }) catch |err| {
            std.log.err("Failed to append app activity: {}\n", .{err});
        };
    }
    ctx.action_handler.update(idle_target, apps);
}

const NodeType = enum {
    InputAudio,
    OuputAudio,

    fn str(self: NodeType) []const u8 {
        return switch (self) {
            .InputAudio => "Stream/Input/Audio",
            .OuputAudio => "Stream/Output/Audio",
        };
    }
    fn fromMediaClass(media_class: []const u8) ?NodeType {
        if (std.mem.eql(u8, media_class, "Stream/Input/Audio")) {
            return NodeType.InputAudio;
        } else if (std.mem.eql(u8, media_class, "Stream/Output/Audio")) {
            return NodeType.OuputAudio;
        } else {
            return null;
        }
    }
};

fn nodeStateStr(state: pipewire_c.enum_pw_node_state) []const u8 {
    return switch (state) {
        pipewire_c.PW_NODE_STATE_ERROR => "Error",
        pipewire_c.PW_NODE_STATE_SUSPENDED => "Suspended",
        pipewire_c.PW_NODE_STATE_IDLE => "Idle",
        pipewire_c.PW_NODE_STATE_RUNNING => "Running",
        else => "Unknown",
    };
}

const Node = struct {
    id: u32,
    version: u32,
    ctx: *PwContext,
    node_type: NodeType,

    state: pipewire_c.enum_pw_node_state = pipewire_c.PW_NODE_STATE_SUSPENDED,
    proxy: *pipewire_c.struct_pw_proxy,
    listener: *pipewire_c.struct_spa_hook,

    node_name: ?[]const u8,
    application_name: ?[]const u8,
    media_type: ?[]const u8,
    media_category: ?[]const u8,
    media_role: ?[]const u8,
};

pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Config, output_mode: action.OutputMode) !*PwContext {
    pipewire_c.pw_init(null, null);

    const ctx = try allocator.create(PwContext);
    ctx.* = PwContext{
        .io = io,
        .allocator = allocator,
        .config = config,
        .action_handler = try .init(io, output_mode),
        .nodes = .init(allocator),
    };

    ctx.loop = pipewire_c.pw_main_loop_new(null) orelse return error.FailedToConnect;
    ctx.context = pipewire_c.pw_context_new(pipewire_c.pw_main_loop_get_loop(ctx.loop), null, 0) orelse return error.FailedToConnect;

    ctx.core = pipewire_c.pw_context_connect(ctx.context, null, 0) orelse return error.FailedToConnect;
    ctx.core_listener = try allocator.create(pipewire_c.struct_spa_hook);
    _ = pipewire_c.zig_pw_core_add_listener(ctx.core, ctx.core_listener, &core_events, ctx);

    ctx.registry = pipewire_c.pw_core_get_registry(ctx.core, pipewire_c.PW_VERSION_REGISTRY, 0).?;
    ctx.registry_listener = try allocator.create(pipewire_c.struct_spa_hook);

    _ = pipewire_c.zig_pw_registry_add_listener(ctx.registry, ctx.registry_listener, &registry_events, ctx);

    ctx.pending_sync = pipewire_c.zig_pw_core_sync(ctx.core, pipewire_c.PW_ID_CORE, 0);

    return ctx;
}

pub fn deinit(self: *PwContext) void {
    self.nodes.deinit();
    pipewire_c.pw_proxy_destroy(@ptrCast(self.registry));
    _ = pipewire_c.pw_core_disconnect(self.core);
    pipewire_c.pw_context_destroy(self.context);
    pipewire_c.pw_main_loop_destroy(self.loop);
    self.allocator.destroy(self.registry_listener);
    self.allocator.destroy(self.core_listener);
}

pub fn runLoop(self: *PwContext) !void {
    _ = pipewire_c.pw_main_loop_run(self.loop);
}

////////////////////
// PipeWire events
////////////////////

fn opaquePtrCast(comptime T: type, self: *anyopaque) *T {
    return @ptrCast(@alignCast(self));
}

///////////////////
// Core events

fn coreError(data: ?*anyopaque, id: u32, seq: c_int, res: c_int, message: [*c]const u8) callconv(.c) void {
    _ = seq;
    _ = message;
    const ctx = opaquePtrCast(PwContext, data.?);
    if (id == pipewire_c.PW_ID_CORE and res == -pipewire_c.EPIPE) {
        std.log.err("PipeWire core connection lost, exiting\n", .{});
        _ = pipewire_c.pw_main_loop_quit(ctx.loop);
    }
}
fn coreDone(data: ?*anyopaque, id: u32, seq: c_int) callconv(.c) void {
    const ctx = opaquePtrCast(PwContext, data.?);
    if (id == pipewire_c.PW_ID_CORE and seq == ctx.pending_sync) {
        ctx.pending_sync = -1;
    }
}

const core_events: pipewire_c.struct_pw_core_events = .{
    .version = pipewire_c.PW_VERSION_CORE_EVENTS,
    .@"error" = coreError,
    .done = coreDone,
};

///////////////////
// Node events

fn nodeInfo(data: ?*anyopaque, info: [*c]const pipewire_c.struct_pw_node_info) callconv(.c) void {
    const node: *Node = opaquePtrCast(Node, data.?);
    if (info.*.change_mask & pipewire_c.PW_NODE_CHANGE_MASK_STATE != 0) {
        node.state = info.*.state;
    }

    evaluateStreams(node.ctx);
}

const node_events: pipewire_c.struct_pw_node_events = .{
    .version = pipewire_c.PW_VERSION_NODE_EVENTS,
    .info = nodeInfo,
};

///////////////////
// Registry events

fn dupeProp(allocator: std.mem.Allocator, props: [*c]const pipewire_c.struct_spa_dict, key: [*c]const u8) ?[]const u8 {
    if (pipewire_c.spa_dict_lookup_item(props, key)) |prop| {
        return allocator.dupe(u8, std.mem.span(prop.*.value.?)) catch null;
    }
    return null;
}

fn registryGlobal(data: ?*anyopaque, id: u32, permissions: u32, @"type": [*c]const u8, version: u32, props: [*c]const pipewire_c.struct_spa_dict) callconv(.c) void {
    _ = permissions;
    const ctx: *PwContext = opaquePtrCast(PwContext, data.?);
    const media_class: ?*const pipewire_c.struct_spa_dict_item = pipewire_c.spa_dict_lookup_item(props, pipewire_c.PW_KEY_MEDIA_CLASS);
    if (media_class) |item| {
        const node_type = NodeType.fromMediaClass(std.mem.span(item.value.?)) orelse return; // Not an audio stream, ignore
        const node_name = dupeProp(ctx.allocator, props, pipewire_c.PW_KEY_NODE_NAME);
        const app_name = dupeProp(ctx.allocator, props, pipewire_c.PW_KEY_APP_NAME);
        const media_type = dupeProp(ctx.allocator, props, pipewire_c.PW_KEY_MEDIA_TYPE);
        const media_category = dupeProp(ctx.allocator, props, pipewire_c.PW_KEY_MEDIA_CATEGORY);
        const media_role = dupeProp(ctx.allocator, props, pipewire_c.PW_KEY_MEDIA_ROLE);
        const proxy: *pipewire_c.struct_pw_proxy = @ptrCast(pipewire_c.pw_registry_bind(ctx.registry, id, @"type", version, 0) orelse return);

        const listener: *pipewire_c.struct_spa_hook = ctx.allocator.create(pipewire_c.struct_spa_hook) catch |err| {
            std.debug.print("Failed to create listener: {}\n", .{err});
            return;
        };
        const node: *Node = ctx.allocator.create(Node) catch |err| {
            std.debug.print("Failed to create node: {}\n", .{err});
            return;
        };
        node.* = Node{
            .id = id,
            .ctx = ctx,
            .proxy = proxy,
            .version = version,
            .node_type = node_type,
            .node_name = node_name,
            .application_name = app_name,
            .media_type = media_type,
            .media_category = media_category,
            .listener = listener,
            .media_role = media_role,
        };
        pipewire_c.pw_proxy_add_object_listener(proxy, node.listener, &node_events, node);

        ctx.nodes.put(id, node) catch |err| {
            std.debug.print("Failed to add node to map: {}\n", .{err});
        };
    }
}

fn registryGlobalRemove(data: ?*anyopaque, id: u32) callconv(.c) void {
    const ctx: *PwContext = opaquePtrCast(PwContext, data.?);
    if (ctx.nodes.get(id)) |node| {
        pipewire_c.pw_proxy_destroy(node.proxy);
        pipewire_c.spa_hook_remove(node.listener);
        ctx.allocator.destroy(node.listener);
        if (node.node_name) |name| {
            ctx.allocator.free(name);
        }
        if (node.application_name) |app| {
            ctx.allocator.free(app);
        }
        if (node.media_type) |media_type| {
            ctx.allocator.free(media_type);
        }
        if (node.media_category) |media_category| {
            ctx.allocator.free(media_category);
        }
        if (node.media_role) |media_role| {
            ctx.allocator.free(media_role);
        }
        ctx.allocator.destroy(node);
        _ = ctx.nodes.remove(id);
    }
}

const registry_events: pipewire_c.pw_registry_events = .{
    .version = pipewire_c.PW_VERSION_REGISTRY_EVENTS,
    .global = registryGlobal,
    .global_remove = registryGlobalRemove,
};
