const std = @import("std");
const builtin = @import("builtin");

const c = @import("c");

const xr = @import("xr.zig");

const log = std.log.scoped(.main);

pub const std_options: std.Options = .{
    .log_level = switch (builtin.mode) {
        .Debug, .ReleaseSafe => .debug,
        .ReleaseFast, .ReleaseSmall => .info,
    },
};

const State = struct {
    gpu_device: *c.SDL_GPUDevice,
    instance: c.XrInstance,
    system_id: c.XrSystemId,
    session: c.XrSession,
    session_state: xr.SessionState,
    frame_arena_impl: std.heap.ArenaAllocator,
    gpa: std.mem.Allocator,
    session_data: ?SessionData,
};

const SessionData = struct {};

var run: bool = true;
const run_ptr: *volatile bool = &run;

pub fn main() !void {
    var gpa_impl: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer if (gpa_impl.deinit() == .leak) @panic("MEMORY LEAK FUCKFUCK FCCKNECEKONHSKO");
    const gpa = gpa_impl.allocator();

    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return error.FailedToInitSdl;
    defer c.SDL_Quit();
    log.info("Init SDL", .{});

    const gpu_props = c.SDL_CreateProperties();

    if (!c.SDL_OpenXR_LoadLibrary()) return error.FailedToLoadOpenXRLoader;
    defer c.SDL_OpenXR_UnloadLibrary();
    log.info("Loaded OpenXR", .{});

    const pfns = try xr.Pfns.load(c.SDL_OpenXR_GetXrGetInstanceProcAddr());
    _ = pfns; // autofix

    // enable our supported shader formats
    _ = c.SDL_SetBooleanProperty(gpu_props, c.SDL_PROP_GPU_DEVICE_CREATE_SHADERS_SPIRV_BOOLEAN, true);
    _ = c.SDL_SetBooleanProperty(gpu_props, c.SDL_PROP_GPU_DEVICE_CREATE_SHADERS_MSL_BOOLEAN, true);
    _ = c.SDL_SetBooleanProperty(gpu_props, c.SDL_PROP_GPU_DEVICE_CREATE_SHADERS_DXIL_BOOLEAN, true);
    _ = c.SDL_SetBooleanProperty(gpu_props, c.SDL_PROP_GPU_DEVICE_CREATE_SHADERS_DXBC_BOOLEAN, true);
    // set the app name
    _ = c.SDL_SetStringProperty(gpu_props, c.SDL_PROP_GPU_DEVICE_CREATE_XR_APPLICATION_NAME, "monado-passthrough-app");
    _ = c.SDL_SetNumberProperty(gpu_props, c.SDL_PROP_GPU_DEVICE_CREATE_XR_APPLICATION_VERSION, 0);
    // set the engine name
    _ = c.SDL_SetStringProperty(gpu_props, c.SDL_PROP_GPU_DEVICE_CREATE_XR_ENGINE_NAME, "monado-passthrough-app");
    _ = c.SDL_SetNumberProperty(gpu_props, c.SDL_PROP_GPU_DEVICE_CREATE_XR_ENGINE_VERSION, 0x00000001);

    _ = c.SDL_SetBooleanProperty(gpu_props, c.SDL_PROP_GPU_DEVICE_CREATE_DEBUGMODE_BOOLEAN, builtin.mode == .Debug);
    _ = c.SDL_SetBooleanProperty(gpu_props, c.SDL_PROP_GPU_DEVICE_CREATE_PREFERLOWPOWER_BOOLEAN, false);

    var instance: c.XrInstance = undefined;
    var system_id: c.XrSystemId = undefined;
    // Enable OpenXR for our GPU device
    _ = c.SDL_SetBooleanProperty(gpu_props, c.SDL_PROP_GPU_DEVICE_CREATE_XR_ENABLE, true);
    _ = c.SDL_SetPointerProperty(gpu_props, c.SDL_PROP_GPU_DEVICE_CREATE_XR_INSTANCE_OUT, @ptrCast(&instance));
    _ = c.SDL_SetPointerProperty(gpu_props, c.SDL_PROP_GPU_DEVICE_CREATE_XR_SYSTEM_ID_OUT, @ptrCast(&system_id));

    // Create our GPU device
    const gpu_device: *c.SDL_GPUDevice = c.SDL_CreateGPUDeviceWithProperties(gpu_props) orelse {
        return error.FailedToCreateGPUDevice;
    };
    log.info("Created GPU device", .{});
    defer c.SDL_DestroyGPUDevice(gpu_device);
    defer _ = c.SDL_WaitForGPUIdle(gpu_device); // wait for idle, ignore any error, we're quitting anyway.

    const blend_mode = find_transparent_blend_mode: {
        var blend_mode_count: u32 = undefined;
        try xr.handleResult(c.xrEnumerateEnvironmentBlendModes(instance, system_id, c.XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO, 0, &blend_mode_count, null));

        const blend_modes = try gpa.alloc(c.XrEnvironmentBlendMode, blend_mode_count);
        defer gpa.free(blend_modes);

        try xr.handleResult(c.xrEnumerateEnvironmentBlendModes(instance, system_id, c.XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO, blend_mode_count, &blend_mode_count, blend_modes.ptr));

        for (blend_modes) |supported_blend_mode| {
            switch (supported_blend_mode) {
                c.XR_ENVIRONMENT_BLEND_MODE_ADDITIVE,
                c.XR_ENVIRONMENT_BLEND_MODE_ALPHA_BLEND,
                => break :find_transparent_blend_mode supported_blend_mode,
                else => {},
            }
        }

        return error.TransparentBlendModesUnsupported;
    };
    log.info("Using environment blend mode {d}", .{blend_mode});

    var session: c.XrSession = undefined;

    var session_create_info: c.XrSessionCreateInfo = .{ .type = c.XR_TYPE_SESSION_CREATE_INFO };

    try xr.handleResult(c.SDL_CreateGPUXRSession(gpu_device, &session_create_info, &session));
    log.info("Created OpenXR session", .{});
    defer _ = c.xrDestroySession(session);

    var stage_space: c.XrSpace = undefined;
    try xr.handleResult(c.xrCreateReferenceSpace(session, &.{
        .type = c.XR_TYPE_REFERENCE_SPACE_CREATE_INFO,
        .poseInReferenceSpace = .{ .orientation = .{ .w = 1 } },
        .referenceSpaceType = c.XR_REFERENCE_SPACE_TYPE_STAGE,
    }, &stage_space));

    var state: State = .{
        .gpu_device = gpu_device,
        .instance = instance,
        .session = session,
        .session_state = .idle, // session state always defaults to idle
        .system_id = system_id,
        .gpa = gpa,
        .frame_arena_impl = .init(gpa),
        .session_data = null,
    };
    defer {
        state.frame_arena_impl.deinit();
    }

    const stdin = std.io.getStdIn();
    const stdin_handle = stdin.handle;
    {
        // Set stdin to nonblocking
        var o: std.os.linux.O = @bitCast(@as(u32, @intCast(std.os.linux.fcntl(stdin_handle, std.os.linux.F.GETFL, 0))));
        o.NONBLOCK = true;
        _ = std.os.linux.fcntl(stdin_handle, std.os.linux.F.SETFL, @as(u32, @bitCast(o)));
    }
    const stdin_reader = stdin.reader();

    var frame: usize = 0;
    while (run_ptr.*) {
        defer {
            log.debug("Handled frame {d}", .{frame});
            frame +%= 1;
        }

        defer _ = state.frame_arena_impl.reset(.{ .retain_with_limit = 1024 * 10 });

        var temp_buf: [8]u8 = undefined;
        const read = stdin_reader.read(&temp_buf) catch |err| handle_read_error: {
            if (err == std.fs.File.ReadError.WouldBlock) {
                break :handle_read_error 0;
            }

            return err;
        };

        if (read > 0) {
            switch (state.session_state) {
                .synchronized, .visible, .focused => {
                    try xr.handleResult(c.xrRequestExitSession(session));
                },
                else => {
                    break;
                },
            }
        }

        const frame_arena = state.frame_arena_impl.allocator();

        // Early return if an event says to
        if (!try clearXrEventQueue(&state, frame_arena)) return;

        // sleep 20ms waiting for our session to be ready...
        if (state.session_data == null) {
            std.time.sleep(std.time.ns_per_ms * 20);
            continue;
        }

        var frame_state: c.XrFrameState = .{ .type = c.XR_TYPE_FRAME_STATE };
        try xr.handleResult(c.xrWaitFrame(session, &.{ .type = c.XR_TYPE_FRAME_WAIT_INFO }, &frame_state));

        try xr.handleResult(c.xrBeginFrame(session, &.{ .type = c.XR_TYPE_FRAME_BEGIN_INFO }));

        try xr.handleResult(c.xrEndFrame(session, &.{
            .type = c.XR_TYPE_FRAME_END_INFO,
            .displayTime = frame_state.predictedDisplayTime,
            .environmentBlendMode = blend_mode,
            .layers = null,
            .layerCount = 0,
        }));
    }
}

/// Handles a continuous stream of OpenXR events until none are left to process, returning whether or not to continue the app.
fn clearXrEventQueue(state: *State, arena: std.mem.Allocator) !bool {
    _ = arena;

    var event: c.XrEventDataBuffer = undefined;

    log.debug("Clearing event queue", .{});
    defer log.debug("Cleared event queue", .{});

    while (true) {
        xr.handleResult(c.xrPollEvent(state.instance, &event)) catch |err| {
            // If we're out of events, break out of the loop
            if (err == xr.Error.event_unavailable)
                return true;

            return err;
        };

        log.debug("Got event with type {d}", .{event.type});

        switch (event.type) {
            c.XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED => {
                const session_state_changed_event: *const c.XrEventDataSessionStateChanged = @ptrCast(&event);

                state.session_state = @enumFromInt(session_state_changed_event.state);

                log.info("Session state changed to {}", .{state.session_state});
                switch (state.session_state) {
                    .unknown => unreachable,
                    .idle => {},
                    .ready => {
                        // begin the session
                        try xr.handleResult(c.xrBeginSession(state.session, &.{
                            .type = c.XR_TYPE_SESSION_BEGIN_INFO,
                            .primaryViewConfigurationType = c.XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO,
                        }));

                        state.session_data = .{};
                    },
                    .synchronized => {},
                    .visible => {},
                    .focused => {},
                    .stopping => {
                        try xr.handleResult(c.xrEndSession(state.session));
                    },
                    .exiting, .loss_pending => {
                        run_ptr.* = false;
                        return false;
                    },
                    _ => log.warn("Unhandled session state {d}", .{session_state_changed_event.state}),
                }
            },
            else => {},
        }
    }
}
