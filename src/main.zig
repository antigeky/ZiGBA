const std = @import("std");
const zigba = @import("root.zig");
const cli = @import("cli.zig");
const fs_io = std.Io.Threaded.global_single_threaded.io();
const sdl = @cImport({
    @cDefine("SDL_MAIN_HANDLED", "1");
    @cInclude("SDL3/SDL.h");
});

const scaled_w = zigba.ppu.screen_w * 2;
const scaled_h = zigba.ppu.screen_h * 2;
const target_frame_ns = std.time.ns_per_s / 60;
const title_update_ns = 500 * std.time.ns_per_ms;
const max_steps_per_frame = 2_000_000;
const pause_wait_ms = 100;
const left_axis_deadzone: i16 = 12_000;
const trigger_deadzone: i16 = 16_000;
const logical_presentation_mode = sdl.SDL_LOGICAL_PRESENTATION_LETTERBOX;

const key_a: u10 = 1 << 0;
const key_b: u10 = 1 << 1;
const key_select: u10 = 1 << 2;
const key_start: u10 = 1 << 3;
const key_right: u10 = 1 << 4;
const key_left: u10 = 1 << 5;
const key_up: u10 = 1 << 6;
const key_down: u10 = 1 << 7;
const key_r: u10 = 1 << 8;
const key_l: u10 = 1 << 9;

fn now_monotonic_ns() i128 {
    return @intCast(std.Io.Timestamp.now(fs_io, .awake).toNanoseconds());
}

const FrontendError = error{
    InvalidUsage,
    SdlInitFailed,
    SdlWindowCreateFailed,
    SdlTextureCreateFailed,
    SdlAudioFailed,
    FrameStalled,
};

const CliOptions = cli.CliOptions;

const LoadedSystem = struct {
    cart: *zigba.cartridge.Cartridge,
    bios: []u8,
    gba: *zigba.gba.Gba,

    fn init(allocator: std.mem.Allocator, options: CliOptions) !LoadedSystem {
        const cart = try allocator.create(zigba.cartridge.Cartridge);
        errdefer allocator.destroy(cart);
        cart.* = try zigba.cartridge.Cartridge.init(allocator, options.rom_path);
        errdefer cart.deinit(allocator);

        const bios = try zigba.gba.Gba.load_bios(allocator, zigba.fs_paths.default_bios_path);
        errdefer allocator.free(bios);

        zigba.arm_isa.generate_lookup();
        zigba.thumb_isa.generate_lookup();

        const gba_ptr = try allocator.create(zigba.gba.Gba);
        errdefer allocator.destroy(gba_ptr);
        gba_ptr.init(cart, bios, options.boot_bios);

        return .{
            .cart = cart,
            .bios = bios,
            .gba = gba_ptr,
        };
    }

    fn deinit(self: *LoadedSystem, allocator: std.mem.Allocator) void {
        allocator.destroy(self.gba);
        allocator.free(self.bios);
        self.cart.deinit(allocator);
        allocator.destroy(self.cart);
    }
};

const App = struct {
    allocator: std.mem.Allocator,
    options: CliOptions,
    system: LoadedSystem,
    pixels: []u32,
    game_name: []u8,
    savestate_path: []u8,
    savestate_buffer: *zigba.savestate.Snapshot,
    window: *sdl.SDL_Window,
    renderer: *sdl.SDL_Renderer,
    texture: *sdl.SDL_Texture,
    audio_stream: *sdl.SDL_AudioStream,
    gamepad: ?*sdl.SDL_Gamepad = null,
    running: bool = true,
    paused: bool = false,
    video_dirty: bool = false,
    skip_emulation_once: bool = false,
    frame_count: u64 = 0,
    fps_frame_count: u64 = 0,
    last_title_tick: i128 = 0,
    last_present_tick: i128 = 0,
    keyboard_state: u10 = 0,
    input_state: u10 = 0,
    color_map: [1 << 15]u32 = [_]u32{0} ** (1 << 15),

    fn init(allocator: std.mem.Allocator, options: CliOptions) !App {
        if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO | sdl.SDL_INIT_AUDIO | sdl.SDL_INIT_EVENTS | sdl.SDL_INIT_GAMEPAD)) {
            std.log.err("SDL_Init failed: {s}", .{sdl.SDL_GetError()});
            return error.SdlInitFailed;
        }
        errdefer sdl.SDL_Quit();

        zigba.fs_paths.ensure_dir(zigba.fs_paths.system_dir) catch |err| {
            std.log.warn("failed to create {s}: {s}", .{ zigba.fs_paths.system_dir, @errorName(err) });
        };
        zigba.fs_paths.ensure_dir(zigba.fs_paths.saves_dir) catch |err| {
            std.log.warn("failed to create {s}: {s}", .{ zigba.fs_paths.saves_dir, @errorName(err) });
        };
        zigba.fs_paths.ensure_dir(zigba.fs_paths.savestates_dir) catch |err| {
            std.log.warn("failed to create {s}: {s}", .{ zigba.fs_paths.savestates_dir, @errorName(err) });
        };

        var system = try LoadedSystem.init(allocator, options);
        errdefer system.deinit(allocator);

        const pixels = try allocator.alloc(u32, zigba.ppu.screen_w * zigba.ppu.screen_h);
        errdefer allocator.free(pixels);

        const game_name = try zigba.fs_paths.build_display_name(allocator, options.rom_path);
        errdefer allocator.free(game_name);

        const savestate_path = try zigba.fs_paths.build_savestate_path(allocator, options.rom_path);
        errdefer allocator.free(savestate_path);

        const savestate_buffer = try allocator.create(zigba.savestate.Snapshot);
        errdefer allocator.destroy(savestate_buffer);
        savestate_buffer.* = .{};

        var window_ptr: ?*sdl.SDL_Window = null;
        var renderer_ptr: ?*sdl.SDL_Renderer = null;
        if (!sdl.SDL_CreateWindowAndRenderer(
            "ZiGBA",
            scaled_w,
            scaled_h,
            sdl.SDL_WINDOW_RESIZABLE,
            &window_ptr,
            &renderer_ptr,
        )) {
            std.log.err("SDL_CreateWindowAndRenderer failed: {s}", .{sdl.SDL_GetError()});
            return error.SdlWindowCreateFailed;
        }
        errdefer if (renderer_ptr) |ptr| sdl.SDL_DestroyRenderer(ptr);
        errdefer if (window_ptr) |ptr| sdl.SDL_DestroyWindow(ptr);

        if (!sdl.SDL_SetRenderLogicalPresentation(renderer_ptr, scaled_w, scaled_h, logical_presentation_mode)) {
            std.log.warn("SDL_SetRenderLogicalPresentation failed: {s}", .{sdl.SDL_GetError()});
        }

        const texture = sdl.SDL_CreateTexture(
            renderer_ptr,
            sdl.SDL_PIXELFORMAT_ARGB8888,
            sdl.SDL_TEXTUREACCESS_STREAMING,
            zigba.ppu.screen_w,
            zigba.ppu.screen_h,
        ) orelse {
            std.log.err("SDL_CreateTexture failed: {s}", .{sdl.SDL_GetError()});
            return error.SdlTextureCreateFailed;
        };
        errdefer sdl.SDL_DestroyTexture(texture);
        if (!sdl.SDL_SetTextureScaleMode(texture, sdl.SDL_SCALEMODE_NEAREST)) {
            std.log.warn("SDL_SetTextureScaleMode failed: {s}", .{sdl.SDL_GetError()});
        }

        const audio_spec = sdl.SDL_AudioSpec{
            .freq = zigba.apu.sample_freq,
            .format = sdl.SDL_AUDIO_F32,
            .channels = 2,
        };
        const audio_stream = sdl.SDL_OpenAudioDeviceStream(sdl.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &audio_spec, null, null) orelse {
            std.log.err("SDL_OpenAudioDeviceStream failed: {s}", .{sdl.SDL_GetError()});
            return error.SdlAudioFailed;
        };
        errdefer sdl.SDL_DestroyAudioStream(audio_stream);
        if (!sdl.SDL_ResumeAudioStreamDevice(audio_stream)) {
            std.log.err("SDL_ResumeAudioStreamDevice failed: {s}", .{sdl.SDL_GetError()});
            return error.SdlAudioFailed;
        }

        var app = App{
            .allocator = allocator,
            .options = options,
            .system = system,
            .pixels = pixels,
            .game_name = game_name,
            .savestate_path = savestate_path,
            .savestate_buffer = savestate_buffer,
            .window = window_ptr.?,
            .renderer = renderer_ptr.?,
            .texture = texture,
            .audio_stream = audio_stream,
        };
        app.init_color_lookups();
        app.last_present_tick = now_monotonic_ns();
        app.open_first_gamepad();
        app.update_input_state();
        app.video_dirty = true;
        try app.present();
        app.video_dirty = false;
        app.refresh_window_title(true);
        return app;
    }

    fn deinit(self: *App) void {
        self.close_gamepad();
        self.allocator.destroy(self.savestate_buffer);
        self.allocator.free(self.savestate_path);
        self.allocator.free(self.game_name);
        self.allocator.free(self.pixels);
        sdl.SDL_DestroyAudioStream(self.audio_stream);
        sdl.SDL_DestroyTexture(self.texture);
        sdl.SDL_DestroyRenderer(self.renderer);
        sdl.SDL_DestroyWindow(self.window);
        self.system.deinit(self.allocator);
        sdl.SDL_Quit();
    }

    fn run(self: *App) !void {
        while (self.running) {
            if (self.paused or self.system.gba.stop) {
                self.wait_for_events(pause_wait_ms);
                if (!self.running) break;
                if (self.video_dirty) {
                    try self.present();
                    self.video_dirty = false;
                }
                self.refresh_window_title(false);
                continue;
            }

            self.process_events();
            if (!self.running) break;
            if (self.paused or self.system.gba.stop) {
                if (self.video_dirty) {
                    try self.present();
                    self.video_dirty = false;
                }
                self.refresh_window_title(false);
                continue;
            }

            if (self.skip_emulation_once) {
                self.skip_emulation_once = false;
            } else {
                try self.emulate_frame();
                self.frame_count += 1;
                self.video_dirty = true;
            }

            if (self.video_dirty) {
                try self.present();
                self.video_dirty = false;
            }
            self.refresh_window_title(false);
            self.limit_frame_rate();
        }
    }

    fn process_events(self: *App) void {
        var event: sdl.SDL_Event = undefined;
        while (sdl.SDL_PollEvent(&event)) {
            self.dispatch_event(&event);
        }
        self.update_input_state();
    }

    fn wait_for_events(self: *App, timeout_ms: c_int) void {
        var event: sdl.SDL_Event = undefined;
        if (sdl.SDL_WaitEventTimeout(&event, timeout_ms)) {
            self.dispatch_event(&event);
        }
        while (sdl.SDL_PollEvent(&event)) {
            self.dispatch_event(&event);
        }
        self.update_input_state();
    }

    fn dispatch_event(self: *App, event: *const sdl.SDL_Event) void {
        switch (event.type) {
            sdl.SDL_EVENT_QUIT => self.running = false,
            sdl.SDL_EVENT_KEY_DOWN => self.handle_key_down(event.key),
            sdl.SDL_EVENT_KEY_UP => self.handle_key_up(event.key.scancode),
            sdl.SDL_EVENT_GAMEPAD_ADDED => self.try_open_gamepad(event.gdevice.which),
            sdl.SDL_EVENT_GAMEPAD_REMOVED => self.handle_gamepad_removed(event.gdevice.which),
            sdl.SDL_EVENT_WINDOW_EXPOSED,
            sdl.SDL_EVENT_WINDOW_RESIZED,
            sdl.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED,
            sdl.SDL_EVENT_WINDOW_RESTORED,
            => self.video_dirty = true,
            else => {},
        }
    }

    fn handle_key_down(self: *App, event: sdl.SDL_KeyboardEvent) void {
        if (event.repeat) {
            if (scancode_mask(event.scancode)) |mask| {
                self.keyboard_state |= mask;
            }
            return;
        }

        if (event.scancode == sdl.SDL_SCANCODE_ESCAPE) {
            self.running = false;
            return;
        }

        const has_ctrl = (event.mod & sdl.SDL_KMOD_CTRL) != 0;
        if (has_ctrl) {
            switch (event.scancode) {
                sdl.SDL_SCANCODE_S => {
                    self.save_state();
                    return;
                },
                sdl.SDL_SCANCODE_L => {
                    self.load_state();
                    return;
                },
                sdl.SDL_SCANCODE_P => {
                    self.set_paused(!self.paused);
                    return;
                },
                else => {},
            }
        }

        if (event.scancode == sdl.SDL_SCANCODE_SPACE) {
            self.set_paused(!self.paused);
            return;
        }

        if (scancode_mask(event.scancode)) |mask| {
            self.keyboard_state |= mask;
        }
    }

    fn handle_key_up(self: *App, scancode: sdl.SDL_Scancode) void {
        if (scancode_mask(scancode)) |mask| {
            self.keyboard_state &= ~mask;
        }
    }

    fn update_input_state(self: *App) void {
        const combined = self.keyboard_state | self.poll_gamepad_state();
        if (combined == self.input_state) {
            return;
        }
        self.input_state = combined;
        self.apply_input_state();
    }

    fn apply_input_state(self: *App) void {
        const bits: u16 = (~@as(u16, self.input_state)) & 0x03ff;
        self.system.gba.io.regs.keyinput = @bitCast(bits);
        self.system.gba.update_keypad_irq();
    }

    fn poll_gamepad_state(self: *App) u10 {
        const gamepad = self.gamepad orelse return 0;
        if (!sdl.SDL_GamepadConnected(gamepad)) {
            self.close_gamepad();
            return 0;
        }

        var state: u10 = 0;
        if (sdl.SDL_GetGamepadButton(gamepad, sdl.SDL_GAMEPAD_BUTTON_SOUTH)) state |= key_b;
        if (sdl.SDL_GetGamepadButton(gamepad, sdl.SDL_GAMEPAD_BUTTON_EAST)) state |= key_a;
        if (sdl.SDL_GetGamepadButton(gamepad, sdl.SDL_GAMEPAD_BUTTON_BACK)) state |= key_select;
        if (sdl.SDL_GetGamepadButton(gamepad, sdl.SDL_GAMEPAD_BUTTON_START)) state |= key_start;
        if (sdl.SDL_GetGamepadButton(gamepad, sdl.SDL_GAMEPAD_BUTTON_DPAD_RIGHT)) state |= key_right;
        if (sdl.SDL_GetGamepadButton(gamepad, sdl.SDL_GAMEPAD_BUTTON_DPAD_LEFT)) state |= key_left;
        if (sdl.SDL_GetGamepadButton(gamepad, sdl.SDL_GAMEPAD_BUTTON_DPAD_UP)) state |= key_up;
        if (sdl.SDL_GetGamepadButton(gamepad, sdl.SDL_GAMEPAD_BUTTON_DPAD_DOWN)) state |= key_down;
        if (sdl.SDL_GetGamepadButton(gamepad, sdl.SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER)) state |= key_r;
        if (sdl.SDL_GetGamepadButton(gamepad, sdl.SDL_GAMEPAD_BUTTON_LEFT_SHOULDER)) state |= key_l;

        const left_x = sdl.SDL_GetGamepadAxis(gamepad, sdl.SDL_GAMEPAD_AXIS_LEFTX);
        if (left_x >= left_axis_deadzone) state |= key_right;
        if (left_x <= -left_axis_deadzone) state |= key_left;

        const left_y = sdl.SDL_GetGamepadAxis(gamepad, sdl.SDL_GAMEPAD_AXIS_LEFTY);
        if (left_y >= left_axis_deadzone) state |= key_down;
        if (left_y <= -left_axis_deadzone) state |= key_up;

        const left_trigger = sdl.SDL_GetGamepadAxis(gamepad, sdl.SDL_GAMEPAD_AXIS_LEFT_TRIGGER);
        if (left_trigger >= trigger_deadzone) state |= key_l;
        const right_trigger = sdl.SDL_GetGamepadAxis(gamepad, sdl.SDL_GAMEPAD_AXIS_RIGHT_TRIGGER);
        if (right_trigger >= trigger_deadzone) state |= key_r;

        return state;
    }

    fn try_open_gamepad(self: *App, instance_id: sdl.SDL_JoystickID) void {
        if (self.gamepad != null) {
            return;
        }
        if (!sdl.SDL_IsGamepad(instance_id)) {
            return;
        }
        const gamepad = sdl.SDL_OpenGamepad(instance_id) orelse {
            std.log.warn("SDL_OpenGamepad failed: {s}", .{sdl.SDL_GetError()});
            return;
        };
        self.gamepad = gamepad;
    }

    fn open_first_gamepad(self: *App) void {
        if (self.gamepad != null) {
            return;
        }
        var count: c_int = 0;
        const ids = sdl.SDL_GetGamepads(&count);
        if (ids == null or count <= 0) {
            return;
        }
        defer sdl.SDL_free(ids);

        var i: usize = 0;
        while (i < @as(usize, @intCast(count))) : (i += 1) {
            self.try_open_gamepad(ids[i]);
            if (self.gamepad != null) {
                return;
            }
        }
    }

    fn handle_gamepad_removed(self: *App, instance_id: sdl.SDL_JoystickID) void {
        const gamepad = self.gamepad orelse return;
        if (sdl.SDL_GetGamepadID(gamepad) != instance_id) {
            return;
        }
        self.close_gamepad();
        self.open_first_gamepad();
    }

    fn close_gamepad(self: *App) void {
        if (self.gamepad) |gamepad| {
            sdl.SDL_CloseGamepad(gamepad);
            self.gamepad = null;
        }
    }

    fn set_paused(self: *App, paused: bool) void {
        if (self.paused == paused) {
            return;
        }
        self.paused = paused;
        if (paused) {
            if (!sdl.SDL_ClearAudioStream(self.audio_stream)) {
                std.log.warn("SDL_ClearAudioStream failed: {s}", .{sdl.SDL_GetError()});
            }
            if (!sdl.SDL_PauseAudioStreamDevice(self.audio_stream)) {
                std.log.warn("SDL_PauseAudioStreamDevice failed: {s}", .{sdl.SDL_GetError()});
            }
        } else {
            self.last_present_tick = now_monotonic_ns();
            if (!sdl.SDL_ResumeAudioStreamDevice(self.audio_stream)) {
                std.log.warn("SDL_ResumeAudioStreamDevice failed: {s}", .{sdl.SDL_GetError()});
            }
        }
        self.refresh_window_title(true);
    }

    fn save_state(self: *App) void {
        zigba.savestate.save_state(self.system.gba, self.system.cart, self.savestate_path, self.savestate_buffer) catch |err| {
            std.log.err("savestate save failed: {s}", .{@errorName(err)});
            return;
        };
        std.log.info("savestate saved: {s}", .{self.savestate_path});
    }

    fn load_state(self: *App) void {
        zigba.savestate.load_state(self.system.gba, self.system.cart, self.system.bios, self.savestate_path, self.savestate_buffer) catch |err| {
            std.log.err("savestate load failed: {s}", .{@errorName(err)});
            return;
        };
        if (!sdl.SDL_ClearAudioStream(self.audio_stream)) {
            std.log.warn("SDL_ClearAudioStream failed: {s}", .{sdl.SDL_GetError()});
        }
        if (!self.paused and !sdl.SDL_ResumeAudioStreamDevice(self.audio_stream)) {
            std.log.warn("SDL_ResumeAudioStreamDevice failed: {s}", .{sdl.SDL_GetError()});
        }
        self.system.gba.apu.samples_full = false;
        self.skip_emulation_once = true;
        self.video_dirty = true;
        self.last_present_tick = now_monotonic_ns();
        self.update_input_state();
        self.refresh_window_title(true);
        std.log.info("savestate loaded: {s}", .{self.savestate_path});
    }

    fn emulate_frame(self: *App) !void {
        var steps: usize = 0;
        while (!self.system.gba.ppu.frame_complete and !self.system.gba.stop) : (steps += 1) {
            if (steps >= max_steps_per_frame) {
                return error.FrameStalled;
            }
            self.system.gba.step();
            if (self.system.gba.apu.samples_full) {
                if (!sdl.SDL_PutAudioStreamData(
                    self.audio_stream,
                    &self.system.gba.apu.sample_buf,
                    @sizeOf(@TypeOf(self.system.gba.apu.sample_buf)),
                )) {
                    std.log.warn("SDL_PutAudioStreamData failed: {s}", .{sdl.SDL_GetError()});
                }
                self.system.gba.apu.samples_full = false;
            }
        }
        self.system.gba.ppu.frame_complete = false;
    }

    fn present(self: *App) !void {
        self.convert_screen(self.pixels);
        if (!sdl.SDL_UpdateTexture(self.texture, null, self.pixels.ptr, zigba.ppu.screen_w * @sizeOf(u32))) {
            std.log.err("SDL_UpdateTexture failed: {s}", .{sdl.SDL_GetError()});
            return error.SdlTextureCreateFailed;
        }
        if (!sdl.SDL_RenderClear(self.renderer)) {
            std.log.warn("SDL_RenderClear failed: {s}", .{sdl.SDL_GetError()});
        }
        if (!sdl.SDL_RenderTexture(self.renderer, self.texture, null, null)) {
            std.log.err("SDL_RenderTexture failed: {s}", .{sdl.SDL_GetError()});
            return error.SdlTextureCreateFailed;
        }
        if (!sdl.SDL_RenderPresent(self.renderer)) {
            std.log.err("SDL_RenderPresent failed: {s}", .{sdl.SDL_GetError()});
            return error.SdlTextureCreateFailed;
        }
    }

    fn convert_screen(self: *App, out: []u32) void {
        const screen_ptr: [*]const zigba.gba.hword = @ptrCast(&self.system.gba.ppu.screen[0][0]);
        var index: usize = 0;
        while (index < out.len) : (index += 1) {
            out[index] = self.color_map[screen_ptr[index] & 0x7fff];
        }
    }

    fn init_color_lookups(self: *App) void {
        var channel_lookup: [32]u8 = [_]u8{0} ** 32;

        var i: usize = 0;
        while (i < 32) : (i += 1) {
            const linear = (@as(u32, @intCast(i)) * 255 + 15) / 31;
            channel_lookup[i] = @truncate(linear);
        }

        var color: usize = 0;
        while (color < self.color_map.len) : (color += 1) {
            const pixel: zigba.gba.hword = @intCast(color);
            const r = channel_lookup[(pixel >> 0) & 0x1f];
            const g = channel_lookup[(pixel >> 5) & 0x1f];
            const b = channel_lookup[(pixel >> 10) & 0x1f];
            self.color_map[color] = 0xff00_0000 | (@as(u32, r) << 16) | (@as(u32, g) << 8) | b;
        }
    }

    fn refresh_window_title(self: *App, force: bool) void {
        const now = now_monotonic_ns();
        const elapsed = now - self.last_title_tick;
        if (!force and elapsed < title_update_ns) {
            return;
        }

        const fps_value: u32 = blk: {
            if (elapsed <= 0) break :blk 0;
            const delta_frames = self.frame_count - self.fps_frame_count;
            const fps = @as(f64, @floatFromInt(delta_frames * std.time.ns_per_s)) / @as(f64, @floatFromInt(elapsed));
            const rounded = @as(u32, @intFromFloat(@max(0.0, fps + 0.5)));
            break :blk @min(@as(u32, 60), rounded);
        };

        var buf: [256]u8 = undefined;
        const paused_suffix = if (self.paused) " | Paused" else "";
        const title = std.fmt.bufPrintZ(&buf, "ZiGBA | {s} | {d}/60 FPS{s}", .{ self.game_name, fps_value, paused_suffix }) catch return;
        _ = sdl.SDL_SetWindowTitle(self.window, title.ptr);
        self.last_title_tick = now;
        self.fps_frame_count = self.frame_count;
    }

    fn limit_frame_rate(self: *App) void {
        const now = now_monotonic_ns();
        const elapsed = now - self.last_present_tick;
        if (elapsed < target_frame_ns) {
            const remaining_ns: u64 = @intCast(target_frame_ns - elapsed);
            if (remaining_ns != 0) {
                sdl.SDL_DelayNS(remaining_ns);
            }
        }
        self.last_present_tick = now_monotonic_ns();
    }
};

fn scancode_mask(scancode: sdl.SDL_Scancode) ?u10 {
    return switch (scancode) {
        sdl.SDL_SCANCODE_X => key_a,
        sdl.SDL_SCANCODE_Z => key_b,
        sdl.SDL_SCANCODE_BACKSPACE => key_select,
        sdl.SDL_SCANCODE_RETURN => key_start,
        sdl.SDL_SCANCODE_RIGHT => key_right,
        sdl.SDL_SCANCODE_LEFT => key_left,
        sdl.SDL_SCANCODE_UP => key_up,
        sdl.SDL_SCANCODE_DOWN => key_down,
        sdl.SDL_SCANCODE_S => key_r,
        sdl.SDL_SCANCODE_A => key_l,
        else => null,
    };
}

pub fn main(init: std.process.Init) !void {
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const options = try cli.parse_args(argv[1..]);
    var app = try App.init(init.gpa, options);
    defer app.deinit();
    try app.run();
}
