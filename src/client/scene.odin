package main

import "core:mem"

scene_init :: proc() -> ^Scene {
	return new(Scene)
}

scene_add_mesh :: proc(scene: ^Scene, mesh: ^Mesh) {
	append(&scene.meshes, mesh)
	scene.mesh_count = i32(len(scene.meshes))
}

scene_remove_mesh :: proc(scene: ^Scene, mesh: ^Mesh) {
	// Effects (tracers, trails, bullet holes) are added after every map mesh,
	// so search from the end.
	for i := len(scene.meshes) - 1; i >= 0; i -= 1 {
		if scene.meshes[i] == mesh {
			ordered_remove(&scene.meshes, i)
			scene.mesh_count = i32(len(scene.meshes))
			return
		}
	}
}

// Players receive shadows and cast only with Dynamic Shadows (Krunker sets
// castShadow = dynamicShadows on every body part). The local viewmodel lives
// in the fps scene, which is never drawn into the shadow map.
scene_add_player_part :: proc(scene: ^Scene, mesh: ^Mesh) {
	if mesh == nil { return }
	mesh.shadow_caster = .DYNAMIC
	if mesh.material != nil && mesh.material.vtable == &basic_material_vtable {
		(cast(^Basic_Material)mesh.material).receive_shadow = true
	}
	scene_add_mesh(scene, mesh)
}

scene_add_player_mesh :: proc(scene: ^Scene, player_mesh: ^Player_Mesh, loadout_size: int) {
	if player_mesh.body != nil {
		for mesh in player_mesh.body.meshes {
			scene_add_player_part(scene, mesh)
		}
	}

	if player_mesh.head != nil {
		for mesh in player_mesh.head.meshes {
			scene_add_player_part(scene, mesh)
		}
	}

	for i in 0 ..< loadout_size {
		if i >= len(player_mesh.arms) {
			break
		}

		arms := player_mesh.arms[i]
		if arms == nil {
			continue
		}

		if arms.weapon_right != nil {
			scene_add_player_part(scene, arms.weapon_right)
		}
		if arms.weapon_left != nil {
			scene_add_player_part(scene, arms.weapon_left)
		}
		if arms.attachment != nil {
			scene_add_player_part(scene, arms.attachment)
		}

		for j in 0 ..< 2 {
			arm := arms.left if j == 1 else arms.right

			if arm == nil {
				continue
			}

			if arm.extender != nil {
				scene_add_player_part(scene, arm.extender)
			}

			if arm.upper != nil {
				scene_add_player_part(scene, arm.upper)
			}
			if arm.joint != nil {
				scene_add_player_part(scene, arm.joint)
			}

			for k in arm.lower.meshes {
				scene_add_player_part(scene, k)
			}
		}
	}

	for leg in player_mesh.legs {
		if leg == nil {
			continue
		}

		for mesh in leg.meshes {
			scene_add_player_part(scene, mesh)
		}
	}

	for leg in player_mesh.crouched_legs {
		if leg == nil {
			continue
		}

		scene_add_player_part(scene, leg.upper)
		scene_add_player_part(scene, leg.joint)

		for mesh in leg.lower.meshes {
			scene_add_player_part(scene, mesh)
		}
	}
}

scene_remove_player_mesh :: proc(scene: ^Scene, player_mesh: ^Player_Mesh, loadout_size: int) {
	if player_mesh == nil {
		return
	}

	if player_mesh.body != nil {
		for mesh in player_mesh.body.meshes {
			scene_remove_mesh(scene, mesh)
		}
	}

	if player_mesh.head != nil {
		for mesh in player_mesh.head.meshes {
			scene_remove_mesh(scene, mesh)
		}
	}

	for i in 0 ..< loadout_size {
		if i >= len(player_mesh.arms) {
			break
		}

		arms := player_mesh.arms[i]
		if arms == nil {
			continue
		}

		if arms.weapon_right != nil {
			scene_remove_mesh(scene, arms.weapon_right)
		}
		if arms.weapon_left != nil {
			scene_remove_mesh(scene, arms.weapon_left)
		}
		if arms.attachment != nil {
			scene_remove_mesh(scene, arms.attachment)
		}

		for j in 0 ..< 2 {
			arm := arms.left if j == 1 else arms.right

			if arm == nil {
				continue
			}

			if arm.extender != nil {
				scene_remove_mesh(scene, arm.extender)
			}

			if arm.upper != nil {
				scene_remove_mesh(scene, arm.upper)
			}
			if arm.joint != nil {
				scene_remove_mesh(scene, arm.joint)
			}

			for k in arm.lower.meshes {
				scene_remove_mesh(scene, k)
			}
		}
	}

	for leg in player_mesh.legs {
		if leg == nil {
			continue
		}

		for mesh in leg.meshes {
			scene_remove_mesh(scene, mesh)
		}
	}

	for leg in player_mesh.crouched_legs {
		if leg == nil {
			continue
		}

		scene_remove_mesh(scene, leg.upper)
		scene_remove_mesh(scene, leg.joint)

		for mesh in leg.lower.meshes {
			scene_remove_mesh(scene, mesh)
		}
	}
}

// Uniform locations of the UI programs.
// Local to a render pass: HUD draws, resource uploads, and other GL contexts
// cannot leave this cache stale. The draw state starts at the default.
Scene_Draw_State :: struct {
	program:     Gpu_Program,
	input:       Gpu_Vertex_Input,
	pass_pushed: bool, // The `Pass` block for this camera is bound.
	draw:        Gpu_Draw_State,
}

@(private = "file")
scene_set_draw_state :: proc(state: ^Scene_Draw_State, draw: Gpu_Draw_State) {
	if state.draw == draw { return }
	gpu_draw_state_set(draw)
	state.draw = draw
}

// Binds the pass's `Pass` block once per scene_render: every basic program
// variant reads the same one. A new pass can use the same program with a
// different camera (weapons) or map environment, so it is never reused
// across passes.
scene_update_pass_uniforms :: proc(state: ^Scene_Draw_State, camera: ^Camera) {
	if state.pass_pushed { return }
	pass := basic_pass_uniforms(camera)
	gpu_uniform_push(GPU_BINDING_PASS, mem.ptr_to_bytes(&pass))
	state.pass_pushed = true
}

scene_draw_mesh :: proc(mesh: ^Mesh, camera: ^Camera, state: ^Scene_Draw_State) {
	if !mesh.visible {
		return
	}

	scene_set_draw_state(state, {blend = mesh.material.transparent, depth_write = !mesh.material.no_depth_write, wireframe = mesh.material.wireframe})

	if state.input != mesh.geometry.input {
		gpu_vertex_input_bind(mesh.geometry.input)
		state.input = mesh.geometry.input
	}

	if state.program != mesh.material.program {
		gpu_program_bind(mesh.material.program)
		scene_update_pass_uniforms(state, camera)
		state.program = mesh.material.program
	}

	if mesh.material.vtable == &basic_material_vtable {
		basic_material_push_draw(cast(^Basic_Material)mesh.material, mesh.transform_matrix)
	} else {
		material_update_uniforms(mesh.material)
	}
	gpu_draw_indexed(mesh.geometry.index_count, 0)
	g_draw_calls += 1
	g_draw_stats.draw_calls += 1
}

// Draws the static map batches (map_batch.odin) in their tie-safe order. A
// batch whose members were all hidden (hide cats/props) is skipped; if only
// some are hidden, or a member moved after the build, its visible members are
// drawn individually instead. Single slots are always drawn individually.
scene_draw_batches :: proc(scene: ^Scene, camera: ^Camera, state: ^Scene_Draw_State, frustum: ^Frustum) {
	set := scene.batches
	for &batch in set.batches {
		if g_render_culling && !frustum_aabb_visible(frustum, batch.bounds_min, batch.bounds_max) {
			g_draw_stats.batches_culled += 1
			continue
		}
		members := set.members[batch.member_start:][:batch.member_count]
		all_visible, any_visible, moved := true, false, false
		for mesh in members {
			if mesh.visible { any_visible = true } else { all_visible = false }
			if mesh.transform != mesh.last_transform { moved = true }
		}
		if !any_visible {
			continue
		}
		if batch.single || !all_visible || moved {
			for mesh in members {
				if !mesh.visible { continue }
				mesh_update_transform_matrix(mesh)
				scene_draw_mesh(mesh, camera, state)
			}
			continue
		}

		if state.program != set.program {
			gpu_program_bind(set.program)
			scene_update_pass_uniforms(state, camera)
			state.program = set.program
		}
		if state.input != set.input {
			gpu_vertex_input_bind(set.input)
			state.input = set.input
		}
		// Binding 0 is only used by the batched program; rebind per pass.
		gpu_buffer_bind_storage(0, set.objects)
		scene_set_draw_state(state, {depth_write = true, wireframe = batch.key.wireframe})
		basic_bind_texture(batch.key.texture)
		gpu_draw_indexed(batch.index_count, batch.first_index)
		g_draw_calls += 1
		g_draw_stats.draw_calls += 1
		g_draw_stats.batch_draws += 1
	}
}

// Stable merge sort keeps equal-depth effects in scene order and bounds the
// cost when camera turns reverse the order of many transparent surfaces.
// Scratch storage is reused across frames; there are no per-frame allocations
// once the scene's largest transparent set has been seen.
scene_sort_transparent :: proc(scene: ^Scene) {
	count := len(scene.transparent_meshes)
	if count < 2 { return }
	resize(&scene.transparent_sort_scratch, count)
	source := scene.transparent_meshes[:]
	destination := scene.transparent_sort_scratch[:]
	for width := 1; width < count; width *= 2 {
		for start := 0; start < count; start += width * 2 {
			middle := min(start + width, count)
			end := min(start + width * 2, count)
			left, right := start, middle
			for output in start..<end {
				if left < middle && (right >= end || source[left].camera_space_matrix[2, 3] <= source[right].camera_space_matrix[2, 3]) {
					destination[output] = source[left]
					left += 1
				} else {
					destination[output] = source[right]
					right += 1
				}
			}
		}
		source, destination = destination, source
	}
	if raw_data(source) != raw_data(scene.transparent_meshes) {
		copy(scene.transparent_meshes[:], source)
	}
}

scene_render :: proc(scene: ^Scene, camera: ^Camera, viewport_w, viewport_h: f32, sampler: Gpu_Sampler = 0) {
	aspect := viewport_h > 0 ? viewport_w / viewport_h : (16.0 / 9.0)

	gpu_draw_state_reset()
	gpu_sampler_bind(GPU_UNIT_COLOR, sampler)
	defer gpu_sampler_bind(GPU_UNIT_COLOR, 0)
	state := Scene_Draw_State{draw = GPU_DRAW_STATE_DEFAULT}

	camera_update_projection_matrix(camera, aspect)
	camera_update_world_inverse_matrix(camera)

	mesh_count := len(scene.meshes)
	if mesh_count == 0 {
		return
	}

	// Batched path: static map batches first, then everything else with a
	// bounding-sphere frustum test. Disabled, this is the original path.
	batched := scene.batches != nil && scene.batching_enabled
	frustum: Frustum
	if batched {
		frustum = frustum_from_camera(camera)
		scene_draw_batches(scene, camera, &state, &frustum)
	}

	// 1. Draw opaque meshes directly with hardware depth testing.
	// 2. Collect visible transparent meshes for back-to-front sorting.
	clear(&scene.transparent_meshes)
	for i in 0 ..< mesh_count {
		mesh := scene.meshes[i]
		if !mesh.visible || batched && mesh.batched {
			continue
		}
		mesh_update_transform_matrix(mesh)
		if batched && g_render_culling {
			if center, radius, ok := mesh_bounding_sphere(mesh); ok && !frustum_sphere_visible(&frustum, center, radius) {
				g_draw_stats.meshes_culled += 1
				continue
			}
		}

		if mesh.material.transparent {
			mesh.camera_space_matrix = camera.world_inverse_matrix * mesh.transform_matrix
			append(&scene.transparent_meshes, mesh)
		} else {
			scene_draw_mesh(mesh, camera, &state)
		}
	}

	// Draw sorted transparent meshes
	trans_count := len(scene.transparent_meshes)
	if trans_count > 0 {
		// Visible points have negative camera Z: most negative draws first.
		scene_sort_transparent(scene)

		for i in 0 ..< trans_count {
			scene_draw_mesh(scene.transparent_meshes[i], camera, &state)
		}
	}

	// Rendering state must not leak into the HUD pass.
	gpu_draw_state_reset()
}

scene_fini :: proc(scene: ^Scene) {
	map_batch_destroy(scene, members_alive = false)
	delete(scene.meshes)
	delete(scene.transparent_meshes)
	delete(scene.transparent_sort_scratch)
	free(scene)
}
