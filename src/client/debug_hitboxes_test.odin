package main

import "base:runtime"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:testing"
import gl "vendor:OpenGL"
import mu "vendor:microui"
import glfw "vendor:glfw"
import stbi "vendor:stb/image"
import shared "../shared"

when ODIN_TEST {
	HITBOX_SHOT_W :: 640
	HITBOX_SHOT_H :: 360

	@(test)
	debug_render_toggles_default_off :: proc(t: ^testing.T) {
		client: Client
		dr := &client.debug_render
		testing.expect(t, !dr.player_hitboxes && !dr.map_collision && !dr.shot_rays && !dr.xray, "every Rendering toggle starts off")
		testing.expect(t, !debug_render_enabled(dr), "nothing is drawn with every toggle off")
		// Off means no work: no lines, no GL objects, no recorded shots.
		append(&client.game.impacts, shared.Bullet_Impact{origin = {0, 9.5, 0}, position = {0, 9.5, -40}, hit = true, kind = .World})
		defer delete(client.game.impacts)
		debug_render_record_impacts(&client, 0)
		debug_render_after_world(&client)
		debug_render_after_viewmodel(&client)
		testing.expect(t, len(dr.lines) == 0 && dr.program == 0 && dr.shot_count == 0, "disabled toggles must not build lines, create GL objects or record shots")
	}

	// Position of a text command drawn by the debug window this frame.
	debug_test_text_pos :: proc(dbg: ^Debug_UI, label: string) -> (pos: [2]f32, found: bool) {
		command: ^mu.Command
		for variant in mu.next_command_iterator(&dbg.ctx, &command) {
			if text, ok := variant.(^mu.Command_Text); ok && text.str == label {
				return {f32(text.pos.x) + 4, f32(text.pos.y) + 4}, true
			}
		}
		return
	}

	debug_test_click :: proc(client: ^Client, dbg: ^Debug_UI, at: [2]f32) {
		perf_test_frame(client, dbg, {pointer = at})
		perf_test_frame(client, dbg, {pointer = at})
		perf_test_frame(client, dbg, {pointer = at, buttons = {.LEFT}})
		perf_test_frame(client, dbg, {pointer = at})
	}

	@(test)
	debug_ui_rendering_section_toggles :: proc(t: ^testing.T) {
		client, dbg := perf_test_debug_ui()
		defer { free(dbg); free(client) }
		perf_test_frame(client, dbg, {})
		perf_test_frame(client, dbg, {}) // The window fits its content height after a frame.
		header, has_header := debug_test_text_pos(dbg, "Rendering")
		_, shown_collapsed := debug_test_text_pos(dbg, "Player hitboxes")
		testing.expect(t, has_header && !shown_collapsed, "the Rendering section starts collapsed")
		debug_test_click(client, dbg, header)
		toggles := [?]string{"Player hitboxes", "Map collision (150u)", "Shot rays", "X-ray (offline only)"}
		for label in toggles {
			at, found := debug_test_text_pos(dbg, label)
			if !testing.expectf(t, found, "%s checkbox is listed (header at %v)", label, header) { return }
			debug_test_click(client, dbg, at)
		}
		dr := &client.debug_render
		testing.expect(t, dr.player_hitboxes && dr.map_collision && dr.shot_rays && dr.xray, "each checkbox flips its toggle")
		_, labelled := debug_test_text_pos(dbg, "SR Client shot boxes")
		testing.expect(t, labelled, "the hitbox model in use is labelled")
	}

	@(test)
	debug_hitboxes_draw_the_tested_boxes :: proc(t: ^testing.T) {
		player := shared.Player{active = true, scale = shared.GAME_CONSTANTS.player_scale, position = {3.5, 1.25, -20}}
		for crouch in ([3]f32{0, 0.5, 1}) {
			player.crouch_val = crouch
			shared.player_update_height(&player)
			for kind in shared.Hitbox_Kind {
				lines: [dynamic]Debug_Line_Vertex
				defer delete(lines)
				debug_lines_player(&lines, &player, .SR_CLIENT, kind, false)
				if !testing.expect(t, len(lines) == 48, "SR Client players draw two boxes of 12 edges") { return }
				body, head := shared.player_hitboxes(&player, kind)
				for box, b in ([2]shared.Box{body, head}) {
					// ray_box_hit's slab bounds for this box.
					want_min := shared.Vec3{box.origin.x - box.scale.x * 0.5, box.origin.y, box.origin.z - box.scale.z * 0.5}
					want_max := shared.Vec3{box.origin.x + box.scale.x * 0.5, box.origin.y + box.scale.y, box.origin.z + box.scale.z * 0.5}
					got_min, got_max := lines[b * 24].position, lines[b * 24].position
					for vertex in lines[b * 24:][:24] {
						got_min = linalg.min(got_min, vertex.position)
						got_max = linalg.max(got_max, vertex.position)
					}
					testing.expectf(t, linalg.length(got_min - want_min) < 1e-4 && linalg.length(got_max - want_max) < 1e-4,
						"crouch %v %v box %d: drawn %v..%v, hit-tested %v..%v", crouch, kind, b, got_min, got_max, want_min, want_max)
					testing.expect(t, lines[b * 24].color == (b == 0 ? DEBUG_COLOR_BODY : DEBUG_COLOR_HEAD), "body and head use different colours")
				}
			}
		}
	}

	hurtbox_center :: proc(box: shared.Krunker_Hurtbox) -> shared.Vec3 {
		return (box.transform * shared.Vec4{0, 0, 0, 1}).xyz
	}

	hurtbox_size :: proc(box: shared.Krunker_Hurtbox) -> shared.Vec3 {
		m := box.transform
		return {linalg.length(m[0].xyz), linalg.length(m[1].xyz), linalg.length(m[2].xyz)}
	}

	near3 :: proc(a, b: shared.Vec3, tolerance: f32 = 1e-3) -> bool { return linalg.length(a - b) <= tolerance }

	@(test)
	krunker_hurtboxes_follow_krunker_rig :: proc(t: ^testing.T) {
		weapon := shared.WEAPON_AK47
		boxes: [shared.KRUNKER_HURTBOX_MAX]shared.Krunker_Hurtbox
		pose := shared.Krunker_Hurtbox_Pose{position = {0, 0, 0}, weapon = &weapon}
		count := shared.krunker_player_hurtboxes(pose, &boxes)
		testing.expect(t, count == 10, "standing: head, torso, 3 boxes per arm, 2 legs")
		testing.expect(t, boxes[0].part == .HEAD && near3(hurtbox_center(boxes[0]), {0, 10, 0}) && near3(hurtbox_size(boxes[0]), {2, 2, 2}),
			"head: a 2-unit cube from 9 to 11")
		testing.expect(t, boxes[1].part == .TORSO && near3(hurtbox_center(boxes[1]), {0, 6.6, 0}) && near3(hurtbox_size(boxes[1]), {2.6, 4.8, 1.3}),
			"torso: chestWidth x 4.8 x chestScale from legHeight to 9")
		legs := 0
		for box in boxes[:count] {
			if box.part == .LEG {
				legs += 1
				c := hurtbox_center(box)
				testing.expect(t, abs(abs(c.x) - 0.65) < 1e-3 && abs(c.y - 2.1) < 1e-3 && near3(hurtbox_size(box), {1.3, 4.2, 1.3}), "standing legs hang from the hips")
			}
			if box.part == .ARM {
				c := hurtbox_center(box)
				testing.expectf(t, c.z < 0 && c.y > 6 && c.y < 10, "arms reach forward (-z) at chest height, got %v", c)
			}
		}
		testing.expect(t, legs == 2)

		pose.crouch = 1
		count = shared.krunker_player_hurtboxes(pose, &boxes)
		testing.expect(t, count == 14, "crouched: bent legs are 3 boxes each")
		testing.expect(t, near3(hurtbox_center(boxes[0]), {0, 7, 0}), "crouching drops the head by crouchDst")

		pose.crouch, pose.moving = 0, true
		shared.krunker_player_hurtboxes(pose, &boxes)
		testing.expect(t, near3(hurtbox_size(boxes[0]), {4, 4, 4}), "moving targets get 1 unit of padding per side")

		pose.moving, pose.pitch = false, -0.6
		shared.krunker_player_hurtboxes(pose, &boxes)
		head := hurtbox_center(boxes[0])
		testing.expect(t, head.z < -1 && head.y < 10, "looking down tilts the upper body (yD * 0.5) forward")

		pose.pitch, pose.yaw, pose.position = 0, math.PI / 2, {5, 2, 7}
		shared.krunker_player_hurtboxes(pose, &boxes)
		testing.expect(t, near3(hurtbox_center(boxes[0]), {5, 12, 7}), "the rig follows the position")
	}

	debug_test_project :: proc(view_projection: shared.Mat4, point: shared.Vec3) -> (pixel: [2]int, ok: bool) {
		screen, visible := player_healthbar_project(view_projection, point, HITBOX_SHOT_W, HITBOX_SHOT_H)
		return {int(math.round(screen.x)), int(math.round(screen.y))}, visible
	}

	// Whether a pixel within `radius` of the screen point (top-left origin) matches.
	debug_test_pixel_near :: proc(pixels: []u8, at: [2]int, radius: int, match: proc(r, g, b: u8) -> bool) -> bool {
		for dy in -radius ..= radius {
			for dx in -radius ..= radius {
				x, y := at.x + dx, at.y + dy
				if x < 0 || y < 0 || x >= HITBOX_SHOT_W || y >= HITBOX_SHOT_H { continue }
				i := ((HITBOX_SHOT_H - 1 - y) * HITBOX_SHOT_W + x) * 3
				if match(pixels[i], pixels[i + 1], pixels[i + 2]) { return true }
			}
		}
		return false
	}

	debug_test_lit_pixels :: proc(pixels: []u8) -> (lit: int) {
		for i := 0; i < len(pixels); i += 3 { if pixels[i] > 60 || pixels[i + 1] > 60 || pixels[i + 2] > 60 { lit += 1 } }
		return
	}

	debug_test_read :: proc(pixels: []u8) {
		gl.PixelStorei(gl.PACK_ALIGNMENT, 1)
		ui_flush()
		gl.ReadPixels(0, 0, HITBOX_SHOT_W, HITBOX_SHOT_H, gl.RGB, gl.UNSIGNED_BYTE, raw_data(pixels))
	}

	debug_test_save :: proc(pixels: []u8, path: cstring) {
		os.make_directory("bin/debug_hitboxes")
		stbi.write_png(path, HITBOX_SHOT_W, HITBOX_SHOT_H, 3, &pixels[(HITBOX_SHOT_H - 1) * HITBOX_SHOT_W * 3], -HITBOX_SHOT_W * 3)
	}

	is_green :: proc(r, g, b: u8) -> bool { return g > 200 && r < 120 && b < 160 }
	is_yellow :: proc(r, g, b: u8) -> bool { return r > 200 && g > 180 && b < 100 }

	// A remote player 30 units in front of the camera: the wireframes land on
	// the screen where the hit-tested boxes project, the depth-tested pass is
	// hidden behind nearer depth while x-ray is not, and screenshots of both
	// hitbox models are written to bin/debug_hitboxes/.
	@(test)
	debug_hitboxes_render_at_projected_boxes :: proc(t: ^testing.T) {
		logger := context.logger
		context = runtime.default_context()
		context.logger = logger
		if !testing.expect(t, bool(glfw.Init()), "GLFW initialization failed") do return
		defer glfw.Terminate()
		glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)
		glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 5)
		window := glfw.CreateWindow(HITBOX_SHOT_W, HITBOX_SHOT_H, "Debug hitboxes", nil, nil)
		if !testing.expect(t, window != nil, "hidden OpenGL window failed") do return
		defer glfw.DestroyWindow(window)
		glfw.MakeContextCurrent(window)
		gl.load_up_to(4, 5, glfw.gl_set_proc_address)
		gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
		gl.Viewport(0, 0, HITBOX_SHOT_W, HITBOX_SHOT_H)

		client := Client{window = window, scene = scene_init(), fps_scene = scene_init(), viewport_width = HITBOX_SHOT_W, viewport_height = HITBOX_SHOT_H}
		g_client = &client
		defer { g_client = nil }
		config := shared.config_load_gameplay()
		defer shared.config_destroy_gameplay(config)
		crate := shared.Object{active = true, collision_type = .BOX, position = {-13, 0, -32}, scale = {5, 9, 5}}
		zone := shared.Object{active = true, collision_type = .CYLINDER, no_shoot = true, position = {13, 0, -32}, scale = {7, 12, 7}}
		far_box := shared.Object{active = true, collision_type = .BOX, position = {0, 0, -400}, scale = {10, 10, 10}}
		map_inst := shared.Map{death_y = -1000}
		append(&map_inst.objects, &crate, &zone, &far_box)
		maps := []^shared.Map{&map_inst}
		shared.game_configure(&client.game, &config.game, maps, nil, config.weapons, config.classes)
		shared.game_init(&client.game, 0, 0, true)
		defer {
			debug_render_fini(&client.debug_render)
			client_clear_players(&client)
			shared.game_destroy(&client.game)
			scene_fini(client.fps_scene)
			scene_fini(client.scene)
			resource_cache_fini()
		}

		me := shared.player_init(&client.game)
		shared.game_players_add(&client.game, me)
		shared.player_spawn(me, 0)
		me.uid, me.active, me.is_you, me.position = 1, true, true, {0, 0, 0}
		client.me = me
		remote := shared.player_init(&client.game)
		shared.game_players_add(&client.game, remote)
		shared.player_spawn(remote, 0)
		remote.uid, remote.active, remote.swap_timer = 2, true, 0
		remote.position, remote.last_position, remote.direction = {0, 0, -30}, {0, 0, -30}, {0, math.PI} // Facing the camera.

		camera := camera_init(math.PI / 2)
		camera.position = {0, 6, 0}
		camera_update_projection_matrix(&camera, f32(HITBOX_SHOT_W) / f32(HITBOX_SHOT_H))
		camera_update_world_inverse_matrix(&camera)
		client.camera = camera
		view_projection := camera.projection_matrix * camera.world_inverse_matrix
		dr := &client.debug_render
		pixels := make([]u8, HITBOX_SHOT_W * HITBOX_SHOT_H * 3)
		defer delete(pixels)

		// 1. Lines alone on black: edges at the projected hit-tested boxes.
		dr.player_hitboxes = true
		debug_render_build(&client, 0)
		testing.expect(t, len(dr.lines) == 48, "only the remote player is drawn (first-person you is not)")
		gl.ClearColor(0, 0, 0, 1)
		ui_flush()
		gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
		testing.expect(t, debug_render_lines(dr, view_projection, true) == 48)
		testing.expect(t, gl.GetError() == gl.NO_ERROR, "wireframes must draw without OpenGL errors")
		debug_test_read(pixels)
		body, head := shared.player_hitboxes(remote, .SHOT)
		front_z := body.origin.z + body.scale.z * 0.5
		left_x := body.origin.x - body.scale.x * 0.5
		body_left_mid, ok1 := debug_test_project(view_projection, {left_x, body.origin.y + body.scale.y * 0.5, front_z})
		body_center, ok2 := debug_test_project(view_projection, {body.origin.x, body.origin.y + body.scale.y * 0.5, front_z})
		head_top_mid, ok3 := debug_test_project(view_projection, {head.origin.x, head.origin.y + head.scale.y, head.origin.z + head.scale.z * 0.5})
		testing.expect(t, ok1 && ok2 && ok3, "the target is in front of the camera")
		testing.expectf(t, debug_test_pixel_near(pixels, body_left_mid, 1, is_green), "body edge must be drawn at its projected position %v", body_left_mid)
		testing.expectf(t, debug_test_pixel_near(pixels, head_top_mid, 1, is_yellow), "head edge must be drawn at its projected position %v", head_top_mid)
		black :: proc(r, g, b: u8) -> bool { return r < 20 && g < 20 && b < 20 }
		testing.expect(t, debug_test_pixel_near(pixels, body_center, 0, black), "boxes are wireframes, not filled")
		shifted := body_left_mid + {12, 0}
		testing.expect(t, !debug_test_pixel_near(pixels, shifted, 1, is_green), "no body edge where the box is not")

		// 2. Depth-tested lines hide behind nearer depth; x-ray shows through.
		gl.ClearDepth(0)
		ui_flush()
		gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
		debug_render_lines(dr, view_projection, true)
		debug_test_read(pixels)
		testing.expect(t, debug_test_lit_pixels(pixels) == 0, "depth-tested wireframes must be hidden behind nearer geometry")
		debug_render_lines(dr, view_projection, false)
		debug_test_read(pixels)
		testing.expect(t, debug_test_lit_pixels(pixels) > 100, "x-ray wireframes must show through geometry")
		testing.expect(t, gl.IsEnabled(gl.DEPTH_TEST) && gl.GetError() == gl.NO_ERROR, "line drawing must restore depth testing")
		gl.ClearDepth(1)

		// 3. Screenshots over the real player model, with map collision (only
		// the two nearby objects) and a recorded shot ray.
		dr.map_collision, dr.shot_rays = true, true
		append(&client.game.impacts, shared.Bullet_Impact{origin = {9, 9.5, -8}, position = {0.4, 9.2, -27.5}, hit = true, kind = .Player, shooter_uid = 1})
		debug_render_record_impacts(&client, 0)
		clear(&client.game.impacts)
		testing.expect(t, dr.shot_count == 1, "the local player's shot is recorded")
		player_generate_meshes(remote, false)
		scene_add_player_mesh(client.scene, cast(^Player_Mesh)remote.mesh, int(remote.loadout_size))
		player_update_meshes(remote, false)
		debug_render_build(&client, 0)
		testing.expect(t, len(dr.lines) == 48 + 24 + (16*2 + 4)*2 + 2 + 6, "players, the two nearby map objects and the shot ray")
		shots := [2]cstring{"bin/debug_hitboxes/sr_hitboxes.png", "bin/debug_hitboxes/krunker_hurtboxes.png"}
		for model, i in ([2]Debug_Hitbox_Model{.SR_CLIENT, .KRUNKER}) {
			if model == .KRUNKER {
				clear(&dr.lines)
				debug_lines_player(&dr.lines, remote, .KRUNKER, .SHOT, false)
				debug_lines_map(&dr.lines, &client.game, camera.position, DEBUG_MAP_RANGE)
			}
			gl.ClearColor(0.55, 0.62, 0.7, 1)
			ui_flush()
			gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
			scene_render(client.scene, &camera, HITBOX_SHOT_W, HITBOX_SHOT_H)
			scene_err := gl.GetError()
			testing.expectf(t, scene_err == gl.NO_ERROR, "the world pass after a wireframe pass must draw without OpenGL errors (0x%x)", scene_err)
			debug_render_lines(dr, view_projection, true)
			err := gl.GetError()
			testing.expectf(t, err == gl.NO_ERROR, "wireframes over the scene must draw without OpenGL errors (0x%x)", err)
			debug_test_read(pixels)
			debug_test_save(pixels, shots[i])
		}
	}
}
