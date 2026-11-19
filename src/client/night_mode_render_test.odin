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
	NIGHT_W :: 640
	NIGHT_H :: 360

	@(private = "file")
	Night_View :: struct {
		map_name: string,
		camera:   shared.Vec3,
		yaw:      f32,
		pitch:    f32,
		player:   shared.Vec3, // The remote player; zero puts them 30 units ahead.
	}

	@(private = "file")
	NIGHT_VIEWS := []Night_View{
		// Burg's courtyard, as the shadows game-path test.
		{"burg", {-90, 220, 180}, 0, -0.1, {}},
		// Undergrowth (a darker, foggy map) looking over its west side.
		{"undergrowth", {-186, 105, -122}, -2.2, -0.35, {}},
		// Eterno Jump's point light (Lighting High).
		{"eterno_jump", {-3552, 55, 30}, 0, -0.2, {}},
	}

	@(private = "file")
	night_frame :: proc(client: ^Client, pixels: []u8) {
		test_gpu_use_device_target()
		gpu_set_target(test_gpu_current_target(), NIGHT_W, NIGHT_H)
		client_render_world(client)
		test_read_rgb(0, 0, NIGHT_W, NIGHT_H, raw_data(pixels))
	}

	@(private = "file")
	night_write :: proc(name: string, pixels: []u8) {
		stbi.write_png(fmt.ctprintf("bin/night/%s.png", name), NIGHT_W, NIGHT_H, 3, &pixels[(NIGHT_H - 1) * NIGHT_W * 3], -NIGHT_W * 3)
	}

	@(private = "file")
	night_mean :: proc(pixels: []u8) -> (luma: f32, rgb: [3]f32) {
		for i := 0; i < len(pixels); i += 3 {
			for c in 0 ..< 3 { rgb[c] += f32(pixels[i + c]) }
		}
		n := f32(len(pixels) / 3)
		rgb = {rgb[0] / n, rgb[1] / n, rgb[2] / n}
		return rgb[0]*0.2126 + rgb[1]*0.7152 + rgb[2]*0.0722, rgb
	}

	// Pixels the remote player changes, and their mean difference: how well the
	// player stands out from what is behind them.
	@(private = "file")
	night_player_contrast :: proc(with, without: []u8) -> (pixels: int, mean: f32) {
		total := 0
		for i := 0; i < len(with); i += 3 {
			d := max(abs(int(with[i]) - int(without[i])), abs(int(with[i + 1]) - int(without[i + 1])), abs(int(with[i + 2]) - int(without[i + 2])))
			if d > 2 { pixels += 1; total += d }
		}
		return pixels, pixels > 0 ? f32(total) / f32(pixels) : 0
	}

	// Night mode through the game's own frame path (client_render_world) on
	// Burg, Undergrowth and Eterno Jump (a map light): off and strength 0
	// must be pixel-identical; 0.3, 0.7 and 1.0 must get progressively darker
	// and bluer while a remote player stays distinguishable. Every frame is
	// written to bin/night/ for checking by eye.
	@(test)
	night_mode_renders_on_every_lighting :: proc(t: ^testing.T) {
		logger := context.logger
		context = runtime.default_context()
		context.logger = logger
		if !testing.expect(t, bool(glfw.Init())) do return
		defer glfw.Terminate()
		test_gpu := test_gpu_open(NIGHT_W, NIGHT_H, "Night mode")
		if !testing.expect(t, test_gpu.ok, "no GPU device for the test") do return
		defer test_gpu_close(&test_gpu, t)
		g_test_gpu = &test_gpu
		window := test_gpu.window
		os.make_directory("bin/night")

		old_lighting, old_visuals := g_lighting_config, g_visual_settings
		defer { g_lighting_config, g_visual_settings = old_lighting, old_visuals; g_night_low_tint, g_night_unlit_tint = {1, 1, 1}, {1, 1, 1} }
		defer shadow_fini()
		config := shared.config_load_gameplay("assets/config/game.toml")
		defer shared.config_destroy_gameplay(config)

		views := NIGHT_VIEWS
		pixels := make([]u8, NIGHT_W * NIGHT_H * 3)
		off := make([]u8, len(pixels))
		without := make([]u8, len(pixels))
		defer { delete(pixels); delete(off); delete(without) }

		for view in views {
			client := new(Client)
			g_client = client
			client.render_batching = true
			client.camera = camera_init(menuui.DEFAULT_FOV * math.PI / 180)
			client.camera.near, client.camera.far = 0.1, 10000
			client.viewport_width, client.viewport_height = NIGHT_W, NIGHT_H
			client.visual_settings, client.quality_settings = menuui.DEFAULT_VISUAL_SETTINGS, menuui.DEFAULT_QUALITY_SETTINGS
			client.viewmodel_settings = menuui.DEFAULT_VIEWMODEL_SETTINGS
			client_graphics_init(client)
			client.scene = scene_init()
			client.fps_scene = scene_init()
			map_inst, ok := shared.map_load_from_file(fmt.tprintf("assets/maps/%s.json", view.map_name))
			if !testing.expect(t, ok && map_inst != nil, view.map_name) {
				scene_fini(client.fps_scene); scene_fini(client.scene); client_graphics_fini(client); free(client)
				continue
			}
			maps := []^shared.Map{map_inst}
			shared.game_configure(&client.game, &config.game, maps, nil, config.weapons, config.classes)
			shared.game_init(&client.game, 0, -1, true)
			client_load_current_map(client)

			position, yaw := view.camera, view.yaw
			client.camera.position, client.camera.rotation = position, {view.pitch, yaw, 0}

			// A remote player in front of the camera, standing on the ground below
			// the camera's line of sight.
			remote := shared.player_init(&client.game)
			shared.game_players_add(&client.game, remote)
			shared.player_spawn(remote, 0)
			remote.uid, remote.active, remote.swap_timer_ms = 2, true, 0
			forward := shared.Vec3{-math.sin(yaw), 0, -math.cos(yaw)}
			remote.position = view.player != {} ? view.player : position + forward * 30 - shared.Vec3{0, 11, 0}
			remote.direction = {yaw + math.PI, 0}
			shared.player_update_height(remote)
			player_generate_meshes(remote, false)
			rig := cast(^Player_Mesh)remote.mesh
			scene_add_player_mesh(client.scene, rig, int(remote.loadout_size))
			player_update_meshes(remote, false)

			qualities := [?]struct{ name: string, quality: menuui.Quality_Settings }{
				{"normal-shadows", menuui.DEFAULT_QUALITY_SETTINGS},
				{"normal-noshadows", {lighting = i32(menuui.Lighting_Quality.NORMAL)}},
				{"low", {lighting = i32(menuui.Lighting_Quality.LOW), shadows = true}},
				{"high-shadows", {lighting = i32(menuui.Lighting_Quality.HIGH), shadows = true, self_shadow = true}},
			}
			for q in qualities {
				client.quality_settings = q.quality
				client.visual_settings = menuui.DEFAULT_VISUAL_SETTINGS
				for _ in 0 ..< 2 { night_frame(client, off) }
				night_write(fmt.tprintf("%s_%s_off", view.map_name, q.name), off)
				off_luma, _ := night_mean(off)

				// On at strength 0: exactly today's frame.
				client.visual_settings.night_mode, client.visual_settings.night_strength = true, 0
				night_frame(client, pixels)
				same := true
				for value, i in pixels { if value != off[i] { same = false; break } }
				testing.expect(t, same, fmt.tprintf("%s %s: night at strength 0 must be pixel-identical to night off", view.map_name, q.name))

				previous := off_luma
				for strength in ([3]f32{0.3, 0.7, 1.0}) {
					client.visual_settings.night_strength = strength
					night_frame(client, pixels)
					label := fmt.tprintf("%s_%s_night%.1f", view.map_name, q.name, strength)
					night_write(label, pixels)
					luma, rgb := night_mean(pixels)
					fmt.printf("[night] %-40s mean luma %6.1f (off %6.1f) rgb %5.1f %5.1f %5.1f\n", label, luma, off_luma, rgb[0], rgb[1], rgb[2])
					testing.expect(t, luma < previous, fmt.tprintf("%s: stronger night must be darker (%.1f, before %.1f)", label, luma, previous))
					previous = luma
					if strength == 1.0 {
						testing.expect(t, luma < off_luma * 0.6, fmt.tprintf("%s: full night must read as night (luma %.1f vs %.1f)", label, luma, off_luma))
						testing.expect(t, rgb[2] > rgb[0], fmt.tprintf("%s: night must be cool (rgb %v)", label, rgb))
						testing.expect(t, luma > 8, fmt.tprintf("%s: night must stay readable, not black (luma %.1f)", label, luma))
						// The player must still stand out from the scene behind them.
						scene_remove_player_mesh(client.scene, rig, int(remote.loadout_size))
						night_frame(client, without)
						scene_add_player_mesh(client.scene, rig, int(remote.loadout_size))
						count, mean := night_player_contrast(pixels, without)
						fmt.printf("[night] %-40s player covers %d pixels, mean contrast %.1f\n", label, count, mean)
						testing.expect(t, count > 200 && mean > 10, fmt.tprintf("%s: the player must stay distinguishable (%d pixels, contrast %.1f)", label, count, mean))
					}
				}
			}
			testing.expect(t, test_gpu_no_error(), fmt.tprintf("%s: night mode must render without OpenGL errors", view.map_name))

			client_clear_players(client)
			client_unload_map(client)
			scene_fini(client.fps_scene)
			scene_fini(client.scene)
			shared.game_destroy(&client.game)
			shared.map_destroy(map_inst)
			client_graphics_fini(client)
			resource_cache_fini()
			free(client)
			g_client = nil
			free_all(context.temp_allocator)
		}
	}
}
