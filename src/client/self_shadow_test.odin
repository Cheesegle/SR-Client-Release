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
	SELF_SHADOW_W :: 128
	SELF_SHADOW_H :: 128

	@(private = "file")
	self_shadow_frame :: proc(client: ^Client, quality: menuui.Quality_Settings, pixels: []u8) {
		client.quality_settings = quality
		test_gpu_use_device_target()
		gpu_set_target(test_gpu_current_target(), SELF_SHADOW_W, SELF_SHADOW_H)
		client_render_world(client)
		test_read_rgb(0, 0, SELF_SHADOW_W, SELF_SHADOW_H, raw_data(pixels))
	}

	@(private = "file")
	self_shadow_luma :: proc(pixels: []u8, x, y: int) -> int {
		i := (y * SELF_SHADOW_W + x) * 3
		return (int(pixels[i]) + int(pixels[i + 1]) + int(pixels[i + 2])) / 3
	}

	// You stand on a sunlit floor (sun 30 degrees off vertical towards +x),
	// looking straight down. With Self shadow on, your body's shadow lies on
	// the floor on the -x side; the body itself is never drawn and the
	// viewmodel is never darkened by it.
	@(test)
	self_shadow_shows_your_shadow_only :: proc(t: ^testing.T) {
		logger := context.logger
		context = runtime.default_context()
		context.logger = logger
		if !testing.expect(t, bool(glfw.Init())) do return
		defer glfw.Terminate()
		test_gpu := test_gpu_open(SELF_SHADOW_W, SELF_SHADOW_H, "Self shadow")
		if !testing.expect(t, test_gpu.ok, "no GPU device for the test") do return
		defer test_gpu_close(&test_gpu, t)
		g_test_gpu = &test_gpu
		window := test_gpu.window

		config := shared.config_load_gameplay("assets/config/game.toml")
		defer shared.config_destroy_gameplay(config)
		map_inst, ok := shared.map_load_from_file("assets/maps/burg.json")
		if !testing.expect(t, ok && map_inst != nil) do return
		defer shared.map_destroy(map_inst)
		// A plain sun; the map's own meshes are not loaded, only the floor below.
		map_inst.lighting = shared.DEFAULT_LIGHTING_CONFIG
		map_inst.lighting.ambient_color, map_inst.lighting.ambient_intensity = {0.3, 0.3, 0.3}, 1
		map_inst.lighting.light_color, map_inst.lighting.light_intensity = {1, 1, 1}, 1
		map_inst.lighting.sun_angle_x, map_inst.lighting.sun_angle_y = 60, 90
		map_inst.lighting.fog_distance = 100000

		client := new(Client)
		defer free(client)
		g_client = client
		defer g_client = nil
		client.camera = {zoom = 1, fov = math.PI / 2, near = 0.1, far = 10000}
		client.visual_settings = menuui.DEFAULT_VISUAL_SETTINGS
		client.viewmodel_settings = menuui.DEFAULT_VIEWMODEL_SETTINGS
		client.viewport_width, client.viewport_height = SELF_SHADOW_W, SELF_SHADOW_H
		client.selected_secondary = 2
		client.scene = scene_init()
		client.fps_scene = scene_init()
		maps := []^shared.Map{map_inst}
		shared.game_configure(&client.game, &config.game, maps, nil, config.weapons, config.classes)
		shared.game_init(&client.game, 0, -1, true)
		old_lighting, old_visuals := g_lighting_config, g_visual_settings
		defer {
			g_lighting_config, g_visual_settings = old_lighting, old_visuals
			client_clear_players(client)
			shadow_fini()
			scene_fini(client.fps_scene)
			scene_fini(client.scene)
			shared.game_destroy(&client.game)
			resource_cache_fini()
		}

		floor_material := basic_material_init()
		floor_material.no_fog, floor_material.receive_shadow = true, true
		floor := mesh_init(create_cube_geo(), &floor_material.base)
		floor.transform.position, floor.transform.scale = {0, -1, 0}, {200, 1, 200}
		floor.shadow_caster = .STATIC
		scene_add_mesh(client.scene, floor)
		defer mesh_fini(floor)

		me := shared.player_init(&client.game)
		shared.game_players_add(&client.game, me)
		me.uid, me.is_you = 1, true
		shared.player_spawn(me, 0, client.selected_secondary)
		me.active = true
		player_generate_meshes(me, true)
		shared.player_swap_weapon(me, 0, true, false, false)
		scene_add_player_mesh(client.fps_scene, cast(^Player_Mesh)me.mesh, int(me.loadout_size))
		client.me = me
		me.position, me.direction = {0, 0, 0}, {0, 0}
		shared.player_update_height(me)
		client.camera.position = {0, 30, 0}
		client.camera.rotation = {-math.PI / 2, 0, 0}

		pixels := make([]u8, SELF_SHADOW_W * SELF_SHADOW_H * 3)
		baseline := make([]u8, len(pixels))
		without_viewmodel := make([]u8, len(pixels))
		defer { delete(pixels); delete(baseline); delete(without_viewmodel) }

		// Shadows off: your rig is never built and the frame equals the frame
		// with no local player at all, so the body is not in the colour pass.
		off := menuui.Quality_Settings{lighting = 1, self_shadow = true}
		self_shadow_frame(client, off, baseline)
		testing.expect(t, g_self_shadow.body == nil && g_shadow.player_renders == 0, "Shadows off must not build your shadow rig or run a player pass")
		client.me = nil
		for mesh in client.fps_scene.meshes { mesh.visible = false }
		self_shadow_frame(client, off, without_viewmodel)
		for mesh in client.fps_scene.meshes { mesh.visible = true }
		client.me = me

		// Shadow column: floor at x = -4 world (-x of your feet), image centre row.
		// Looking down with yaw 0, +x is to the right; 30 units up at 90 degrees
		// FOV, 64 px per 30 units.
		px := SELF_SHADOW_W / 2 - 8 // x = -4 world
		py := SELF_SHADOW_H / 2
		lit_px := SELF_SHADOW_W / 2 - 41 // x = -20 world

		on_self := menuui.Quality_Settings{shadows = true, lighting = 1, self_shadow = true}
		self_shadow_frame(client, on_self, pixels)
		testing.expect(t, g_self_shadow.body != nil && g_shadow.player_renders > 0 && g_shadow.casters_drawn > 0, "Self shadow must draw your rig into the player map")
		shadowed := self_shadow_luma(pixels, px, py)
		lit := self_shadow_luma(pixels, lit_px, py)
		testing.expect(t, shadowed + 60 < lit, fmt.tprintf("your shadow must darken the floor beside your feet (%d vs lit %d)", shadowed, lit))
		os.make_directory("bin/bench")
		stbi.write_png("bin/bench/self_shadow_test.png", SELF_SHADOW_W, SELF_SHADOW_H, 3, &pixels[(SELF_SHADOW_H - 1) * SELF_SHADOW_W * 3], -SELF_SHADOW_W * 3)

		// The rig is not in any colour pass.
		body := g_self_shadow.scene.meshes[:]
		for part in body {
			for mesh in client.scene.meshes { testing.expect(t, mesh != part, "your shadow rig must never be in the world scene") }
			for mesh in client.fps_scene.meshes { testing.expect(t, mesh != part, "your shadow rig must never be in the viewmodel scene") }
		}

		// The viewmodel's pixels are the same with and without Self shadow.
		self_off := on_self
		self_off.self_shadow = false
		players := g_shadow.player_renders
		off_pixels := make([]u8, len(pixels))
		defer delete(off_pixels)
		self_shadow_frame(client, self_off, off_pixels)
		testing.expect(t, g_shadow.player_renders == players && g_self_shadow.body == nil, "Self shadow off must skip the player pass and free the rig")
		testing.expect(t, self_shadow_luma(off_pixels, px, py) > shadowed + 60, "Self shadow off must leave the floor lit")
		viewmodel_pixels, viewmodel_differs := 0, 0
		for i in 0 ..< SELF_SHADOW_W * SELF_SHADOW_H {
			is_viewmodel := false
			for c in 0 ..< 3 { if baseline[i * 3 + c] != without_viewmodel[i * 3 + c] { is_viewmodel = true } }
			if !is_viewmodel { continue }
			viewmodel_pixels += 1
			for c in 0 ..< 3 { if pixels[i * 3 + c] != off_pixels[i * 3 + c] { viewmodel_differs += 1; break } }
		}
		testing.expect(t, viewmodel_pixels > 0 && viewmodel_differs == 0, fmt.tprintf("your shadow must not touch the viewmodel (%d of %d viewmodel pixels changed)", viewmodel_differs, viewmodel_pixels))

		// Crouching lowers the rig (continuous for you, like the viewmodel).
		me.crouch_val = 0.5
		self_shadow_frame(client, on_self, pixels)
		testing.expect(t, abs(player_rig_crouch(me) - 0.5) < 0.0001, "your own rig keeps its continuous crouch")
		me.crouch_val = 0

		// Sharp uses the same player map.
		sharp := on_self
		sharp.shadow_quality = 1
		self_shadow_frame(client, sharp, pixels)
		testing.expect(t, self_shadow_luma(pixels, px, py) + 60 < self_shadow_luma(pixels, lit_px, py), "Sharp must show your shadow too")
		testing.expect(t, test_gpu_no_error(), "Self shadow must not generate OpenGL errors")
	}
}
