package main

import "core:math"
import "core:math/linalg"
import "core:testing"
import shared "../shared"

when ODIN_TEST {
	// basic.vert derives the face from gl_VertexID; batches store it per vertex.
	@(test)
	map_batch_face_index_matches_vertex_shader :: proc(t: ^testing.T) {
		cube := Basic_Material{}
		for vertex_id in 0 ..< 24 {
			testing.expect_value(t, batch_face_index(&cube, vertex_id), u32(vertex_id / 4))
		}
		// Ladders and OBJ models keep counting four vertices per face.
		testing.expect_value(t, batch_face_index(&cube, 51), u32(12))
		ramp := Basic_Material{is_ramp = true}
		expected := [18]u32{0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 3, 3, 3, 3}
		for vertex_id in 0 ..< 18 {
			testing.expect_value(t, batch_face_index(&ramp, vertex_id), expected[vertex_id])
		}
	}

	// The SSBO record must carry the exact values the uniform path uploads.
	@(test)
	map_batch_object_matches_material_uniforms :: proc(t: ^testing.T) {
		material := Basic_Material{
			is_ramp = true, use_face_tex_scaling = true, unlit = true,
			face_scale = {3, 4, 5}, face_mask = 0x2d, texture_scale = 2.5,
			color = {0.1, 0.2, 0.3, 1}, emissive = {1, 1, 1, 1}, alpha_test = 0.01,
			texture_repeat = {2, 3}, texture_offset = {0.25, 0.75}, texture_rotation = 1.3,
		}
		transform := linalg.matrix4_translate_f32({1, 2, 3}) * linalg.matrix4_rotate_f32(0.4, {0, 1, 0})
		object := batch_object_from_material(&material, transform)
		tex := basic_material_tex_transform(&material)
		testing.expect(t, object.transform == transform)
		testing.expect(t, object.color == material.color && object.emissive == material.emissive)
		testing.expect(t, object.face_scale == shared.Vec4{3, 4, 5, 2.5})
		testing.expect(t, object.tex_row0 == shared.Vec4{tex[0][0], tex[0][1], tex[0][2], 0})
		testing.expect(t, object.tex_row1 == shared.Vec4{tex[1][0], tex[1][1], tex[1][2], 0})
		testing.expect_value(t, object.params.x, f32(0x2d))
		testing.expect_value(t, object.params.y, f32(BATCH_FLAG_RAMP | BATCH_FLAG_FACE_TEX_SCALE | BATCH_FLAG_UNLIT))
		testing.expect_value(t, object.params.z, material.alpha_test)
		// Only the six cube-face bits reach the shader, as exact float values.
		material.face_mask = 0xffffffff
		testing.expect_value(t, batch_object_from_material(&material, transform).params.x, f32(0x3f))
		// Rotation: cos/sin of the same float, repeat and offset in place.
		c, s := math.cos(material.texture_rotation), math.sin(material.texture_rotation)
		testing.expect(t, tex[0] == [3]f32{2 * c, 2 * s, 0.25} && tex[1] == [3]f32{-3 * s, 3 * c, 0.75} && tex[2] == [3]f32{0, 0, 1})
	}

	@(test)
	map_batch_eligibility_excludes_dynamic_objects :: proc(t: ^testing.T) {
		geometry := Geometry{index_count = 36, has_bounds = true}
		material := Basic_Material{}
		material.base.vtable = &basic_material_vtable
		mesh := Mesh{geometry = &geometry, material = &material.base, visible = true, map_detail_visible = true}
		object := shared.Object{prefab = .CUBE}
		testing.expect(t, map_batch_eligible(&mesh, &object), "a static opaque cube is batched")

		material.base.transparent = true
		testing.expect(t, !map_batch_eligible(&mesh, &object), "transparent meshes need per-frame sorting")
		material.base.transparent = false
		material.base.no_depth_write = true
		testing.expect(t, !map_batch_eligible(&mesh, &object), "no-depth-write meshes stay per object")
		material.base.no_depth_write = false

		animation := shared.Texture_Animation{move = 1}
		object.tex_anim = &animation
		testing.expect(t, !map_batch_eligible(&mesh, &object), "animated textures change every frame")
		object.tex_anim = nil

		object.prefab = .OBJECTIVE
		testing.expect(t, !map_batch_eligible(&mesh, &object), "objectives toggle with match state")
		object.prefab = .SCORE_ZONE
		testing.expect(t, !map_batch_eligible(&mesh, &object), "score zones toggle with match state")
		object.prefab = .CUBE

		mesh.map_detail_visible = false
		testing.expect(t, !map_batch_eligible(&mesh, &object), "authored-hidden objects are never drawn")
		mesh.map_detail_visible = true

		parent := Mesh_Transform{scale = {1, 1, 1}}
		mesh.transform.parent = &parent
		testing.expect(t, !map_batch_eligible(&mesh, &object), "parented meshes can move")
		mesh.transform.parent = nil

		other := Material{} // any material without the basic vtable
		mesh.material = &other
		testing.expect(t, !map_batch_eligible(&mesh, &object), "only the basic material is batched")
	}

	@(test)
	map_batch_chunks_floor_negative_coordinates :: proc(t: ^testing.T) {
		x, z := map_batch_chunk({-0.5, 0, 127.9})
		testing.expect(t, x == -1 && z == 0)
		x, z = map_batch_chunk({-128, 0, 128})
		testing.expect(t, x == -1 && z == 1)
		x, z = map_batch_chunk({-128.1, 0, 256})
		testing.expect(t, x == -2 && z == 2)
	}

	@(test)
	map_batch_detects_coincident_faces :: proc(t: ^testing.T) {
		// Identical boxes (a face-masked overlay on a block).
		testing.expect(t, map_batch_boxes_tie({0, 0, 0}, {10, 5, 10}, {0, 0, 0}, {10, 5, 10}))
		// Crossing walls with the same top: their tops overlap at one height.
		testing.expect(t, map_batch_boxes_tie({0, 0, 4}, {10, 8, 6}, {4, 0, 0}, {6, 8, 10}))
		// Side by side, sharing only an edge: no overlapping area.
		testing.expect(t, !map_batch_boxes_tie({0, 0, 0}, {10, 5, 10}, {10, 0, 0}, {20, 5, 10}))
		// Stacked: top meets bottom, faces point opposite ways.
		testing.expect(t, !map_batch_boxes_tie({0, 0, 0}, {10, 5, 10}, {2, 5, 2}, {8, 9, 8}))
	}

	@(test)
	map_batch_frustum_culls_boxes :: proc(t: ^testing.T) {
		camera := camera_init(math.PI / 2)
		camera.position = {0, 0, 0}
		camera_update_projection_matrix(&camera, 16.0 / 9.0)
		camera_update_world_inverse_matrix(&camera)
		frustum := frustum_from_camera(&camera)
		// The camera looks down -Z.
		testing.expect(t, frustum_aabb_visible(&frustum, {-1, -1, -20}, {1, 1, -10}), "a box ahead is visible")
		testing.expect(t, !frustum_aabb_visible(&frustum, {-1, -1, 10}, {1, 1, 20}), "a box behind is culled")
		testing.expect(t, !frustum_aabb_visible(&frustum, {200, -1, -20}, {210, 1, -10}), "a box far to the side is culled")
		testing.expect(t, frustum_aabb_visible(&frustum, {-1000, -1, -20}, {1000, 1, -10}), "a box spanning the view is visible")
		testing.expect(t, !frustum_aabb_visible(&frustum, {-1, -1, -20000}, {1, 1, -15000}), "a box past the far plane is culled")
		testing.expect(t, frustum_sphere_visible(&frustum, {0, 0, 5}, 6), "a sphere around the camera is visible")
		testing.expect(t, !frustum_sphere_visible(&frustum, {0, 0, 50}, 6), "a sphere behind is culled")
	}
}
