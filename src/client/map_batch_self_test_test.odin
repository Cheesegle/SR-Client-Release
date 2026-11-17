package main

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"
import "core:math/linalg"
import gl "vendor:OpenGL"
import glfw "vendor:glfw"
import shared "../shared"

when ODIN_TEST {
	// CPU side of the storage-buffer contract: every Batch_Object field is a
	// whole number of vec4 slots, the generated #defines name those slots, the
	// shader reads every slot through them, and the bytes of a packed record
	// sit where the shader's objects[i * BATCH_OBJECT_VEC4S + slot] reads them.
	@(test)
	map_batch_ssbo_layout_matches_shader :: proc(t: ^testing.T) {
		testing.expect_value(t, size_of(Batch_Object), 160)
		testing.expect_value(t, BATCH_OBJECT_VEC4S, 10)
		Slot :: struct { name: string, offset: uintptr, vec4s: int }
		slots := [?]Slot{
			{"BATCH_SLOT_TRANSFORM", offset_of(Batch_Object, transform), 4},
			{"BATCH_SLOT_COLOR", offset_of(Batch_Object, color), 1},
			{"BATCH_SLOT_EMISSIVE", offset_of(Batch_Object, emissive), 1},
			{"BATCH_SLOT_FACE_SCALE", offset_of(Batch_Object, face_scale), 1},
			{"BATCH_SLOT_TEX_ROW0", offset_of(Batch_Object, tex_row0), 1},
			{"BATCH_SLOT_TEX_ROW1", offset_of(Batch_Object, tex_row1), 1},
			{"BATCH_SLOT_PARAMS", offset_of(Batch_Object, params), 1},
		}
		defines := map_batch_shader_defines()
		defer delete(defines)
		vert, vert_ok := shared.read_file("assets/shaders/basic.vert")
		defer delete(vert)
		if !testing.expect(t, vert_ok, "basic.vert must be readable") do return
		total := 0
		for slot in slots {
			testing.expect(t, slot.offset % 16 == 0, fmt.tprintf("%s must start on a vec4 boundary", slot.name))
			testing.expect(t, strings.contains(defines, fmt.tprintf("#define %s %d\n", slot.name, slot.offset / 16)), fmt.tprintf("%s define must match offset_of", slot.name))
			testing.expect(t, strings.contains(string(vert), slot.name), fmt.tprintf("basic.vert must read %s", slot.name))
			total += slot.vec4s
		}
		testing.expect_value(t, total, BATCH_OBJECT_VEC4S) // Fields tile the record.
		testing.expect(t, strings.has_prefix(defines, "#define BATCHED\n"))
		testing.expect(t, strings.contains(defines, "#define BATCH_OBJECT_VEC4S 10\n"))
		testing.expect(t, strings.contains(string(vert), "vec4 objects[];"), "basic.vert must declare the buffer as a vec4 array")

		// Pack two records and read them back as the shader indexes them.
		material := Basic_Material{face_mask = 0x15, color = {0.1, 0.2, 0.3, 0.4}, emissive = {1, 1, 1, 1}, face_scale = {3, 4, 5}, texture_scale = 2, alpha_test = 0.5, texture_repeat = {1, 1}, unlit = true, receive_shadow = true}
		transform := linalg.matrix4_translate_f32({7, 8, 9}) * linalg.matrix4_scale_f32({2, 3, 4})
		records := [2]Batch_Object{{}, batch_object_from_material(&material, transform, .STATIC)}
		floats := transmute([2 * 40]f32)records
		object := 1
		vec4 :: proc(floats: []f32, index: int) -> shared.Vec4 { return {floats[index * 4], floats[index * 4 + 1], floats[index * 4 + 2], floats[index * 4 + 3]} }
		base := object * BATCH_OBJECT_VEC4S
		for column in 0 ..< 4 {
			// mat4(objects[base + 0..3]) takes columns, as glUniformMatrix4fv does.
			got := vec4(floats[:], base + int(offset_of(Batch_Object, transform) / 16) + column)
			testing.expect(t, got == shared.Vec4{transform[0, column], transform[1, column], transform[2, column], transform[3, column]}, fmt.tprintf("transform column %d", column))
		}
		testing.expect(t, vec4(floats[:], base + int(offset_of(Batch_Object, color) / 16)) == material.color)
		testing.expect(t, vec4(floats[:], base + int(offset_of(Batch_Object, face_scale) / 16)) == shared.Vec4{3, 4, 5, 2})
		testing.expect(t, vec4(floats[:], base + int(offset_of(Batch_Object, params) / 16)) == shared.Vec4{0x15, BATCH_FLAG_UNLIT | BATCH_FLAG_RECEIVE_SHADOW | BATCH_FLAG_CAST_SHADOW, 0.5, 0})
		// Shadow flags live in params.y with the other bits; casters only with .STATIC.
		testing.expect_value(t, batch_object_from_material(&material, transform, .NONE).params.y, f32(BATCH_FLAG_UNLIT | BATCH_FLAG_RECEIVE_SHADOW))
		testing.expect_value(t, batch_object_from_material(&material, transform, .DYNAMIC).params.y, f32(BATCH_FLAG_UNLIT | BATCH_FLAG_RECEIVE_SHADOW))
		// The shaders test these bits through generated defines, not literals.
		testing.expect(t, strings.contains(defines, fmt.tprintf("#define BATCH_FLAG_RECEIVE_SHADOW %d\n", BATCH_FLAG_RECEIVE_SHADOW)))
		testing.expect(t, strings.contains(defines, fmt.tprintf("#define BATCH_FLAG_CAST_SHADOW %d\n", BATCH_FLAG_CAST_SHADOW)))
		testing.expect(t, strings.contains(string(vert), "BATCH_FLAG_CAST_SHADOW"), "the batched depth pass must test the cast flag")
		frag, frag_ok := shared.read_file("assets/shaders/basic.frag")
		defer delete(frag)
		testing.expect(t, frag_ok && strings.contains(string(frag), "BATCH_FLAG_RECEIVE_SHADOW"), "basic.frag must test the receive flag")
		testing.expect(t, floats[base * 4 + 12] == 7 && floats[base * 4 + 13] == 8 && floats[base * 4 + 14] == 9, "translation in column 3")

		// Vertex attributes 2 and 3 are plain floats holding exact integers.
		testing.expect_value(t, size_of(Batched_Vertex), 28)
		testing.expect_value(t, offset_of(Batched_Vertex, face_idx), uintptr(20))
		testing.expect_value(t, offset_of(Batched_Vertex, object_index), uintptr(24))
		testing.expect_value(t, u32(f32(MAP_BATCH_MAX_OBJECTS - 1)), u32(MAP_BATCH_MAX_OBJECTS - 1))
	}

	@(private = "file")
	self_test_context :: proc(t: ^testing.T, title: cstring) -> glfw.WindowHandle {
		if !testing.expect(t, bool(glfw.Init())) do return nil
		glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)
		glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 5)
		window := glfw.CreateWindow(64, 64, title, nil, nil)
		if !testing.expect(t, window != nil) {
			glfw.Terminate()
			return nil
		}
		glfw.MakeContextCurrent(window)
		gl.load_up_to(4, 5, glfw.gl_set_proc_address)
		gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
		return window
	}

	// Driver side of the contract: the linked program reports the same layout.
	@(test)
	map_batch_program_layout_matches_driver :: proc(t: ^testing.T) {
		logger := context.logger
		context = runtime.default_context()
		context.logger = logger
		window := self_test_context(t, "Batch layout")
		if window == nil do return
		defer glfw.Terminate()
		defer glfw.DestroyWindow(window)
		defer resource_cache_fini()
		testing.expect_value(t, map_batch_limits_reason(), "")
		basic_batched_shader_program = 0
		program := basic_batched_program()
		if !testing.expect(t, program != 0, "the batched shader must compile") do return
		testing.expect_value(t, g_map_batch_shader_layout_reason, "")
		testing.expect_value(t, map_batch_program_layout_reason(u32(program)), "")
	}

	@(private = "file")
	self_test_load :: proc(t: ^testing.T, client: ^Client, map_name: string) -> bool {
		client^ = Client{scene = scene_init(), render_batching = true}
		g_client = client
		map_inst, ok := shared.map_load_from_file(fmt.tprintf("assets/maps/%s.json", map_name))
		if !testing.expect(t, ok && map_inst != nil, map_name) {
			scene_fini(client.scene)
			g_client = nil
			return false
		}
		client.game.map_inst = map_inst
		client_load_current_map(client)
		return true
	}

	@(private = "file")
	self_test_unload :: proc(client: ^Client) {
		client_unload_map(client)
		shared.map_destroy(client.game.map_inst)
		scene_fini(client.scene)
		resource_cache_fini()
		g_client = nil
		free_all(context.temp_allocator)
	}

	// The map-load self-test keeps batching on for a correct driver and turns
	// it off, for the session, when batched rendering is broken (injected
	// fault: every storage-buffer transform reads as zero).
	@(test)
	map_batch_self_test_disables_batching_on_mismatch :: proc(t: ^testing.T) {
		logger := context.logger
		context = runtime.default_context()
		context.logger = logger
		window := self_test_context(t, "Batch self-test")
		if window == nil do return
		defer glfw.Terminate()
		defer glfw.DestroyWindow(window)
		old_lighting := g_lighting_config
		defer g_lighting_config = old_lighting

		client: Client
		if self_test_load(t, &client, "burg") {
			testing.expect(t, client.batch_self_test_done, "the self-test runs on the first map")
			testing.expect(t, client.render_batching && client.scene.batches != nil, "a correct driver keeps batching")
			// Later maps reuse the verdict: no second self-test.
			client.batch_self_test_done = true
			client_unload_map(&client)
			client_load_current_map(&client)
			testing.expect(t, client.scene.batches != nil, "reloading keeps batching on")
			self_test_unload(&client)
		}

		// Live shadow/night/lighting state (left from the previous frame) must
		// not make a correct driver fail, and comes back unchanged afterwards.
		{
			old_quality, old_low, old_unlit := g_render_quality, g_night_low_tint, g_night_unlit_tint
			defer { g_render_quality, g_night_low_tint, g_night_unlit_tint = old_quality, old_low, old_unlit }
			live := Render_Quality{shadows = true, soft_shadows = true, player_shadows = true, lighting = .HIGH, mode = .SHARP}
			g_render_quality = live
			g_night_low_tint, g_night_unlit_tint = {0.2, 0.25, 0.4}, {0.5, 0.5, 0.6}
			if self_test_load(t, &client, "sandstorm_v3") {
				testing.expect(t, client.batch_self_test_done && client.render_batching && client.scene.batches != nil, "shadow/night state must not fail the self-test")
				testing.expect(t, g_render_quality == live, "the self-test restores the render quality")
				testing.expect(t, g_night_low_tint == {0.2, 0.25, 0.4} && g_night_unlit_tint == {0.5, 0.5, 0.6}, "the self-test restores the night tints")
				self_test_unload(&client)
			}
		}

		g_map_batch_fault_inject = true
		defer g_map_batch_fault_inject = false
		if self_test_load(t, &client, "burg") {
			testing.expect(t, client.batch_self_test_done, "the self-test runs on the first map")
			testing.expect(t, !client.render_batching, "a mismatch must turn batching off for the session")
			testing.expect(t, client.scene.batches == nil, "a mismatch must free the batches")
			// Per-object drawing is untouched: no mesh stays marked as batched.
			for mesh in client.scene.meshes {
				if mesh.batched {
					testing.expect(t, false, "no mesh may stay marked batched")
					break
				}
			}
			// The next map load stays on the per-object path.
			client_unload_map(&client)
			client_load_current_map(&client)
			testing.expect(t, client.scene.batches == nil, "batching stays off after the next map load")
			testing.expect(t, gl.GetError() == gl.NO_ERROR, "the self-test must not leave OpenGL errors")
			self_test_unload(&client)
		}

		// The comparison itself: within tolerance, then beyond it.
		pixel_count := MAP_BATCH_SELF_TEST_WIDTH * MAP_BATCH_SELF_TEST_HEIGHT
		testing.expect(t, map_batch_self_test_within_tolerance({tie_pixels = 5}, pixel_count))
		testing.expect(t, !map_batch_self_test_within_tolerance({tie_pixels = pixel_count / 1000 + 1}, pixel_count))
		testing.expect(t, !map_batch_self_test_within_tolerance({geometry_pixels = pixel_count / 2000 + 1}, pixel_count))
		off := [6]u8{10, 10, 10, 50, 50, 50}
		on := [6]u8{11, 10, 10, 90, 50, 50}
		depth := [2]u32{7, 7}
		depth_moved := [2]u32{7, 8}
		testing.expect(t, map_batch_compare(off[:], on[:], depth[:], depth[:]) == Map_Batch_Compare{max_diff = 40, tie_pixels = 1, first_geometry = -1})
		testing.expect(t, map_batch_compare(off[:], on[:], depth[:], depth_moved[:]) == Map_Batch_Compare{max_diff = 40, max_geometry_diff = 40, geometry_pixels = 1, first_geometry = 1})
	}
}
