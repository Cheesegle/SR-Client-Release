package main

import "core:fmt"
import "core:math"
import "core:strings"
import gl "vendor:OpenGL"
import glfw "vendor:glfw"
import menuui "../menu"
import shared "../shared"

// `--asset-sweep <manifest.txt>` loads everything a tester session can show
// through the normal loaders, with asset tracing on, and writes:
//   <manifest>.txt                   every file that was opened, sorted
//   <manifest>-missing.txt           required files that could not be opened
//   <manifest>-optional-missing.txt  probes with a fallback (texture variants, sky captures)
// Exit codes: 0 complete, 1 the sweep could not run, 2 required files are missing.
ASSET_SWEEP_EXIT_FAILED :: 1
ASSET_SWEEP_EXIT_MISSING :: 2

asset_sweep_output_paths :: proc(manifest: string) -> (missing, optional: string) {
	base := strings.trim_suffix(manifest, ".txt")
	return fmt.tprintf("%s-missing.txt", base), fmt.tprintf("%s-optional-missing.txt", base)
}

asset_sweep_run :: proc(manifest: string) -> int {
	g_gpu_backend = .OpenGL // the sweep renders in its own hidden GL context
	shared.asset_trace_begin()
	defer shared.asset_trace_end()

	if !bool(glfw.Init()) {
		fmt.eprintln("[Sweep] GLFW initialization failed")
		return ASSET_SWEEP_EXIT_FAILED
	}
	defer glfw.Terminate()
	glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)
	glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
	glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
	glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 5)
	window := glfw.CreateWindow(1280, 720, "SR Client asset sweep", nil, nil)
	if window == nil {
		fmt.eprintln("[Sweep] Could not create a hidden OpenGL 4.5 window")
		return ASSET_SWEEP_EXIT_FAILED
	}
	defer glfw.DestroyWindow(window)
	glfw.MakeContextCurrent(window)
	gl.load_up_to(4, 5, glfw.gl_set_proc_address)
	gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)

	client := new(Client)
	defer free(client)
	g_client = client
	defer g_client = nil
	client.window = window
	client.viewport_width, client.viewport_height = 1280, 720
	client.camera = {zoom = 1, fov = math.PI / 2, near = 0.1, far = 10000}
	client.sensitivity = 1
	client.audio_settings = DEFAULT_AUDIO_SETTINGS
	client.visual_settings = menuui.DEFAULT_VISUAL_SETTINGS
	client.selected_secondary = 2

	set_window_icon(client)
	client_graphics_init(client)
	defer client_graphics_fini(client)
	client.scene = scene_init()
	client.fps_scene = scene_init()
	client.ui = ui_init()
	if client.scene == nil || client.fps_scene == nil || client.ui == nil || !menuui.init(&client.menu, menu_measure_text, client.ui) {
		fmt.eprintln("[Sweep] Could not initialize the renderer or menu")
		return ASSET_SWEEP_EXIT_FAILED
	}
	defer {
		menuui.fini(&client.menu)
		scene_fini(client.fps_scene)
		scene_fini(client.scene)
		overlay_fini()
		ui_fini(client.ui)
		delete(menu_portraits)
		menu_portraits = nil
		resource_cache_fini()
	}

	config_path := shared.concat(shared.assets_path(), "config/game.toml")
	defer delete(config_path)
	config := shared.config_load_gameplay(config_path)
	defer shared.config_destroy_gameplay(config)
	// No output device: samples still decode, so every sound file is opened.
	client.audio = audio_create(config.weapons, client.audio_settings, no_device = true)
	defer audio_destroy(client.audio)
	client.game.presentation_enabled = client.audio != nil
	defer shared.game_destroy(&client.game)

	// Players, HUD and menus are independent of the map, so they are swept on
	// the first map only. Each map is freed before the next one loads.
	for name, index in shared.DEFAULT_MAP_NAMES {
		asset_sweep_map(client, config, name, index == 0)
		free_all(context.temp_allocator)
	}

	missing_path, optional_path := asset_sweep_output_paths(manifest)
	trace := &shared.g_asset_trace
	if !shared.asset_trace_write_list(manifest, trace.used) ||
	   !shared.asset_trace_write_list(missing_path, trace.missing) ||
	   !shared.asset_trace_write_list(optional_path, trace.optional_miss) {
		fmt.eprintf("[Sweep] Could not write %s\n", manifest)
		return ASSET_SWEEP_EXIT_FAILED
	}
	fmt.printf("[Sweep] %d files used, %d required files missing, %d optional probes missing\n",
		len(trace.used), len(trace.missing), len(trace.optional_miss))
	fmt.printf("[Sweep] Wrote %s, %s and %s\n", manifest, missing_path, optional_path)
	for path in shared.asset_trace_sorted(trace.missing) {
		fmt.eprintf("[Sweep] missing: %s\n", path)
	}
	return len(trace.missing) > 0 ? ASSET_SWEEP_EXIT_MISSING : 0
}

@(private = "file")
asset_sweep_map :: proc(client: ^Client, config: ^shared.Gameplay_Config, name: string, with_players: bool) {
	path := shared.concat(shared.assets_path(), fmt.tprintf("maps/%s.json", shared.map_asset_name(name)))
	map_inst, ok := shared.map_load_from_file(path)
	delete(path)
	if !ok { return }
	defer shared.map_destroy(map_inst)

	// Same setup as `--map <name>`: a one-map list owned by this scope.
	maps := []^shared.Map{map_inst}
	shared.game_configure(&client.game, &config.game, maps, nil, config.weapons, config.classes)
	shared.game_init(&client.game, 0, -1, true)
	if client.game.ready {
		client_load_current_map(client)
		if with_players { asset_sweep_players(client) }
	}
	client_clear_players(client)
	client_unload_map(client)
	client.game.map_inst = nil
	client.game.maps_list = nil
	client.game.map_count = 0
}

@(private = "file")
asset_sweep_players :: proc(client: ^Client) {
	// Lobby: every class portrait plus primary and secondary icons.
	ui_update(client.ui, f32(client.viewport_width), f32(client.viewport_height))
	view := menu_view(client)
	menu_render_commands(client.ui, menuui.build(&client.menu, view, {}, client.ui.width, client.ui.height, 0))

	// HUD art that does not depend on the loadout.
	overlay_scope_render(client.ui)
	if texture, use_source := bullet_hole_texture(); use_source { texture_release(texture) }
	krunker_client_add_explosion(client, {}, 10)
	krunker_client_clear_explosions(client)

	// Each class with its own loadout, as the local viewmodel and as a remote
	// player, with the HUD drawn for the local one.
	for _, class_index in client.game.classes {
		asset_sweep_player(client, i32(class_index), -1, true)
		asset_sweep_player(client, i32(class_index), -1, false)
	}
	// Every weapon, melee and secondary the server could hand a player.
	for weapon, weapon_id in client.game.weapons {
		if weapon == nil { continue }
		asset_sweep_player(client, 0, i32(weapon_id), true)
		asset_sweep_player(client, 0, i32(weapon_id), false)
	}
}

@(private = "file")
asset_sweep_player :: proc(client: ^Client, class_index, weapon_id: i32, render_you: bool) {
	player := shared.player_init(&client.game)
	shared.game_players_add(&client.game, player)
	player.uid = 1
	player.is_you = render_you
	shared.player_spawn(player, class_index, client.selected_secondary)
	if weapon_id >= 0 && player.loadout_size > 0 { player.loadout[0] = weapon_id }
	player_generate_meshes(player, render_you)
	shared.player_swap_weapon(player, 0, true, false, false)
	scene_add_player_mesh(render_you ? client.fps_scene : client.scene, cast(^Player_Mesh)player.mesh, int(player.loadout_size))

	if render_you {
		client.me = player
		ui_update(client.ui, f32(client.viewport_width), f32(client.viewport_height))
		overlay_render(client, 0)
		// Every sound effect, with both alternating variants.
		for kind in shared.Presentation_Kind {
			for variant in 0 ..< 2 {
				client_audio_present(client, {kind = kind, uid = player.uid, weapon_id = player.loadout[0], headshot = variant == 1})
			}
		}
	}
	client_clear_players(client)
}
