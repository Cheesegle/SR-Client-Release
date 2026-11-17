package main

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:testing"
import "core:time"
import gl "vendor:OpenGL"
import glfw "vendor:glfw"
import menuui "../menu"
import shared "../shared"

when ODIN_TEST {
	// Next free GL names. Drivers hand out the lowest free name, so these stay
	// put unless objects are created (and kept) between two probes.
	@(private = "file")
	GL_Name_Probe :: struct {
		texture, buffer, sampler, framebuffer, vertex_array, renderbuffer, query, program, shader: u32,
	}

	@(private = "file")
	gl_name_probe :: proc() -> (probe: GL_Name_Probe) {
		gl.GenTextures(1, &probe.texture); gl.DeleteTextures(1, &probe.texture)
		gl.GenBuffers(1, &probe.buffer); gl.DeleteBuffers(1, &probe.buffer)
		gl.GenSamplers(1, &probe.sampler); gl.DeleteSamplers(1, &probe.sampler)
		gl.GenFramebuffers(1, &probe.framebuffer); gl.DeleteFramebuffers(1, &probe.framebuffer)
		gl.GenVertexArrays(1, &probe.vertex_array); gl.DeleteVertexArrays(1, &probe.vertex_array)
		gl.GenRenderbuffers(1, &probe.renderbuffer); gl.DeleteRenderbuffers(1, &probe.renderbuffer)
		gl.GenQueries(1, &probe.query); gl.DeleteQueries(1, &probe.query)
		probe.program = gl.CreateProgram(); gl.DeleteProgram(probe.program)
		probe.shader = gl.CreateShader(gl.VERTEX_SHADER); gl.DeleteShader(probe.shader)
		return
	}

	// Live GL objects named at or above `probe`: anything created after the
	// probe and still alive (a leak), even if the driver reused the probe name.
	@(private = "file")
	gl_objects_above :: proc(probe: GL_Name_Probe, span: u32 = 512) -> (count: int) {
		for name in 0 ..< span {
			if gl.IsTexture(probe.texture + name) { count += 1 }
			if gl.IsBuffer(probe.buffer + name) { count += 1 }
			if gl.IsSampler(probe.sampler + name) { count += 1 }
			if gl.IsFramebuffer(probe.framebuffer + name) { count += 1 }
			if gl.IsVertexArray(probe.vertex_array + name) { count += 1 }
			if gl.IsRenderbuffer(probe.renderbuffer + name) { count += 1 }
			if gl.IsQuery(probe.query + name) { count += 1 }
			if gl.IsProgram(probe.program + name) || gl.IsShader(probe.program + name) { count += 1 }
		}
		return
	}

	@(private = "file")
	Settings_Stress_Counters :: struct {
		batch_builds, self_tests, shader_compiles, monitor_refreshes, cached_textures, menu_portraits: int,
	}

	@(private = "file")
	stress_counters :: proc(client: ^Client) -> Settings_Stress_Counters {
		return {g_map_batch_builds, g_map_batch_self_tests, g_shader_compiles, client.monitor_cache_refreshes, len(g_texture_cache), len(menu_portraits)}
	}

	// One menu frame as the main loop draws it with the cursor free: the world
	// behind the menu, the Clay menu and its action, then the buffer swap.
	@(private = "file")
	stress_frame :: proc(client: ^Client) {
		phase_frame_begin()
		g_draw_calls = 0
		client.mouse_state.locked = false
		client_render_world(client)
		ui_update(client.ui, f32(client.viewport_width), f32(client.viewport_height))
		hud_render(client, 1.0 / 60)
		glfw.SwapBuffers(client.window)
		glfw.PollEvents()
		free_all(context.temp_allocator)
	}

	// Opens Settings (on Main, as the game does) and visits every tab with a
	// debug context, dragging every Visuals slider, toggling hide cats/props
	// and changing filtering, anisotropy, display mode, monitor, resolution
	// and the menu FPS limit, then closes and reopens it. Settings must not
	// raise GL errors or warnings, keep creating GL objects or heap memory,
	// rebuild map batches, rerun the batching self-test, compile shaders, load
	// textures, or enumerate monitor modes except once per opening.
	when !SR_VULKAN {
	@(test)
	settings_tabs_are_gl_clean_and_steady :: proc(t: ^testing.T) {
		// Resource caches outlive the test (as in the other GL tests), so the
		// runner's tracker is left out; the loop below tracks its own heap use.
		logger := context.logger
		context = runtime.default_context()
		context.logger = logger
		if !testing.expect(t, bool(glfw.Init())) do return
		defer glfw.Terminate()
		glfw.DefaultWindowHints()
		defer glfw.DefaultWindowHints()
		glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)
		glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 5)
		glfw.WindowHint(glfw.OPENGL_DEBUG_CONTEXT, glfw.TRUE)
		window := glfw.CreateWindow(1280, 720, "Settings GL stress", nil, nil)
		if !testing.expect(t, window != nil) do return
		defer glfw.DestroyWindow(window)
		glfw.MakeContextCurrent(window)
		glfw.SwapInterval(0)
		gl.load_up_to(4, 5, glfw.gl_set_proc_address)
		old_diag := g_diag
		defer g_diag = old_diag
		diagnostics_capture_gpu_info()
		testing.expect(t, g_diag.gl_debug_context, "the test needs a debug context")
		gl_debug_reset_counts()
		log_path := "bin/settings-gl-stress.log"
		if !testing.expect(t, gl_debug_install(log_path), "KHR_debug must be available") do return
		defer gl_debug_shutdown()
		gpu_set_target(test_gpu_current_target(), 1280, 720)

		client := new(Client)
		defer free(client)
		g_client = client
		defer g_client = nil
		client^ = Client{window = window, sensitivity = 1, mouse_dpi = menuui.DEFAULT_MOUSE_DPI, render_batching = true,
			visual_settings = menuui.DEFAULT_VISUAL_SETTINGS, bindings = menuui.default_bindings(), audio_settings = DEFAULT_AUDIO_SETTINGS,
			viewmodel_settings = menuui.DEFAULT_VIEWMODEL_SETTINGS, crosshair_settings = menuui.DEFAULT_CROSSHAIR_SETTINGS,
			viewport_width = 1280, viewport_height = 720, menu_fps_limit = menuui.MENU_FPS_LIMIT_MONITOR,
			quality_settings = {smooth_textures = true, anisotropy = 16}}
		client.camera = camera_init(menuui.DEFAULT_FOV * 3.14159265 / 180)
		client.scene, client.fps_scene, client.ui = scene_init(), scene_init(), ui_init()
		client_graphics_init(client)
		if !testing.expect(t, menuui.init(&client.menu, menu_measure_text, client.ui), "menu init") do return
		old_lighting, old_visuals := g_lighting_config, g_visual_settings
		defer {
			client_unload_map(client)
			if client.game.map_inst != nil { shared.map_destroy(client.game.map_inst) }
			for _, texture in menu_portraits { texture_release(texture) }
			delete(menu_portraits); menu_portraits = nil
			menuui.fini(&client.menu)
			client_graphics_fini(client)
			scene_fini(client.fps_scene)
			scene_fini(client.scene)
			ui_fini(client.ui)
			resource_cache_fini()
			g_lighting_config, g_visual_settings = old_lighting, old_visuals
		}
		map_inst, map_ok := shared.map_load_from_file("assets/maps/burg.json")
		if !testing.expect(t, map_ok && map_inst != nil, "burg must load") do return
		client.game.map_inst = map_inst
		client_load_current_map(client)
		client.camera.position = map_inst.camera_position
		testing.expect(t, client.scene.batches != nil, "batching is on for the test map")

		// Warm up: glyphs, the blank texture, portraits and other lazily
		// created objects, on the home page and on every tab once.
		menu := &client.menu
		menu.page = .HOME
		for _ in 0 ..< 3 { stress_frame(client) }
		menu.page = .SETTINGS
		for tab in menuui.Settings_Tab {
			menu.settings_tab = tab
			for _ in 0 ..< 3 { stress_frame(client) }
		}
		menu.page = .HOME
		stress_frame(client)

		// Every heap allocation from here on is tracked; the temp allocator is
		// reset each frame like the main loop does.
		tracker: mem.Tracking_Allocator
		mem.tracking_allocator_init(&tracker, context.allocator)
		defer mem.tracking_allocator_destroy(&tracker)
		context.allocator = mem.tracking_allocator(&tracker)

		before := stress_counters(client)
		probe := gl_name_probe()
		live_bytes_start := tracker.current_memory_allocated
		FRAMES_PER_STEP :: 4
		ROUNDS :: 3
		draw_calls: [menuui.Settings_Tab]u32
		frame_ms: [menuui.Settings_Tab]f64
		for round in 0 ..< ROUNDS {
			// Opening lands on Main, as in the game.
			menu.page, menu.settings_tab = .SETTINGS, .MAIN
			for tab in menuui.Settings_Tab {
				menuui.activate(menu, {action = {kind = .SETTINGS_TAB, index = i32(tab)}})
				start := time.tick_now()
				for _ in 0 ..< FRAMES_PER_STEP { stress_frame(client) }
				draw_calls[tab] = max(draw_calls[tab], g_draw_calls)
				frame_ms[tab] = max(frame_ms[tab], time.duration_milliseconds(time.tick_since(start)) / FRAMES_PER_STEP)
				#partial switch tab {
				case .MAIN, .VIDEO:
					menuui.activate(menu, {action = {kind = .DISPLAY_MODE, index = i32(round % 3)}})
					menuui.activate(menu, {action = {kind = .MONITOR, index = i32(round % 2)}})
					menuui.activate(menu, {action = {kind = .RESOLUTION, index = 1}})
					menuui.activate(menu, {action = {kind = .MENU_FPS_LIMIT, index = i32(round * 2 % len(menuui.MENU_FPS_LIMITS))}})
					menuui.activate(menu, {action = {kind = .TEXTURE_FILTER, index = i32(round % 2)}})
					for level in 0 ..< 5 {
						menuui.activate(menu, {action = {kind = .ANISOTROPY, index = i32(level)}})
						stress_frame(client)
					}
				case .VISUALS:
					for control in menuui.Visual_Control {
						if control == .FOG_DISTANCE { continue }
						limits := menuui.VISUAL_LIMITS[control]
						for i in 0 ..= 8 {
							value := limits[0] + (limits[1] - limits[0]) * f32(i) / 8
							menuui.activate(menu, {action = {kind = .VISUAL_VALUE, index = i32(control), value = value}})
							stress_frame(client)
						}
					}
					menuui.activate(menu, {action = {kind = .VISUAL_TOGGLE, index = 0}})
					stress_frame(client)
					menuui.activate(menu, {action = {kind = .VISUAL_TOGGLE, index = 1}})
					stress_frame(client)
					menuui.activate(menu, {action = {kind = .VISUAL_TOGGLE, index = 0}})
					menuui.activate(menu, {action = {kind = .VISUAL_TOGGLE, index = 1}})
					stress_frame(client)
				}
				for _ in 0 ..< FRAMES_PER_STEP { stress_frame(client) }
			}
			// Close (Cancel drops the draft) and show the home page again.
			menuui.activate(menu, {action = {kind = .SETTINGS_CANCEL}})
			menu.page = .HOME
			for _ in 0 ..< FRAMES_PER_STEP { stress_frame(client) }
		}
		live_bytes_end := tracker.current_memory_allocated
		after := stress_counters(client)
		leaked := gl_objects_above(probe)
		probe_after := gl_name_probe()
		context.allocator = tracker.backing

		testing.expectf(t, g_diag.gl_errors == 0, "Settings must not raise GL errors (%d; see %s)", g_diag.gl_errors, log_path)
		testing.expectf(t, g_diag.gl_warnings == 0, "Settings must not raise GL undefined-behaviour, portability or performance warnings (%d; see %s)", g_diag.gl_warnings, log_path)
		testing.expectf(t, leaked == 0 && probe_after == probe, "Settings must not keep creating GL objects: %d live above %v, next names %v", leaked, probe, probe_after)
		testing.expectf(t, live_bytes_end <= live_bytes_start, "Settings must not grow the heap: %d -> %d bytes live (%d allocations live)",
			live_bytes_start, live_bytes_end, len(tracker.allocation_map))
		testing.expectf(t, after.batch_builds == before.batch_builds && after.self_tests == before.self_tests, "Settings must not rebuild map batches or rerun the self-test: %v -> %v", before, after)
		testing.expectf(t, after.shader_compiles == before.shader_compiles, "Settings must not compile shaders: %v -> %v", before, after)
		testing.expectf(t, after.cached_textures == before.cached_textures && after.menu_portraits == before.menu_portraits, "Settings must not load textures: %v -> %v", before, after)
		testing.expectf(t, after.monitor_refreshes - before.monitor_refreshes == ROUNDS, "monitor modes are enumerated once per opening of Settings: %v -> %v", before, after)
		testing.expect(t, client.scene.batches != nil && client.render_batching, "batching stays on")
		when #config(SETTINGS_STRESS_VERBOSE, false) {
			fmt.printf("counters %v -> %v\nGL errors %d, warnings %d, other %d; heap %d -> %d bytes\n", before, after, g_diag.gl_errors, g_diag.gl_warnings, g_diag.gl_other, live_bytes_start, live_bytes_end)
			for tab in menuui.Settings_Tab { fmt.printf("  %v: %d draw calls, %.2f ms/frame\n", tab, draw_calls[tab], frame_ms[tab]) }
		}
	}
	} // GL-only test (OpenGL state or contexts)
}
