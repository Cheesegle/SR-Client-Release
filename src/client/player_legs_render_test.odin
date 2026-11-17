package main

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:testing"
import gl "vendor:OpenGL"
import glfw "vendor:glfw"
import stbi "vendor:stb/image"
import shared "../shared"

when ODIN_TEST {
	LEGS_SHOT_W :: 480
	LEGS_SHOT_H :: 480

	legs_world_point :: proc(transform: ^Mesh_Transform, local: shared.Vec3) -> shared.Vec3 {
		probe := Mesh{transform = {parent = transform, scale = {1, 1, 1}}}
		probe.transform.position = local
		mesh_update_transform_matrix(&probe)
		p := probe.transform_matrix * shared.Vec4{0, 0, 0, 1}
		return p.xyz
	}

	legs_mesh_point :: proc(mesh: ^Mesh, local: shared.Vec3) -> shared.Vec3 {
		mesh_update_transform_matrix(mesh)
		p := mesh.transform_matrix * shared.Vec4{local.x, local.y, local.z, 1}
		return p.xyz
	}

	legs_near :: proc(a, b: shared.Vec3, tolerance: f32 = 0.01) -> bool {
		d := a - b
		return math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z) <= tolerance
	}

	legs_standing_visible :: proc(rig: ^Player_Mesh) -> bool {
		for leg in rig.legs { for mesh in leg.meshes { if !mesh.visible { return false } } }
		return true
	}

	legs_crouched_visible :: proc(rig: ^Player_Mesh) -> bool {
		for leg in rig.crouched_legs {
			if !leg.upper.visible || !leg.joint.visible { return false }
			for mesh in leg.lower.meshes { if !mesh.visible { return false } }
		}
		return true
	}

	// Checks the rig against Krunker's: standing legs hang from the hip at
	// legHeight and swing about it; bent legs hang from legHeight + 0.5 -
	// crouchDst * crouch (0.5 inside the body's base) and stay joined at the knee.
	legs_check_rig :: proc(t: ^testing.T, player: ^shared.Player, rig_crouch: f32, label: string) {
		rig := cast(^Player_Mesh)player.mesh
		g := shared.GAME_CONSTANTS
		body_y := g.leg_height - g.crouch_distance * rig_crouch
		testing.expectf(t, abs(rig.body_anchor.position.y - body_y) < 0.001, "%s: body base must sit at legHeight - crouchDst * crouch (%.3f, got %.3f)", label, body_y, rig.body_anchor.position.y)
		crouched := rig_crouch != 0
		testing.expectf(t, legs_standing_visible(rig) == !crouched, "%s: standing legs visible=%v", label, !crouched)
		testing.expectf(t, legs_crouched_visible(rig) == crouched, "%s: bent legs visible=%v", label, crouched)
		for leg, i in rig.legs {
			side: f32 = i == 0 ? -1 : 1
			hip := legs_mesh_point(leg.meshes[0], {0, 1, 0})
			want := legs_world_point(rig.anchor, {side * g.leg_scale * 0.5, g.leg_height, 0})
			testing.expectf(t, legs_near(hip, want), "%s: standing leg %d must hang from the hip %v, got %v", label, i, want, hip)
		}
		for leg, i in rig.crouched_legs {
			side: f32 = i == 0 ? -1 : 1
			hip := legs_mesh_point(leg.upper, {0, 1, 0})
			want := legs_world_point(rig.anchor, {side * g.leg_scale * 0.5, body_y + 0.5, 0})
			testing.expectf(t, legs_near(hip, want), "%s: bent leg %d must start 0.5 inside the body base %v, got %v", label, i, want, hip)
			knee := legs_mesh_point(leg.upper, {0, 0, 0})
			testing.expectf(t, legs_near(knee, legs_mesh_point(leg.lower.meshes[0], {0, 1, 0})), "%s: bent leg %d shin must meet the thigh", label, i)
			testing.expectf(t, legs_near(knee, legs_mesh_point(leg.joint, {0, 0.5, 0})), "%s: bent leg %d knee block must sit on the knee", label, i)
		}
	}

	// -define:LEGS_PREVIEW=true [-define:LEGS_TAG=before] writes each side view
	// to bin/legs/<tag>_<state>.png for checking by eye.
	legs_shot :: proc(t: ^testing.T, scene: ^Scene, camera: ^Camera, name: string) {
		gpu_set_clear_color({0.75, 0.8, 0.85})
		gpu_clear(color = true, depth = true)
		scene_render(scene, camera, LEGS_SHOT_W, LEGS_SHOT_H)
		testing.expect(t, test_gpu_no_error(), "player rig must render without OpenGL errors")
		when #config(LEGS_PREVIEW, false) {
			pixels := make([]u8, LEGS_SHOT_W * LEGS_SHOT_H * 3)
			defer delete(pixels)
			test_read_rgb(0, 0, LEGS_SHOT_W, LEGS_SHOT_H, raw_data(pixels))
			os.make_directory("bin/legs")
			path := fmt.ctprintf("bin/legs/%s_%s.png", #config(LEGS_TAG, "after"), name)
			stbi.write_png(path, LEGS_SHOT_W, LEGS_SHOT_H, 3, &pixels[(LEGS_SHOT_H - 1) * LEGS_SHOT_W * 3], -LEGS_SHOT_W * 3)
		}
	}

	Legs_State :: struct {
		name:       string,
		crouch:     f32,
		step:       f32,
		rig_crouch: f32, // What Krunker would show for this remote crouch value.
	}

	@(test)
	player_legs_stay_attached :: proc(t: ^testing.T) {
		logger := context.logger
		context = runtime.default_context()
		context.logger = logger
		if !testing.expect(t, bool(glfw.Init()), "GLFW initialization failed") do return
		defer glfw.Terminate()
		test_gpu := test_gpu_open(LEGS_SHOT_W, LEGS_SHOT_H, "Player legs")
		if !testing.expect(t, test_gpu.ok, "no GPU device for the test") do return
		defer test_gpu_close(&test_gpu, t)
		g_test_gpu = &test_gpu
		window := test_gpu.window
		gpu_set_target(test_gpu_current_target(), LEGS_SHOT_W, LEGS_SHOT_H)
		client := Client{window = window, scene = scene_init(), fps_scene = scene_init()}
		g_client = &client
		defer { g_client = nil }
		config := shared.config_load_gameplay()
		defer shared.config_destroy_gameplay(config)
		map_inst := shared.Map{death_y = -1000}
		maps := []^shared.Map{&map_inst}
		shared.game_configure(&client.game, &config.game, maps, nil, config.weapons, config.classes)
		shared.game_init(&client.game, 0, 0, true)
		defer {
			client_clear_players(&client)
			shared.game_destroy(&client.game)
			scene_fini(client.fps_scene)
			scene_fini(client.scene)
			resource_cache_fini()
		}

		remote := shared.player_init(&client.game)
		shared.game_players_add(&client.game, remote)
		shared.player_spawn(remote, 0)
		remote.uid, remote.active, remote.swap_timer = 2, true, 0
		player_generate_meshes(remote, false)
		scene_add_player_mesh(client.scene, cast(^Player_Mesh)remote.mesh, int(remote.loadout_size))

		// Side view of a remote player facing -z.
		camera := camera_init(DEFAULT_WEAPON_FOV)
		camera.position = {12, 4.5, 0}
		camera.rotation = {0, math.PI / 2, 0}

		mid_stride := f32(math.PI / 2) // A stopped walk keeps its last stride, as in Krunker.
		states := [?]Legs_State{
			{"standing", 0, 0, 0},
			{"standing_crouch_0.001", 0.001, 0, 0},
			{"standing_crouch_0.02", 0.02, 0, 0},
			{"mid_crouch_0.4", 0.4, 0, 0},
			{"mid_crouch_0.6", 0.6, 0, 1},
			{"crouched", 1, 0, 1},
			{"walking", 0, 0.9, 0},
			{"stopped_after_walk", 0, mid_stride, 0},
			{"crouch_walking", 1, 0.9, 1},
		}
		for state in states {
			remote.crouch_val, remote.step_val, remote.step_chase = state.crouch, state.step, state.step
			shared.player_update_height(remote)
			player_update_meshes(remote, false)
			legs_check_rig(t, remote, state.rig_crouch, state.name)
			legs_shot(t, client.scene, &camera, state.name)
		}

		// Remote players show Krunker's binary crouch (the official server sends
		// Math.round(crouchVal)) without the rig rewriting the player's state.
		remote.crouch_val, remote.step_val = 0.02, 0
		player_update_meshes(remote, false)
		testing.expect(t, remote.crouch_val == 0.02, "the rig must not rewrite the player's crouch state")

		// Third-person you follows its own continuous crouch, as Krunker's
		// updateHeight does, and strides like everyone else.
		scene_remove_player_mesh(client.scene, cast(^Player_Mesh)remote.mesh, int(remote.loadout_size))
		client.game.config.third_person = true
		you := shared.player_init(&client.game)
		shared.game_players_add(&client.game, you)
		shared.player_spawn(you, 0)
		you.uid, you.active, you.swap_timer, you.is_you = 1, true, 0, true
		player_generate_meshes(you, true)
		scene_add_player_mesh(client.scene, cast(^Player_Mesh)you.mesh, int(you.loadout_size))
		you_states := [?]Legs_State{
			{"third_person_standing", 0, 0, 0},
			{"third_person_crouching_0.5", 0.5, 0, 0.5},
			{"third_person_crouched", 1, 0, 1},
			{"third_person_walking", 0, 0.9, 0},
		}
		for state in you_states {
			you.crouch_val, you.step_val, you.step_chase = state.crouch, state.step, state.step
			shared.player_update_height(you)
			player_update_meshes(you, false)
			legs_check_rig(t, you, state.rig_crouch, state.name)
			legs_shot(t, client.scene, &camera, state.name)
		}
		rig := cast(^Player_Mesh)you.mesh
		testing.expect(t, rig.legs[0].transform.rotation.x != 0, "third-person legs must stride with the walk cycle")
		// Same direction as Krunker's server leg boxes: the left leg (-x) swings
		// with +stepAnim, so model and hitbox legs move together.
		you.crouch_val, you.step_val, you.step_chase = 0, 0.9, 0.9
		shared.player_update_height(you)
		player_update_meshes(you, false)
		testing.expect(t, rig.legs[0].transform.position.x < 0, "legs[0] is the left leg")
		testing.expect(t, rig.legs[0].transform.rotation.x > 0 && rig.legs[1].transform.rotation.x < 0, "left leg strides +, right leg -, as Krunker's hitboxes")
		pose := shared.krunker_hurtbox_pose(you, false)
		boxes: [shared.KRUNKER_HURTBOX_MAX]shared.Krunker_Hurtbox
		count := shared.krunker_player_hurtboxes(pose, &boxes)
		left_foot_z: f32
		for box in boxes[:count] {
			if box.part != .LEG { continue }
			centre := (box.transform * shared.Vec4{0, 0, 0, 1})
			local := linalg.inverse(linalg.matrix4_translate_f32(pose.position) * linalg.matrix4_rotate_f32(pose.yaw, {0, 1, 0})) * centre
			if local.x < 0 { left_foot_z = local.z }
		}
		model_left_z := -math.sin(rig.legs[0].transform.rotation.x) // hip-hung leg: foot moves to -sin(rx)*len
		testing.expect(t, (left_foot_z < 0) == (model_left_z < 0), "model left leg and left leg hitbox must swing the same way")
	}
}
