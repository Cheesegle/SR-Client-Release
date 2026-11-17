package main

import "base:runtime"
import "core:math"
import "core:testing"
import gl "vendor:OpenGL"
import glfw "vendor:glfw"
import shared "../shared"

when ODIN_TEST {
	@(test)
	bullet_holes_render :: proc(t: ^testing.T) {
		context = runtime.default_context()
		if !testing.expect(t, bool(glfw.Init()), "GLFW initialization failed") do return
		defer glfw.Terminate()
		test_gpu := test_gpu_open(320, 240, "Wall decal regression")
		if !testing.expect(t, test_gpu.ok, "no GPU device for the test") do return
		defer test_gpu_close(&test_gpu, t)
		g_test_gpu = &test_gpu
		window := test_gpu.window
		client := Client{window = window, scene = scene_init(), camera = camera_init(math.PI / 2)}
		g_client = &client
		defer { g_client = nil }
		wall := shared.Object{active = true, prefab = .CUBE, scale = {4, 4, 1}, position = {0, -2, -5}}
		material := basic_material_init()
		if !testing.expect(t, material != nil, "wall material failed") do return
		material.unlit = true
		wall_mesh := mesh_init(create_cube_geo(), &material.base)
		wall_mesh.transform.position = wall.position
		wall_mesh.transform.scale = wall.scale
		wall.mesh = wall_mesh
		scene_add_mesh(client.scene, wall_mesh)
		map_inst := shared.Map{}
		append(&map_inst.objects, &wall)
		client.game.map_inst = &map_inst
		client.game.weapons = shared.WEAPONS_LIST[:]
		defer {
			client_clear_bullet_holes(&client)
			scene_remove_mesh(client.scene, wall_mesh)
			mesh_fini(wall_mesh)
			scene_fini(client.scene)
			delete(map_inst.objects)
			resource_cache_fini()
		}
		impact := shared.Bullet_Impact{kind = .World, hit = true, weapon_id = 1, object_index = 0, position = {0, 0, -4.5}, normal = {0, 0, 1}}
		client_add_bullet_hole(&client, &impact)
		if !testing.expect(t, len(client.impact_markers) == 1, "wall shot must create one surface decal") do return
		hole := client.impact_markers[0].mesh
		testing.expect(t, hole.geometry.index_count >= 6 && (cast(^Basic_Material)hole.material).texture != 0, "hole must have real textured geometry")
		testing.expect(t, hole.transform.position.z > -4.5 && hole.transform.position.z < -4.48, "decal must offset along the wall normal")
		gpu_set_target(test_gpu_current_target(), 320, 240)
		gpu_set_clear_color({0.1, 0.1, 0.1})
		gpu_clear(color = true, depth = true)
		scene_render(client.scene, &client.camera, 320, 240)
		center: [4]u8
		test_read_rgba(160, 120, 1, 1, &center[0])
		testing.expect(t, center[0] < 100 && center[1] < 100 && center[2] < 100, "wall center must show a dark bullet hole")
		mesh_update_transform_matrix(hole)
		fixed_transform := hole.transform_matrix
		client.camera.position = {1, 1, 0}
		client_tick_bullet_holes(&client, 0.01)
		scene_render(client.scene, &client.camera, 320, 240)
		testing.expect(t, hole.transform_matrix == fixed_transform, "hole must stay attached to the surface when the camera moves")
		testing.expect(t, test_gpu_no_error(), "surface decal rendering produced a GL error")
		client_tick_bullet_holes(&client, 3.6)
		alpha := (cast(^Basic_Material)hole.material).color.w
		testing.expect(t, alpha > 0 && alpha < 1, "decal must fade before its four-second lifetime ends")
		client_tick_bullet_holes(&client, 0.5)
		testing.expect(t, len(client.impact_markers) == 0 && client.scene.mesh_count == 1, "expired decals must release their scene meshes")

		// Every wall/floor/ceiling normal must remain planar. Clip near the edge
		// while retaining interpolated UVs instead of shrinking the decal.
		normals := [?]shared.Vec3{{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}
		for normal in normals {
			position := shared.Vec3{1.99, 1.99, -4.51}
			for axis in 0..<3 {
				if normal[axis] != 0 {
					center_position := wall.position + shared.Vec3{0, wall.scale.y / 2, 0}
					position[axis] = center_position[axis] + normal[axis] * wall.scale[axis] / 2
				}
			}
			vertices: [16]Vertex
			count := bullet_hole_vertices(position, normal, 1, 0.37, &wall, vertices[:])
			testing.expect(t, count >= 3, "surface-edge clip must retain the on-wall portion")
			for vertex in vertices[:count] {
				world := vertex.position + position
				distance := vertex.position.x * normal.x + vertex.position.y * normal.y + vertex.position.z * normal.z
				testing.expect(t, abs(distance) < 0.0001 && world.x >= -2.002 && world.x <= 2.002 && world.y >= -2.002 && world.y <= 2.002 && world.z >= -5.502 && world.z <= -4.498, "clipped vertices must lie on their hit surface and inside the wall bounds")
				testing.expect(t, vertex.tex_coord.x >= -0.001 && vertex.tex_coord.x <= 1.001 && vertex.tex_coord.y >= -0.001 && vertex.tex_coord.y <= 1.001, "clipped UVs must stay within the source image")
			}
		}
		non_world_kinds := [?]shared.Bullet_Hit_Kind{.Miss, .Player}
		for kind in non_world_kinds {
			impact.kind = kind
			client_add_bullet_hole(&client, &impact)
		}
		impact.kind = .World
		impact.weapon_id = 12
		client_add_bullet_hole(&client, &impact)
		impact.weapon_id = 18
		client_add_bullet_hole(&client, &impact)
		impact.weapon_id = 1
		wall_mesh.visible = false
		client_add_bullet_hole(&client, &impact)
		wall_mesh.visible = true
		wall.is_border = true
		client_add_bullet_hole(&client, &impact)
		wall.is_border = false
		material.face_mask &= ~u32(1)
		client_add_bullet_hole(&client, &impact)
		material.face_mask = 0x3f
		material.alpha_test = 0.01
		client_add_bullet_hole(&client, &impact)
		material.alpha_test = 0
		wall_mesh.transform.rotation.y = math.PI / 4
		client_add_bullet_hole(&client, &impact)
		wall_mesh.transform.rotation.y = 0
		wall.prefab = .RAMP
		client_add_bullet_hole(&client, &impact)
		wall.prefab = .CUBE
		testing.expect(t, len(client.impact_markers) == 0, "melee, energy projectiles, misses, players, invisible colliders, and map borders must never get bullet holes")
		registry := client.game.weapons
		disabled_projectile := registry[1]^
		disabled_projectile.projectile = true
		disabled_projectile.projectile_disable = true
		client.game.weapons = []^shared.Weapon{&disabled_projectile}
		impact.weapon_id = 0
		client_add_bullet_hole(&client, &impact)
		testing.expect(t, len(client.impact_markers) == 1, "disabled projectile configuration must retain hitscan wall holes")
		client_clear_bullet_holes(&client)
		client.game.config.bullet_drop = true
		client_add_bullet_hole(&client, &impact)
		testing.expect(t, len(client.impact_markers) == 0, "bullet drop must suppress hitscan decals for physical projectiles")
		client.game.config.bullet_drop = false
		disabled_projectile.projectile_disable = false
		client_add_bullet_hole(&client, &impact)
		testing.expect(t, len(client.impact_markers) == 0, "active physical projectiles must suppress hitscan wall decals")
		client.game.weapons = registry
		impact.weapon_id = 1
		for _ in 0..<MAX_BULLET_HOLES + 3 { client_add_bullet_hole(&client, &impact) }
		testing.expect(t, len(client.impact_markers) == MAX_BULLET_HOLES && client.scene.mesh_count == MAX_BULLET_HOLES + 1, "sustained shooting must keep the decal pool bounded")
		wall.active = false
		client_tick_bullet_holes(&client, 0)
		testing.expect(t, len(client.impact_markers) == 0 && client.scene.mesh_count == 1, "removed world geometry must release its bullet holes")
		client_clear_bullet_holes(&client)
		testing.expect(t, client.impact_markers == nil, "cleanup must leave the marker array reusable")
	}
}
