package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import gl "vendor:OpenGL"
import glfw "vendor:glfw"
import stbi "vendor:stb/image"
import menuui "../menu"
import shared "../shared"

// `--bench <maps> <seconds> [--bench-size <sizes>]` renders each map from fixed
// spawn viewpoints into an offscreen framebuffer, once per Shadows/Lighting
// configuration, and prints frame-time statistics.
//
// Pacing: no vsync and no swap; at most BENCH_FRAMES_IN_FLIGHT frames are
// queued (fence wait), like an uncapped swap chain. Frame time is wall time
// between frame starts, so it reflects max(CPU, GPU) in steady state. CPU is
// the time spent submitting the frame; GPU is GL_TIME_ELAPSED for the frame.

BENCH_FRAMES_IN_FLIGHT :: 2
BENCH_QUERY_RING :: 8
BENCH_FRAMES_PER_VIEW :: 120
BENCH_WARMUP_FRAMES :: 30
BENCH_REMOTE_PLAYERS :: 6

Bench_Config :: struct {
	name:     string,
	quality:  menuui.Quality_Settings,
	batching: bool, // Static map batches (map_batch.odin).
	culling:  bool, // Frustum culling; only used on the batched path.
	soft_4tap: bool, // Krunker mode with Sharp's 4-tap soft kernel (cost comparison).
}

Bench_Result :: struct {
	map_name:    string,
	width:       i32,
	height:      i32,
	config:      string,
	frames:      int,
	avg_ms:      f64,
	p95_ms:      f64,
	p99_ms:      f64,
	cpu_avg_ms:  f64,
	gpu_avg_ms:  f64,
	gpu_p95_ms:  f64,
	extra_ms:    f64, // One-off GPU work when the configuration is applied (static shadow map).
	draw_calls:  f64, // Average draw calls per measured frame (world + viewmodel).
	culled:      f64, // Average map batches culled per frame.
}

// Static: bench_map frees the temp allocator after every configuration.
// Baseline is Shadows off with Lighting Normal (the renderer before these
// settings). Every row except the two per-object ones uses the default
// batched + culled path.
BENCH_CONFIGS := [?]Bench_Config{
	{name = "baseline: shadows off", quality = {lighting = 1}, batching = true, culling = true},
	{name = "Krunker default", quality = {shadows = true, lighting = 1}, batching = true, culling = true},
	{name = "Krunker + soft", quality = {shadows = true, soft_shadows = true, lighting = 1}, batching = true, culling = true},
	{name = "Krunker + soft (4-tap kernel)", quality = {shadows = true, soft_shadows = true, lighting = 1}, batching = true, culling = true, soft_4tap = true},
	{name = "Krunker + dynamic", quality = {shadows = true, dynamic_shadows = true, lighting = 1}, batching = true, culling = true},
	{name = "Krunker everything on", quality = {shadows = true, soft_shadows = true, high_res_shadows = true, dynamic_shadows = true, lighting = 3}, batching = true, culling = true},
	{name = "Krunker + self shadow", quality = {shadows = true, self_shadow = true, lighting = 1}, batching = true, culling = true},
	{name = "Sharp", quality = {shadows = true, shadow_quality = 1, lighting = 1}, batching = true, culling = true},
	{name = "Sharp + soft + dynamic", quality = {shadows = true, soft_shadows = true, dynamic_shadows = true, shadow_quality = 1, lighting = 1}, batching = true, culling = true},
	{name = "Sharp + self shadow", quality = {shadows = true, self_shadow = true, shadow_quality = 1, lighting = 1}, batching = true, culling = true},
}

bench_parse_size :: proc(text: string) -> (w, h: i32, ok: bool) {
	if text == "native" {
		mode := glfw.GetVideoMode(glfw.GetPrimaryMonitor())
		if mode == nil { return 0, 0, false }
		return mode.width, mode.height, true
	}
	parts := strings.split(text, "x", context.temp_allocator)
	if len(parts) != 2 { return 0, 0, false }
	width, w_ok := strconv.parse_int(parts[0])
	height, h_ok := strconv.parse_int(parts[1])
	if !w_ok || !h_ok || width < 16 || height < 16 || width > 16384 || height > 16384 { return 0, 0, false }
	return i32(width), i32(height), true
}

Bench_Target :: struct {
	fbo, color, depth: u32,
	width, height:     i32,
}

bench_target_init :: proc(w, h: i32) -> Bench_Target {
	target := Bench_Target{width = w, height = h}
	gl.CreateFramebuffers(1, &target.fbo)
	gl.CreateRenderbuffers(1, &target.color)
	gl.CreateRenderbuffers(1, &target.depth)
	gl.NamedRenderbufferStorage(target.color, gl.RGBA8, w, h)
	gl.NamedRenderbufferStorage(target.depth, gl.DEPTH24_STENCIL8, w, h)
	gl.NamedFramebufferRenderbuffer(target.fbo, gl.COLOR_ATTACHMENT0, gl.RENDERBUFFER, target.color)
	gl.NamedFramebufferRenderbuffer(target.fbo, gl.DEPTH_STENCIL_ATTACHMENT, gl.RENDERBUFFER, target.depth)
	return target
}

bench_target_fini :: proc(target: ^Bench_Target) {
	gl.DeleteFramebuffers(1, &target.fbo)
	gl.DeleteRenderbuffers(1, &target.color)
	gl.DeleteRenderbuffers(1, &target.depth)
	target^ = {}
}

bench_percentile :: proc(sorted: []f64, p: f64) -> f64 {
	if len(sorted) == 0 { return 0 }
	index := int(math.ceil(p * f64(len(sorted)))) - 1
	return sorted[clamp(index, 0, len(sorted) - 1)]
}

bench_mean :: proc(values: []f64) -> f64 {
	if len(values) == 0 { return 0 }
	sum: f64
	for value in values { sum += value }
	return sum / f64(len(values))
}

// View 0 is the map's menu camera looking at the map centre; views 1..5 are
// spawn points at eye height. Each view sweeps a full turn.
@(private = "file")
bench_viewpoint :: proc(client: ^Client, frame: int) {
	map_inst := client.game.map_inst
	me := client.me
	if me == nil { return }
	views := 1 + min(len(map_inst.spawns), 5)
	view := (frame / BENCH_FRAMES_PER_VIEW) % views
	phase := f32(frame % BENCH_FRAMES_PER_VIEW) / f32(BENCH_FRAMES_PER_VIEW)
	if view == 0 {
		p := map_inst.camera_position
		client.camera.position = p
		client.camera.rotation = {-0.35, math.atan2(p.x, p.z) + 0.6 * math.sin(phase * 2 * math.PI), 0}
		me.position = p - shared.Vec3{0, 9.5, 0}
	} else {
		spawn := map_inst.spawns[view - 1]
		me.position = spawn.position
		shared.player_update_height(me)
		client.camera.position = spawn.position
		client.camera.position.y += me.height - shared.GAME_CONSTANTS.camera_height
		client.camera.rotation = {-0.12 + 0.1 * math.sin(phase * 2 * math.PI), f32(spawn.direction) * math.PI / 2 + phase * 2 * math.PI, 0}
	}
	me.direction = {client.camera.rotation.x, client.camera.rotation.y}
	player_update_meshes(me, false)
}

@(private = "file")
bench_spawn_players :: proc(client: ^Client) {
	spawns := client.game.map_inst.spawns
	for index in 0 ..= BENCH_REMOTE_PLAYERS {
		render_you := index == 0
		player := shared.player_init(&client.game)
		shared.game_players_add(&client.game, player)
		player.uid = i32(index + 1)
		player.is_you = render_you
		player.render_you = render_you
		player.active = true
		shared.player_spawn(player, i32(index % max(1, len(client.game.classes))), client.selected_secondary)
		player_generate_meshes(player, render_you)
		shared.player_swap_weapon(player, 0, true, false, false)
		scene_add_player_mesh(render_you ? client.fps_scene : client.scene, cast(^Player_Mesh)player.mesh, int(player.loadout_size))
		if len(spawns) > 0 {
			// Remote players stand a few units in front of later spawns so most
			// viewpoints see at least one of them.
			spawn := spawns[(index + 1) % len(spawns)]
			player.position = spawn.position + shared.Vec3{8, 0, 8}
			player.direction = {0, f32(spawn.direction) * math.PI / 2}
		}
		if render_you { client.me = player }
		shared.player_update_height(player)
		for _ in 0 ..< 120 { shared.player_update_visual_animations(player, 1.0 / 60.0) }
		player_update_meshes(player, false)
	}
}

@(private = "file")
bench_frame :: proc(client: ^Client, target: ^Bench_Target, frame: int) {
	bench_viewpoint(client, frame)
	gl.BindFramebuffer(gl.FRAMEBUFFER, target.fbo)
	gl.Viewport(0, 0, target.width, target.height)
	client.viewport_width, client.viewport_height = target.width, target.height
	client.render_framebuffer = target.fbo
	client_render_world(client)
	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
}

@(private = "file")
bench_run_config :: proc(client: ^Client, target: ^Bench_Target, config: Bench_Config, seconds: f32, map_name: string) -> Bench_Result {
	client.quality_settings = config.quality
	client.visual_settings = menuui.DEFAULT_VISUAL_SETTINGS
	client.render_batching = config.batching
	g_render_culling = config.culling
	g_shadow_soft_kernel_override = config.soft_4tap
	defer g_shadow_soft_kernel_override = false
	defer g_render_culling = true
	result := Bench_Result{map_name = map_name, width = target.width, height = target.height, config = config.name}

	queries: [BENCH_QUERY_RING]u32
	gl.GenQueries(BENCH_QUERY_RING, &queries[0])
	defer gl.DeleteQueries(BENCH_QUERY_RING, &queries[0])
	fences: [BENCH_FRAMES_IN_FLIGHT]gl.sync_t
	defer for fence in fences { if fence != nil { gl.DeleteSync(fence) } }

	// The first frame applies the configuration; for static shadows this is
	// where the one-off shadow map render happens. Time it on its own.
	gl.Finish()
	gl.BeginQuery(gl.TIME_ELAPSED, queries[0])
	bench_frame(client, target, 0)
	gl.EndQuery(gl.TIME_ELAPSED)
	first_ns: u64
	gl.GetQueryObjectui64v(queries[0], gl.QUERY_RESULT, &first_ns)

	for frame in 1 ..= BENCH_WARMUP_FRAMES { bench_frame(client, target, frame) }
	gl.Finish()

	frame_ms := make([dynamic]f64, context.temp_allocator)
	cpu_ms := make([dynamic]f64, context.temp_allocator)
	gpu_ms := make([dynamic]f64, context.temp_allocator)
	pending: [BENCH_QUERY_RING]bool
	draw_sum, culled_sum: int
	start := time.tick_now()
	previous := start
	frame := 0
	for time.duration_seconds(time.tick_since(start)) < f64(seconds) {
		slot := frame % BENCH_QUERY_RING
		if pending[slot] {
			ns: u64
			gl.GetQueryObjectui64v(queries[slot], gl.QUERY_RESULT, &ns)
			append(&gpu_ms, f64(ns) / 1e6)
			pending[slot] = false
		}
		fence_slot := frame % BENCH_FRAMES_IN_FLIGHT
		if fences[fence_slot] != nil {
			gl.ClientWaitSync(fences[fence_slot], gl.SYNC_FLUSH_COMMANDS_BIT, 5_000_000_000)
			gl.DeleteSync(fences[fence_slot])
			fences[fence_slot] = nil
		}
		now := time.tick_now()
		if frame > 0 { append(&frame_ms, time.duration_milliseconds(time.tick_diff(previous, now))) }
		previous = now
		gl.BeginQuery(gl.TIME_ELAPSED, queries[slot])
		bench_frame(client, target, frame)
		gl.EndQuery(gl.TIME_ELAPSED)
		draw_sum += g_draw_stats.draw_calls
		culled_sum += g_draw_stats.batches_culled
		pending[slot] = true
		append(&cpu_ms, time.duration_milliseconds(time.tick_since(now)))
		fences[fence_slot] = gl.FenceSync(gl.SYNC_GPU_COMMANDS_COMPLETE, 0)
		gl.Flush()
		frame += 1
	}
	gl.Finish()
	for slot in 0 ..< BENCH_QUERY_RING {
		if !pending[slot] { continue }
		ns: u64
		gl.GetQueryObjectui64v(queries[slot], gl.QUERY_RESULT, &ns)
		append(&gpu_ms, f64(ns) / 1e6)
	}

	bench_screenshot(client, target, config.name, map_name)

	result.frames = len(frame_ms)
	result.draw_calls = f64(draw_sum) / f64(max(frame, 1))
	result.culled = f64(culled_sum) / f64(max(frame, 1))
	result.avg_ms = bench_mean(frame_ms[:])
	result.cpu_avg_ms = bench_mean(cpu_ms[:])
	result.gpu_avg_ms = bench_mean(gpu_ms[:])
	slice.sort(frame_ms[:])
	slice.sort(gpu_ms[:])
	result.p95_ms = bench_percentile(frame_ms[:], 0.95)
	result.p99_ms = bench_percentile(frame_ms[:], 0.99)
	result.gpu_p95_ms = bench_percentile(gpu_ms[:], 0.95)
	result.extra_ms = max(0, f64(first_ns) / 1e6 - result.gpu_avg_ms)
	return result
}

// One PNG per configuration from the same viewpoint, for checking by eye.
@(private = "file")
bench_screenshot :: proc(client: ^Client, target: ^Bench_Target, config_name, map_name: string) {
	// View 0 is the menu camera; view 1 a spawn at eye height.
	for view in 0 ..< 2 {
		bench_screenshot_view(client, target, config_name, map_name, view)
	}
}

@(private = "file")
bench_screenshot_view :: proc(client: ^Client, target: ^Bench_Target, config_name, map_name: string, view: int) {
	frame := view * BENCH_FRAMES_PER_VIEW + 8
	for warm in 0 ..< 3 { bench_frame(client, target, frame - 3 + warm) }
	bench_frame(client, target, frame)
	w, h := target.width, target.height
	pixels := make([]u8, int(w * h * 3), context.temp_allocator)
	gl.BindFramebuffer(gl.READ_FRAMEBUFFER, target.fbo)
	gl.PixelStorei(gl.PACK_ALIGNMENT, 1)
	gl.ReadPixels(0, 0, w, h, gl.RGB, gl.UNSIGNED_BYTE, raw_data(pixels))
	gl.BindFramebuffer(gl.READ_FRAMEBUFFER, 0)
	slug := strings.builder_make(context.temp_allocator)
	for r in config_name {
		switch r {
		case 'a'..='z', 'A'..='Z', '0'..='9': strings.write_rune(&slug, r)
		case: if !strings.has_suffix(strings.to_string(slug), "-") { strings.write_byte(&slug, '-') }
		}
	}
	os.make_directory("bin/bench")
	path := fmt.ctprintf("bin/bench/%s_%dx%d_view%d_%s.png", map_name, w, h, view, strings.trim(strings.to_string(slug), "-"))
	// GL rows are bottom-up; write with a negative stride from the last row.
	stbi.write_png(path, w, h, 3, &pixels[int((h - 1) * w * 3)], -w * 3)
}

@(private = "file")
bench_map :: proc(client: ^Client, config: ^shared.Gameplay_Config, map_name: string, sizes: [][2]i32, results: ^[dynamic]Bench_Result) -> bool {
	path := shared.concat(shared.assets_path(), fmt.tprintf("maps/%s.json", shared.map_asset_name(map_name)))
	map_inst, ok := shared.map_load_from_file(path)
	delete(path)
	if !ok {
		fmt.eprintf("[Bench] Could not load map %s\n", map_name)
		return false
	}
	defer shared.map_destroy(map_inst)
	maps := []^shared.Map{map_inst}
	shared.game_configure(&client.game, &config.game, maps, nil, config.weapons, config.classes)
	shared.game_init(&client.game, 0, -1, true)
	defer {
		client_clear_players(client)
		client_unload_map(client)
		client.game.map_inst = nil
		client.game.maps_list = nil
		client.game.map_count = 0
	}
	if !client.game.ready { return false }
	// Build the batches once; each configuration only switches the draw path.
	client.render_batching = true
	client_load_current_map(client)
	bench_spawn_players(client)
	fmt.printf("[Bench] %s: %d objects, %d world meshes, %d spawns\n", map_name, len(map_inst.objects), len(client.scene.meshes), len(map_inst.spawns))
	if set := client.scene.batches; set != nil {
		fmt.printf("[Bench] %s: %d draw slots; %d meshes merged (%d vertices, %d indices), %d drawn singly (%d of them for depth ties)\n", map_name, len(set.batches), set.merged, set.vertex_count, set.index_count, set.singles, set.tie_excluded)
	}

	for size in sizes {
		target := bench_target_init(size[0], size[1])
		defer bench_target_fini(&target)
		for bench_config in BENCH_CONFIGS {
			result := bench_run_config(client, &target, bench_config, client.bench_seconds, map_name)
			append(results, result)
			fmt.printf("[Bench] %-12s %4dx%-4d %-34s avg %7.3f ms (%6.1f FPS)  p95 %7.3f  p99 %7.3f  cpu %6.3f  gpu %6.3f (p95 %6.3f)  one-off %6.3f ms  draws %7.1f  [%d frames]\n",
				map_name, size[0], size[1], result.config, result.avg_ms, 1000 / max(result.avg_ms, 0.0001), result.p95_ms, result.p99_ms,
				result.cpu_avg_ms, result.gpu_avg_ms, result.gpu_p95_ms, result.extra_ms, result.draw_calls, result.frames)
			free_all(context.temp_allocator)
		}
	}
	return true
}

bench_run :: proc(map_list: string, seconds: f32, size_list: string) -> int {
	if !bool(glfw.Init()) {
		fmt.eprintln("[Bench] GLFW initialization failed")
		return 1
	}
	defer glfw.Terminate()
	glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)
	glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
	glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
	glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 5)
	window := glfw.CreateWindow(64, 64, "SR Client bench", nil, nil)
	if window == nil {
		fmt.eprintln("[Bench] Could not create a hidden OpenGL 4.5 window")
		return 1
	}
	defer glfw.DestroyWindow(window)
	glfw.MakeContextCurrent(window)
	glfw.SwapInterval(0)
	gl.load_up_to(4, 5, glfw.gl_set_proc_address)
	gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)

	sizes := make([dynamic][2]i32, context.allocator)
	defer delete(sizes)
	for text in strings.split(len(size_list) > 0 ? size_list : "native", ",", context.allocator) {
		w, h, ok := bench_parse_size(strings.trim_space(text))
		if !ok {
			fmt.eprintf("[Bench] Invalid size: %s\n", text)
			return 1
		}
		append(&sizes, [2]i32{w, h})
	}

	renderer := string(cstring(gl.GetString(gl.RENDERER)))
	version := string(cstring(gl.GetString(gl.VERSION)))
	fmt.printf("[Bench] GL_RENDERER: %s\n[Bench] GL_VERSION: %s\n", renderer, version)

	client := new(Client)
	defer free(client)
	g_client = client
	defer g_client = nil
	client.window = window
	client.camera = {zoom = 1, fov = menuui.DEFAULT_FOV * math.PI / 180, near = 0.1, far = 10000}
	client.sensitivity = 1
	client.visual_settings = menuui.DEFAULT_VISUAL_SETTINGS
	client.viewmodel_settings = menuui.DEFAULT_VIEWMODEL_SETTINGS
	client.selected_secondary = 2
	client.bench_seconds = seconds
	client.render_batching = true
	client_graphics_init(client)
	defer client_graphics_fini(client)
	client.scene = scene_init()
	client.fps_scene = scene_init()
	defer {
		shadow_fini()
		scene_fini(client.fps_scene)
		scene_fini(client.scene)
		resource_cache_fini()
	}

	config_path := shared.concat(shared.assets_path(), "config/game.toml")
	defer delete(config_path)
	config := shared.config_load_gameplay(config_path)
	defer shared.config_destroy_gameplay(config)
	defer shared.game_destroy(&client.game)

	results := make([dynamic]Bench_Result)
	defer delete(results)
	for name in strings.split(map_list, ",", context.allocator) {
		trimmed := strings.trim_space(name)
		if !map_name_is_valid(trimmed) {
			fmt.eprintf("[Bench] Unknown map: %s\n", trimmed)
			return 1
		}
		if !bench_map(client, config, trimmed, sizes[:], &results) { return 1 }
	}

	// Markdown table for pasting into a PR.
	fmt.printf("\nGPU: %s\n\n", renderer)
	fmt.println("| Map | Resolution | Configuration | Avg ms | FPS | p95 ms | p99 ms | CPU ms | GPU ms | GPU p95 ms | One-off ms | Draw calls |")
	fmt.println("|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
	for r in results {
		fmt.printf("| %s | %dx%d | %s | %.3f | %.0f | %.3f | %.3f | %.3f | %.3f | %.3f | %.3f | %.0f |\n",
			r.map_name, r.width, r.height, r.config, r.avg_ms, 1000 / max(r.avg_ms, 0.0001), r.p95_ms, r.p99_ms, r.cpu_avg_ms, r.gpu_avg_ms, r.gpu_p95_ms, r.extra_ms, r.draw_calls)
	}
	csv := strings.builder_make(context.temp_allocator)
	strings.write_string(&csv, "map,width,height,config,frames,avg_ms,p95_ms,p99_ms,cpu_avg_ms,gpu_avg_ms,gpu_p95_ms,one_off_ms,draw_calls,batches_culled\n")
	for r in results {
		fmt.sbprintf(&csv, "%s,%d,%d,%s,%d,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.1f,%.1f\n", r.map_name, r.width, r.height, r.config, r.frames, r.avg_ms, r.p95_ms, r.p99_ms, r.cpu_avg_ms, r.gpu_avg_ms, r.gpu_p95_ms, r.extra_ms, r.draw_calls, r.culled)
	}
	if os.write_entire_file("bin/bench-results.csv", transmute([]u8)strings.to_string(csv)) == nil {
		fmt.println("\n[Bench] Wrote bin/bench-results.csv")
	}
	return 0
}
