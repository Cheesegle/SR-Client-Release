package main

import "core:fmt"
import "core:math"
import "core:time"
import gl "vendor:OpenGL"
import menuui "../menu"
import shared "../shared"

// Driver safety net for static map batching (map_batch.odin).
//
// The batched shader path is checked three ways before a session uses it:
//   1. GL limits it needs (vertex-stage storage buffers) are present;
//   2. the linked program lays out the storage buffer the way Batch_Object
//      packs it (program introspection, no rendering);
//   3. after the first map's batches are built, one small view is rendered
//      both batched and per object into an offscreen target and compared.
// Any failure turns batching off for the rest of the session with one log
// line; the per-object path then draws the map as `--no-batching` does.

// Non-empty when the linked batched program's storage-buffer layout does not
// match Batch_Object. Set by basic_batched_program.
g_map_batch_shader_layout_reason: string

when ODIN_TEST {
	// Test builds only: map_batch_build zeroes every object transform, the
	// way a driver that misreads the storage buffer would draw the map.
	g_map_batch_fault_inject: bool
}

// Offscreen size of the self-test render: ~58k pixels, two renders and two
// readbacks once per session.
MAP_BATCH_SELF_TEST_WIDTH :: 320
MAP_BATCH_SELF_TEST_HEIGHT :: 180

// Returns "" when the current context offers what the batched shader needs.
map_batch_limits_reason :: proc() -> string {
	if g_gpu_backend == .Vulkan { return "" } // Vulkan 1.3 guarantees vertex storage buffers.
	vertex_blocks, bindings: i32
	block_size: i64 // May exceed 2^31.
	gl.GetIntegerv(gl.MAX_VERTEX_SHADER_STORAGE_BLOCKS, &vertex_blocks)
	gl.GetIntegerv(gl.MAX_SHADER_STORAGE_BUFFER_BINDINGS, &bindings)
	gl.GetInteger64v(gl.MAX_SHADER_STORAGE_BLOCK_SIZE, &block_size)
	if vertex_blocks < 1 {
		return fmt.tprintf("GL_MAX_VERTEX_SHADER_STORAGE_BLOCKS is %d", vertex_blocks)
	}
	if bindings < 1 {
		return fmt.tprintf("GL_MAX_SHADER_STORAGE_BUFFER_BINDINGS is %d", bindings)
	}
	if block_size < size_of(Batch_Object) {
		return fmt.tprintf("GL_MAX_SHADER_STORAGE_BLOCK_SIZE is %d", block_size)
	}
	return ""
}

// Returns "" when the driver placed `objects` at offset 0 of binding 0 with a
// 16-byte stride, as map_batch_build packs Batch_Object records.
map_batch_program_layout_reason :: proc(program: u32) -> string {
	if g_gpu_backend == .Vulkan { return "" } // SPIR-V layouts are fixed at compile time.
	block := gl.GetProgramResourceIndex(program, gl.SHADER_STORAGE_BLOCK, "Batch_Objects")
	if block == gl.INVALID_INDEX {
		return "batched shader has no Batch_Objects block"
	}
	binding_prop := u32(gl.BUFFER_BINDING)
	binding := i32(-1)
	gl.GetProgramResourceiv(program, gl.SHADER_STORAGE_BLOCK, block, 1, &binding_prop, 1, nil, &binding)
	if binding != 0 {
		return fmt.tprintf("Batch_Objects is bound to %d, not 0", binding)
	}
	variable := gl.GetProgramResourceIndex(program, gl.BUFFER_VARIABLE, "objects[0]")
	if variable == gl.INVALID_INDEX {
		variable = gl.GetProgramResourceIndex(program, gl.BUFFER_VARIABLE, "Batch_Objects.objects[0]")
	}
	if variable == gl.INVALID_INDEX {
		return "batched shader has no objects[] buffer variable"
	}
	props := [2]u32{gl.OFFSET, gl.ARRAY_STRIDE}
	values := [2]i32{-1, -1}
	gl.GetProgramResourceiv(program, gl.BUFFER_VARIABLE, variable, 2, &props[0], 2, nil, &values[0])
	if values[0] != 0 || values[1] != 16 {
		return fmt.tprintf("objects[] has offset %d and stride %d, expected 0 and 16", values[0], values[1])
	}
	return ""
}

// Batched vs per-object pixel comparison. A pixel counts when a channel
// differs by more than 1. Where both renders stored the same depth, two
// coincident surfaces tied and draw order picked the colour (a few such
// pixels along contact lines are expected); elsewhere geometry differs.
Map_Batch_Compare :: struct {
	max_diff:          int,
	max_geometry_diff: int,
	tie_pixels:        int,
	geometry_pixels:   int,
	first_geometry:    int, // Pixel index, -1 if none.
}

map_batch_compare :: proc(off, on: []u8, depth_off, depth_on: []u32) -> Map_Batch_Compare {
	result := Map_Batch_Compare{first_geometry = -1}
	pixels := min(len(off), len(on)) / 3
	for pixel in 0 ..< pixels {
		d := 0
		for c in 0 ..< 3 { d = max(d, abs(int(off[pixel * 3 + c]) - int(on[pixel * 3 + c]))) }
		result.max_diff = max(result.max_diff, d)
		if d <= 1 { continue }
		if depth_off != nil && depth_on != nil && depth_off[pixel] == depth_on[pixel] {
			result.tie_pixels += 1
		} else {
			result.geometry_pixels += 1
			result.max_geometry_diff = max(result.max_geometry_diff, d)
			if result.first_geometry < 0 { result.first_geometry = pixel }
		}
	}
	return result
}

// The self-test's tolerance. The equality test sees at most 32 depth-tie
// pixels in a 1280x720 frame (0.0035%) and no others on a correct driver;
// a driver bug (missing, misplaced or wrongly textured objects) changes far
// more. Allow 0.1% ties and 0.05% other pixels so precision noise on other
// drivers cannot switch batching off.
map_batch_self_test_within_tolerance :: proc(compare: Map_Batch_Compare, pixel_count: int) -> bool {
	return compare.tie_pixels <= pixel_count / 1000 && compare.geometry_pixels <= pixel_count / 2000
}

// The menu camera, looking down at the map centre (bench and equality test view 0).
map_batch_self_test_camera :: proc(map_inst: ^shared.Map) -> Camera {
	camera := camera_init(menuui.DEFAULT_FOV * math.PI / 180)
	p := map_inst.camera_position
	camera.position, camera.rotation = p, {-0.35, math.atan2(p.x, p.z), 0}
	return camera
}

// Self-test renders so far this session (diagnostics and tests).
g_map_batch_self_tests: int

// Renders one small view batched and per object and compares them. Culling is
// off for both renders, so every batch is drawn once. GL bindings that the
// frame loop relies on (framebuffer, viewport, pack alignment) are restored.
// `ran` is false when the scene has no batch geometry to test.
//
// Both renders use one fixed, plain configuration: Normal lighting, no shadow
// sampling, night tints neutral. Map loads happen before the frame that
// prepares shadows and night lighting, so the live values may still describe
// the previous map; and with shadows on, each path would first have to draw
// its own shadow map (the batched depth pass vs per object), where a depth tie
// on a caster can move a soft shadow edge by a texel and fail the comparison
// for no visible reason. The batched depth pass reads the same per-vertex
// layout as the colour pass tested here, and the equality test covers the
// shadowed and night renders pixel for pixel.
map_batch_self_test :: proc(scene: ^Scene, map_inst: ^shared.Map) -> (passed: bool, compare: Map_Batch_Compare, ran: bool) {
	g_map_batch_self_tests += 1
	if scene == nil || map_inst == nil || scene.batches == nil || scene.batches.input == 0 {
		return true, {}, false
	}
	w, h := i32(MAP_BATCH_SELF_TEST_WIDTH), i32(MAP_BATCH_SELF_TEST_HEIGHT)
	pixel_count := int(w * h)
	off := make([]u8, pixel_count * 3)
	on := make([]u8, pixel_count * 3)
	depth_off := make([]u32, pixel_count)
	depth_on := make([]u32, pixel_count)
	defer {
		delete(off)
		delete(on)
		delete(depth_off)
		delete(depth_on)
	}

	// Map loads happen between frames, with the window as the target.
	restore_target, restore_w, restore_h := g_client != nil ? g_client.render_target : 0, i32(0), i32(0)
	if g_client != nil { restore_w, restore_h = g_client.viewport_width, g_client.viewport_height }
	saved_stats, saved_culling, saved_enabled := g_draw_stats, g_render_culling, scene.batching_enabled
	saved_quality, saved_low_tint, saved_unlit_tint := g_render_quality, g_night_low_tint, g_night_unlit_tint
	target := gpu_render_target_create(w, h)
	defer {
		gpu_render_target_destroy(&target)
		gpu_set_target(restore_target, restore_w, restore_h)
		g_draw_stats, g_render_culling, scene.batching_enabled = saved_stats, saved_culling, saved_enabled
		g_render_quality, g_night_low_tint, g_night_unlit_tint = saved_quality, saved_low_tint, saved_unlit_tint
	}

	camera := map_batch_self_test_camera(map_inst)
	g_render_culling = false
	g_render_quality = Render_Quality{lighting = .NORMAL}
	g_night_low_tint, g_night_unlit_tint = {1, 1, 1}, {1, 1, 1}
	gpu_set_target(target, w, h)
	batch_draws := 0
	for batched in ([2]bool{false, true}) {
		scene.batching_enabled = batched
		g_draw_stats = {}
		gpu_clear(color = true, depth = true)
		scene_render(scene, &camera, f32(w), f32(h), 0)
		gpu_read_color_rgb(target, w, h, batched ? on : off)
		gpu_read_depth(target, w, h, batched ? depth_on : depth_off)
		if batched { batch_draws = g_draw_stats.batch_draws }
	}
	if batch_draws == 0 {
		return true, {}, false
	}
	compare = map_batch_compare(off, on, depth_off, depth_on)
	return map_batch_self_test_within_tolerance(compare, pixel_count), compare, true
}

map_batch_renderer_name :: proc() -> string {
	return gpu_device_name()
}

// Turns batching off for the session and logs why, once.
map_batch_disable :: proc(client: ^Client, reason: string, detail := "") {
	map_batch_destroy(client.scene)
	client.render_batching = false
	if client.scene != nil { client.scene.batching_enabled = false }
	fmt.printf("[Render] Batching disabled: %s on %s%s\n", reason, map_batch_renderer_name(), detail)
}

// Builds the map batches when batching is on, running the support checks and,
// for the first map of the session, the render self-test.
client_build_map_batches :: proc(client: ^Client) {
	map_batch_destroy(client.scene)
	if !client.render_batching || client.game.map_inst == nil {
		return
	}
	if reason := map_batch_limits_reason(); reason != "" {
		map_batch_disable(client, reason)
		return
	}
	phase_mark(.BATCH_BUILD)
	if !map_batch_build(client.scene, client.game.map_inst) {
		if basic_batched_shader_program == 0 {
			map_batch_disable(client, "batched shader did not compile")
		} else if g_map_batch_shader_layout_reason != "" {
			map_batch_disable(client, g_map_batch_shader_layout_reason)
		}
		return
	}
	if client.batch_self_test_done {
		return
	}
	phase_mark(.BATCH_SELF_TEST)
	start := time.tick_now()
	passed, compare, ran := map_batch_self_test(client.scene, client.game.map_inst)
	elapsed_ms := time.duration_milliseconds(time.tick_since(start))
	if !ran {
		return // No merged batch was drawn (only single slots); the next map tries again.
	}
	client.batch_self_test_done = true
	if !passed {
		map_batch_disable(client, "self-test mismatch", fmt.tprintf(" (%d depth-tie and %d other pixels of %d differ, max diff %d)",
			compare.tie_pixels, compare.geometry_pixels, MAP_BATCH_SELF_TEST_WIDTH * MAP_BATCH_SELF_TEST_HEIGHT, compare.max_diff))
		return
	}
	fmt.printf("[Render] Batching self-test passed on %s (%d depth-tie pixels, %.1f ms)\n", map_batch_renderer_name(), compare.tie_pixels, elapsed_ms)
}
