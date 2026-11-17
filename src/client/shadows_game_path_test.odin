package main

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:os"
import "core:testing"
import gl "vendor:OpenGL"
import glfw "vendor:glfw"
import stbi "vendor:stb/image"
import menuui "../menu"
import shared "../shared"

when ODIN_TEST {
	GAME_PATH_W :: 640
	GAME_PATH_H :: 360

	// A settings file as written by an earlier build of this branch: every
	// shadow switch on, Lighting Physical, and no shadow_quality/self_shadow.
	GAME_PATH_SETTINGS :: `{"version":1,"display_mode":0,"resolution_index":0,"monitor_index":0,"fullscreen_width":0,"fullscreen_height":0,"sensitivity":1,"mouse_dpi":800,"ads_sensitivity":1,"advanced_sensitivity":false,"invert_mouse":false,"fov":100,"show_fps":false,"vsync":false,"quality":{"smooth_textures":false,"anisotropy":0,"shadows":true,"soft_shadows":true,"high_res_shadows":true,"dynamic_shadows":true,"lighting":3}}`

	@(private = "file")
	game_path_frame :: proc(client: ^Client, pixels: []u8) {
		me := client.me
		me.position, me.velocity, me.direction = {-90, 220 - 9.5, 180}, {}, {-0.48, -0.1}
		// As client_tick: camera at the local player's eye, then the world pass.
		client.camera.position = me.position
		client.camera.position.y += me.height - shared.GAME_CONSTANTS.camera_height
		client.camera.rotation = {me.direction.x, me.direction.y, 0}
		player_update_meshes(me, false)
		gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
		gl.Viewport(0, 0, GAME_PATH_W, GAME_PATH_H)
		client_render_world(client)
		gl.PixelStorei(gl.PACK_ALIGNMENT, 1)
		ui_flush()
		gl.ReadPixels(0, 0, GAME_PATH_W, GAME_PATH_H, gl.RGB, gl.UNSIGNED_BYTE, raw_data(pixels))
	}

	@(private = "file")
	game_path_changed :: proc(a, b: []u8) -> int {
		changed := 0
		for i := 0; i < len(a); i += 3 {
			d := max(abs(int(a[i]) - int(b[i])), abs(int(a[i + 1]) - int(b[i + 1])), abs(int(a[i + 2]) - int(b[i + 2])))
			if d > 8 { changed += 1 }
		}
		return changed
	}

	// The game's own path: preferences loaded from a settings file, the map
	// loaded as `--map burg` does, Local Practice entered, frames drawn by
	// client_render_world. Shadows must visibly change Burg in every mode,
	// including after toggling them off and on again from the settings.
	@(test)
	shadows_render_in_the_game_path :: proc(t: ^testing.T) {
		logger := context.logger
		context = runtime.default_context()
		context.logger = logger
		if !testing.expect(t, bool(glfw.Init())) do return
		defer glfw.Terminate()
		glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)
		glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 5)
		window := glfw.CreateWindow(GAME_PATH_W, GAME_PATH_H, "Shadows game path", nil, nil)
		if !testing.expect(t, window != nil) do return
		defer glfw.DestroyWindow(window)
		glfw.MakeContextCurrent(window)
		gl.load_up_to(4, 5, glfw.gl_set_proc_address)
		gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)

		path := "bin/client-settings-game-path-test.json"
		defer os.remove(path)
		testing.expect(t, os.write_entire_file(path, GAME_PATH_SETTINGS) == nil)
		preferences := client_settings_load(path)
		testing.expect(t, preferences.quality.shadows && preferences.quality.self_shadow && preferences.quality.shadow_quality == 0 && preferences.quality.lighting == 3,
			fmt.tprintf("older settings must load with Self shadow on and Krunker quality: %v", preferences.quality))

		client := new(Client)
		defer free(client)
		g_client = client
		defer g_client = nil
		// As main: preferences, batching on, camera.
		client.visual_settings, client.quality_settings = preferences.visuals, preferences.quality
		client.viewmodel_settings = preferences.viewmodel
		client.render_batching = true
		client.camera.zoom = 1
		client.camera.fov = preferences.fov * math.PI / 180
		client.camera.near, client.camera.far = 0.1, 10000
		client.viewport_width, client.viewport_height = GAME_PATH_W, GAME_PATH_H
		client.selected_secondary = 2
		client_graphics_init(client)
		defer client_graphics_fini(client)
		client.scene = scene_init()
		client.fps_scene = scene_init()

		config := shared.config_load_gameplay("assets/config/game.toml")
		defer shared.config_destroy_gameplay(config)
		map_inst, ok := shared.map_load_from_file("assets/maps/burg.json")
		if !testing.expect(t, ok && map_inst != nil) do return
		maps := []^shared.Map{map_inst}
		shared.game_configure(&client.game, &config.game, maps, nil, config.weapons, config.classes)
		shared.game_init(&client.game, 0, -1, true)
		old_lighting, old_visuals := g_lighting_config, g_visual_settings
		defer {
			g_lighting_config, g_visual_settings = old_lighting, old_visuals
			client_clear_players(client)
			client_unload_map(client)
			shadow_fini()
			scene_fini(client.fps_scene)
			scene_fini(client.scene)
			shared.game_destroy(&client.game)
			shared.map_destroy(map_inst)
			resource_cache_fini()
		}
		if !testing.expect(t, client.game.ready) do return
		client_load_current_map(client)
		client.local_practice = true
		client.lobby_team = 1
		client_enter_game(client)
		me := client.me
		if !testing.expect(t, me != nil && me.mesh != nil, "Local Practice must spawn you") do return
		// Burg's courtyard, looking down at the sunlit ground.
		me.position = {-90, 220 - 9.5, 180}
		me.direction = {-0.48, -0.1}
		shared.player_update_height(me)

		pixels := make([]u8, GAME_PATH_W * GAME_PATH_H * 3)
		baseline := make([]u8, len(pixels))
		defer { delete(pixels); delete(baseline) }
		user := client.quality_settings
		client.quality_settings = {lighting = user.lighting}
		game_path_frame(client, baseline)

		os.make_directory("bin/shadow_game_path")
		cases := [?]struct{ name: string, quality: menuui.Quality_Settings }{
			{"user-settings", user},
			{"krunker-default", menuui.DEFAULT_QUALITY_SETTINGS},
			{"krunker-no-self", {shadows = true, lighting = user.lighting}},
			{"krunker-high-res", {shadows = true, high_res_shadows = true, lighting = user.lighting, self_shadow = true}},
			{"krunker-dynamic", {shadows = true, dynamic_shadows = true, lighting = user.lighting, self_shadow = true}},
			{"krunker-soft", {shadows = true, soft_shadows = true, lighting = user.lighting, self_shadow = true}},
			{"sharp", {shadows = true, shadow_quality = 1, lighting = user.lighting, self_shadow = true}},
			{"sharp-all", {shadows = true, soft_shadows = true, dynamic_shadows = true, shadow_quality = 1, lighting = user.lighting, self_shadow = true}},
		}
		for c in cases {
			client.quality_settings = c.quality
			// Several frames, as the game loop renders.
			for _ in 0 ..< 3 { game_path_frame(client, pixels) }
			changed := game_path_changed(baseline, pixels)
			fmt.printf("[game-path] %-18s %6d pixels changed by shadows (sun layers %d, player map %v)\n", c.name, changed, g_shadow.layers, g_render_quality.player_shadows)
			stbi.write_png(fmt.ctprintf("bin/shadow_game_path/%s.png", c.name), GAME_PATH_W, GAME_PATH_H, 3, &pixels[(GAME_PATH_H - 1) * GAME_PATH_W * 3], -GAME_PATH_W * 3)
			testing.expect(t, changed > 2000, fmt.tprintf("%s: shadows must visibly change Burg in the game path (%d pixels changed)", c.name, changed))
		}

		// The whole game frame (client_tick: input, players, world, HUD), as the
		// main loop runs it, with and without shadows.
		client.window = window
		client.ui = ui_init()
		defer { menuui.fini(&client.menu); ui_fini(client.ui); client.ui = nil }
		if testing.expect(t, menuui.init(&client.menu, menu_measure_text, client.ui)) {
			client.mouse_state.locked = true
			tick_frames :: proc(client: ^Client, me: ^shared.Player, quality: menuui.Quality_Settings, pixels: []u8) {
				client.quality_settings = quality
				for frame in 0 ..< 4 {
					me.position = {-90, 220 - 9.5, 180}
					me.velocity = {}
					me.direction = {-0.48, -0.1}
					client_tick(client, f32(glfw.GetTime()), 1.0 / 60)
				}
				gl.PixelStorei(gl.PACK_ALIGNMENT, 1)
				ui_flush()
				gl.ReadPixels(0, 0, GAME_PATH_W, GAME_PATH_H, gl.RGB, gl.UNSIGNED_BYTE, raw_data(pixels))
			}
			tick_off := make([]u8, len(pixels))
			defer delete(tick_off)
			tick_frames(client, me, {lighting = user.lighting}, tick_off)
			tick_frames(client, me, user, pixels)
			tick_changed := game_path_changed(tick_off, pixels)
			fmt.printf("[game-path] client_tick: %d pixels changed by shadows (render quality %v)\n", tick_changed, g_render_quality)
			stbi.write_png("bin/shadow_game_path/client_tick_user.png", GAME_PATH_W, GAME_PATH_H, 3, &pixels[(GAME_PATH_H - 1) * GAME_PATH_W * 3], -GAME_PATH_W * 3)
			stbi.write_png("bin/shadow_game_path/client_tick_off.png", GAME_PATH_W, GAME_PATH_H, 3, &tick_off[(GAME_PATH_H - 1) * GAME_PATH_W * 3], -GAME_PATH_W * 3)
			testing.expect(t, tick_changed > 2000, fmt.tprintf("shadows must show in full game frames (%d pixels changed)", tick_changed))
			client.mouse_state.locked = false
		}

		// Toggle Shadows off and on through the settings draft, as the menu does,
		// against a Shadows-off frame of the same state.
		client.quality_settings = {lighting = user.lighting}
		game_path_frame(client, baseline)
		client.quality_settings = user
		client.menu.page = .SETTINGS
		menuui.prepare_settings(&client.menu, menu_view(client))
		client.menu.settings_active = true
		client.menu.settings_draft.quality = user
		client.menu.settings_draft.quality.shadows = false
		game_path_frame(client, pixels)
		draft_changed := game_path_changed(baseline, pixels)
		testing.expect(t, draft_changed < 50, fmt.tprintf("Shadows off in the draft must preview without shadows (%d pixels differ; %v)", draft_changed, g_render_quality))
		client.menu.settings_draft.quality.shadows = true
		for _ in 0 ..< 2 { game_path_frame(client, pixels) }
		testing.expect(t, game_path_changed(baseline, pixels) > 2000, "turning Shadows back on must bring them back")
		client.menu.settings_active = false
		testing.expect(t, gl.GetError() == gl.NO_ERROR, "the game path must render shadows without OpenGL errors")
	}
}
