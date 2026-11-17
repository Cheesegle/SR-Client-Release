package main

import gl "vendor:OpenGL"

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

scene_uniforms :: proc(program: u32) -> ^Shader_Uniforms {
	if program == basic_shader_program {
		return &u_basic
	} else if program != 0 && program == basic_batched_shader_program {
		return &u_basic_batched
	} else if program == quad_shader_program {
		return &u_quad
	}
	return &u_text
}

// Local to a render pass: HUD draws, resource uploads, and other GL contexts
// cannot leave this cache stale. Blend and polygon state start disabled/filled.
Scene_Draw_State :: struct {
	program, vao: u32,
	blending, wireframe, no_depth_write: bool,
}

scene_update_pass_uniforms :: proc(program: u32, camera: ^Camera) {
	u := scene_uniforms(program)
	if u.camera_world_inverse > -1 {
		gl.UniformMatrix4fv(u.camera_world_inverse, 1, gl.FALSE, &camera.world_inverse_matrix[0, 0])
	}
	if u.camera_projection > -1 {
		gl.UniformMatrix4fv(u.camera_projection, 1, gl.FALSE, &camera.projection_matrix[0, 0])
	}
	if program == basic_shader_program {
		basic_material_update_pass_uniforms(camera, &u_basic)
	} else if program != 0 && program == basic_batched_shader_program {
		basic_material_update_pass_uniforms(camera, &u_basic_batched)
	}
}

scene_draw_mesh :: proc(mesh: ^Mesh, camera: ^Camera, state: ^Scene_Draw_State) {
	if !mesh.visible {
		return
	}

	if state.no_depth_write != mesh.material.no_depth_write {
		gl.DepthMask(gl.FALSE if mesh.material.no_depth_write else gl.TRUE)
		state.no_depth_write = mesh.material.no_depth_write
	}

	if state.blending != mesh.material.transparent {
		if mesh.material.transparent {
			gl.Enable(gl.BLEND)
		} else {
			gl.Disable(gl.BLEND)
		}
		state.blending = mesh.material.transparent
	}

	if state.vao != mesh.geometry.vao {
		// The index buffer is already part of the VAO, set during upload.
		gl.BindVertexArray(mesh.geometry.vao)
		state.vao = mesh.geometry.vao
	}

	if state.program != mesh.material.program {
		if g_active_shader != mesh.material.program {
			gl.UseProgram(mesh.material.program)
			g_active_shader = mesh.material.program
		}
		// A new pass can use the same program with a different camera (weapons)
		// or map environment. Refresh these even if the program is still bound.
		scene_update_pass_uniforms(mesh.material.program, camera)
		state.program = mesh.material.program
	}

	material_update_uniforms(mesh.material)

	u := scene_uniforms(mesh.material.program)
	if u.transform > -1 {
		gl.UniformMatrix4fv(u.transform, 1, gl.FALSE, &mesh.transform_matrix[0, 0])
	}
	if state.wireframe != mesh.material.wireframe {
		gl.PolygonMode(gl.FRONT_AND_BACK, gl.LINE if mesh.material.wireframe else gl.FILL)
		state.wireframe = mesh.material.wireframe
	}

	gl.DrawElements(gl.TRIANGLES, mesh.geometry.index_count, gl.UNSIGNED_INT, nil)
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
			if g_active_shader != set.program {
				gl.UseProgram(set.program)
				g_active_shader = set.program
			}
			scene_update_pass_uniforms(set.program, camera)
			state.program = set.program
		}
		if state.vao != set.vao {
			gl.BindVertexArray(set.vao)
			state.vao = set.vao
		}
		// Binding 0 is only used by the batched program; rebind per pass.
		gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, 0, set.ssbo)
		if state.no_depth_write {
			gl.DepthMask(gl.TRUE)
			state.no_depth_write = false
		}
		if state.blending {
			gl.Disable(gl.BLEND)
			state.blending = false
		}
		if state.wireframe != batch.key.wireframe {
			gl.PolygonMode(gl.FRONT_AND_BACK, gl.LINE if batch.key.wireframe else gl.FILL)
			state.wireframe = batch.key.wireframe
		}
		basic_bind_texture(batch.key.texture)
		gl.DrawElements(gl.TRIANGLES, batch.index_count, gl.UNSIGNED_INT, rawptr(uintptr(batch.first_index) * size_of(u32)))
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

scene_render :: proc(scene: ^Scene, camera: ^Camera, viewport_w, viewport_h: f32, sampler: u32 = 0) {
	aspect := viewport_h > 0 ? viewport_w / viewport_h : (16.0 / 9.0)

	gl.Enable(gl.DEPTH_TEST)
	gl.DepthMask(gl.TRUE)
	gl.BindBuffer(gl.ARRAY_BUFFER, 0)
	gl.Disable(gl.BLEND)
	gl.PolygonMode(gl.FRONT_AND_BACK, gl.FILL)
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindSampler(0, sampler)
	defer gl.BindSampler(0, 0)
	state: Scene_Draw_State

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
	gl.DepthMask(gl.TRUE)
	gl.PolygonMode(gl.FRONT_AND_BACK, gl.FILL)
}

scene_fini :: proc(scene: ^Scene) {
	map_batch_destroy(scene, members_alive = false)
	delete(scene.meshes)
	delete(scene.transparent_meshes)
	delete(scene.transparent_sort_scratch)
	free(scene)
}
