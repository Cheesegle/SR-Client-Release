package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:testing"
import "core:time"
import gl "vendor:OpenGL"
import glfw "vendor:glfw"
import shared "../shared"
import kproto "../krunker"
import menuui "../menu"

when ODIN_TEST {
	@(test)
	krunker_health_updates_target_players :: proc(t: ^testing.T) {
		world := kproto.Krunker_World_State{local_sid = 7}
		defer kproto.krunker_world_reset(&world)
		append(&world.players,
			kproto.Krunker_World_Player{sid = 7, health = 100, max_health = 100, active = true, sync_revision = 4},
			kproto.Krunker_World_Player{sid = 8, health = 170, max_health = 170, active = true})
		testing.expect(t, kproto.krunker_world_apply_packet(&world, []kproto.Krunker_Msgpack_Value{"h", i64(85), i64(8)}))
		testing.expect(t, world.players[1].health == 85 && world.players[1].max_health == 170 && world.players[0].health == 100,
			"remote health changes must target the supplied SID and preserve class maximum health")
		kproto.krunker_world_apply_packet(&world, []kproto.Krunker_Msgpack_Value{"h", i64(45), kproto.Krunker_Msgpack_Nil{}})
		testing.expect(t, world.players[0].health == 45 && world.players[0].sync_revision == 4,
			"a nil SID targets local health without replaying an old movement correction")
		kproto.krunker_world_apply_packet(&world, []kproto.Krunker_Msgpack_Value{"h", i64(80), i64(8), i64(0), i64(0), true, true})
		testing.expect(t, world.players[1].health == 80 && world.players[1].max_health == 80, "server maximum-health resets must update the bar denominator")
		kproto.krunker_world_apply_packet(&world, []kproto.Krunker_Msgpack_Value{"h", i64(120), i64(8)})
		testing.expect(t, world.players[1].max_health == 120, "server overheal must raise maximum health")
		testing.expect(t, !kproto.krunker_world_apply_packet(&world, []kproto.Krunker_Msgpack_Value{"h", i64(-5), i64(8)}) && world.players[1].health == 120,
			"invalid health must not overwrite a valid player state")
		kproto.krunker_world_apply_packet(&world, []kproto.Krunker_Msgpack_Value{i64(3), i64(8)})
		testing.expect(t, !world.players[1].active && world.players[1].health == 0, "death messages must remove a remote health bar")
		kproto.krunker_world_apply_packet(&world, []kproto.Krunker_Msgpack_Value{"2", i64(7)})
		testing.expect(t, !world.players[0].active, "disconnected players must not leave stale bars")
		roster: [53]kproto.Krunker_Msgpack_Value
		roster[1], roster[6], roster[8] = i64(8), i64(3), i64(170)
		kproto.krunker_world_apply_packet(&world, []kproto.Krunker_Msgpack_Value{i64(0), roster[:]})
		testing.expect(t, world.players[1].active && world.players[1].health == 170 && world.players[1].max_health == 170,
			"a nil roster health on respawn must mean full class health instead of preserving the previous dead state")
	}

	healthbar_test_colors :: proc(client: ^Client, pixels: []u8) -> (red, green: int) {
		red, green, _ = nameplate_test_colors(client, pixels)
		return
	}

	// Lets the visibility fades settle (one second of frames), then draws.
	nameplate_test_colors :: proc(client: ^Client, pixels: []u8) -> (red, green, white: int) {
		healthbar_test_settle(client)
		red, green, white, _ = nameplate_test_draw(client, pixels)
		return
	}

	// Draws with the current nameplate alphas. red_level sums the red channel
	// of red-dominant pixels, so it scales with the bar's alpha.
	nameplate_test_draw :: proc(client: ^Client, pixels: []u8) -> (red, green, white, red_level: int) {
		ui_flush()
		gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
		scene_render(client.scene, &client.camera, f32(client.viewport_width), f32(client.viewport_height))
		player_healthbars_render(client)
		ui_flush()
		gl.ReadPixels(0, 0, client.viewport_width, client.viewport_height, gl.RGB, gl.UNSIGNED_BYTE, raw_data(pixels))
		for i := 0; i < len(pixels); i += 3 {
			if pixels[i] > 200 && pixels[i+1] < 120 && pixels[i+2] < 120 { red += 1 }
			if pixels[i] < 190 && pixels[i+1] > 200 && pixels[i+2] < 140 { green += 1 }
			if pixels[i] > 200 && pixels[i+1] > 200 && pixels[i+2] > 200 { white += 1 }
			if int(pixels[i]) > int(pixels[i+1]) + 40 && int(pixels[i]) > int(pixels[i+2]) + 40 { red_level += int(pixels[i]) }
		}
		return
	}

	@(test)
	healthbars_render_above_players_as_unclipped_overlay :: proc(t: ^testing.T) {
		if !testing.expect(t, bool(glfw.Init())) { return }
		defer glfw.Terminate()
		glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)
		glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 5)
		window := glfw.CreateWindow(640, 360, "Overhead health bar regression", nil, nil)
		if !testing.expect(t, window != nil) { return }
		defer glfw.DestroyWindow(window)
		glfw.MakeContextCurrent(window)
		gl.load_up_to(4, 5, glfw.gl_set_proc_address)
		gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
		gl.Viewport(0, 0, 640, 360)
		gl.ClearColor(0, 0, 0, 1)
		local := shared.Player{active = true, is_you = true, team = 1, position = {0, 0, -80}, height = 11, health = 100, max_health = 100}
		enemy := shared.Player{active = true, team = 2, position = {-20, 0, -80}, height = 11, health = 100, max_health = 100}
		ally := shared.Player{active = true, team = 1, position = {20, 0, -80}, height = 11, health = 100, max_health = 100}
		client := Client{in_game = true, viewport_width = 640, viewport_height = 360, me = &local}
		client.mouse_state.locked = true
		client.hud_settings.hide_nametags = true // bar pixels only; names have their own test
		client.camera = camera_init(math.PI/2)
		client.camera.position = {0, 12.8, 0}
		client.scene, client.ui = scene_init(), ui_init()
		append(&client.game.players, &local, &enemy, &ally)
		defer {
			delete(client.game.players)
			ui_fini(client.ui)
			scene_fini(client.scene)
			resource_cache_fini()
		}
		pixels := make([]u8, 640*360*3, context.temp_allocator)
		red, green := healthbar_test_colors(&client, pixels)
		testing.expect(t, red > 20 && green > 20 && abs(red-green) < 5, "both enemies and teammates must have visible, equally sized bars in their team colors")
		enemy.health = 50
		half_red, same_green := healthbar_test_colors(&client, pixels)
		testing.expect(t, half_red > red/3 && half_red < red*2/3 && same_green == green, "taking damage must shrink only the affected player's fill")
		material := basic_material_init()
		material.unlit, material.no_fog, material.color = true, true, {0.1, 0.1, 0.1, 1}
		wall := mesh_init(create_cube_geo(), &material.base)
		wall.transform.position, wall.transform.scale = {0, -100, -40}, {200, 200, 1}
		scene_add_mesh(client.scene, wall)
		defer mesh_fini(wall)
		// A surface between the camera and the bars (a wall-mounted prop, or
		// a wall the line-of-sight gate does not count as blocking) must not
		// cut the bars: Krunker draws them on a 2D overlay canvas.
		covered_red, covered_green := healthbar_test_colors(&client, pixels)
		testing.expectf(t, covered_red == half_red && covered_green == green, "geometry in front of a shown bar must never clip it, even partially (%d/%d red, %d/%d green)", covered_red, half_red, covered_green, green)
		testing.expect(t, !gl.IsEnabled(gl.DEPTH_TEST), "overlay bars must be drawn without depth testing")
		wall.transform.position, wall.transform.scale = {-10, -100, -40}, {3, 200, 1}
		half_covered_red, half_covered_green := healthbar_test_colors(&client, pixels)
		testing.expectf(t, half_covered_red == half_red && half_covered_green == green, "a surface covering half a bar must not cut that bar in half (%d/%d red)", half_covered_red, half_red)
		scene_remove_mesh(client.scene, wall)
		los_wall := shared.Object{active = true, collision_type = .BOX, position = {-10, 0, -80}, scale = {2, 40, 12}}
		los_map := shared.Map{}
		append(&los_map.objects, &los_wall)
		defer delete(los_map.objects)
		client.game.map_inst = &los_map
		hidden_red, wall_green := healthbar_test_colors(&client, pixels)
		testing.expect(t, hidden_red == 0 && wall_green == green, "an enemy behind map geometry must get no bar (ESP) while the teammate keeps one")
		// A low wall hides the enemy's feet but not the head or chest.
		los_wall.scale.y = 6
		partial_red, _ := healthbar_test_colors(&client, pixels)
		testing.expectf(t, partial_red == half_red, "a partly occluded enemy keeps a full bar (%d/%d red)", partial_red, half_red)
		testing.expect(t, enemy.nameplate_alpha == 1 && !shared.map_can_see(&los_map, player_healthbar_eye(&local), enemy.position),
			"the low wall hides the feet, yet the plate is fully shown")
		// The renderer uses the fade alpha: half-faded is dimmer, zero is gone.
		_, _, _, full_level := nameplate_test_draw(&client, pixels)
		enemy.nameplate_alpha = 0.5
		_, _, _, half_level := nameplate_test_draw(&client, pixels)
		enemy.nameplate_alpha = 0
		faded_red, faded_green, _, faded_level := nameplate_test_draw(&client, pixels)
		testing.expectf(t, half_level > full_level/4 && half_level < full_level*3/4, "a half-faded bar is drawn at about half intensity (%d of %d)", half_level, full_level)
		testing.expect(t, faded_red == 0 && faded_level == 0 && faded_green == green, "a fully faded enemy bar is not drawn; the teammate's is untouched")
		los_wall.scale.y = 40
		client.game.map_inst = nil
		client.mouse_state.locked = false
		menu_red, menu_green := healthbar_test_colors(&client, pixels)
		testing.expect(t, menu_red == 0 && menu_green == 0, "bars must disappear while the menu is open")
		client.mouse_state.locked = true
		client.in_game = false
		lobby_red, lobby_green := healthbar_test_colors(&client, pixels)
		testing.expect(t, lobby_red == 0 && lobby_green == 0, "bars must only render during gameplay")
		client.in_game = true
		enemy.position.z, ally.position.z = 80, 80
		behind_red, behind_green := healthbar_test_colors(&client, pixels)
		testing.expect(t, behind_red == 0 && behind_green == 0, "players behind the camera must not produce mirrored bars")
		enemy.position.z, ally.position.z = -80, -80
		enemy.active, ally.health = false, 0
		dead_red, dead_green := healthbar_test_colors(&client, pixels)
		testing.expect(t, dead_red == 0 && dead_green == 0, "inactive/dead players and the local player must not get overhead bars")
		testing.expect(t, gl.GetError() == gl.NO_ERROR, "health bar and world rendering must preserve valid OpenGL state")
	}

	healthbar_test_settle :: proc(client: ^Client, seconds: f32 = 1) {
		start := client.healthbar_visibility_time
		frames := int(seconds*60)
		for i in 1 ..= frames { player_healthbars_update_visibility(client, start + f32(i)/60) }
	}

	// Steps the visibility update at 144 Hz for `seconds`, tracking the alpha range seen.
	healthbar_test_run :: proc(client: ^Client, player: ^shared.Player, seconds: f32) -> (lowest, highest: f32) {
		lowest, highest = 2, -1
		start := client.healthbar_visibility_time
		frames := int(math.ceil(seconds*144))
		for i in 1 ..= frames {
			player_healthbars_update_visibility(client, start + f32(i)/144)
			lowest, highest = min(lowest, player.nameplate_alpha), max(highest, player.nameplate_alpha)
		}
		return
	}

	// Steps at 144 Hz until the alpha reaches `target`; returns the time taken.
	healthbar_test_time_to :: proc(client: ^Client, player: ^shared.Player, target: f32, limit: f32 = 2) -> (elapsed: f32, partial: bool) {
		start := client.healthbar_visibility_time
		for i in 1 ..= int(limit*144) {
			player_healthbars_update_visibility(client, start + f32(i)/144)
			if player.nameplate_alpha == target { return f32(i)/144, partial }
			if player.nameplate_alpha > 0 && player.nameplate_alpha < 1 { partial = true }
		}
		return limit, partial
	}

	@(test)
	healthbars_follow_nameplate_visibility_rules :: proc(t: ^testing.T) {
		local := shared.Player{active = true, is_you = true, team = 1, position = {0, 0, 0}, height = 11, health = 100, max_health = 100}
		enemy := shared.Player{active = true, team = 2, position = {0, 0, -80}, height = 11, health = 100, max_health = 100}
		ally := shared.Player{active = true, team = 1, position = {6, 0, -80}, height = 11, health = 100, max_health = 100}
		floor := shared.Object{active = true, collision_type = .BOX, position = {0, -10, -40}, scale = {400, 10, 400}}
		wall := shared.Object{active = true, collision_type = .BOX, position = {0, 0, -40}, scale = {200, 30, 2}}
		world := shared.Map{}
		append(&world.objects, &floor, &wall)
		defer delete(world.objects)
		client := Client{me = &local}
		client.game.map_inst = &world
		append(&client.game.players, &local, &enemy, &ally)
		defer delete(client.game.players)

		healthbar_test_settle(&client)
		testing.expect(t, !enemy.can_be_seen && enemy.nameplate_alpha == 0, "an enemy fully behind a wall is hidden once the fade ends")
		testing.expect(t, ally.can_be_seen && ally.nameplate_alpha == 1, "teammates are always shown at full alpha, even through walls")

		wall.active = false
		healthbar_test_settle(&client)
		testing.expect(t, enemy.can_be_seen && enemy.nameplate_alpha == 1, "an enemy in clear sight gets a nameplate; standing on the floor must not block it")

		// Changed from Krunker's feet-only rule: a waist-high wall hides the
		// feet, but the head and chest are in sight, so the plate stays.
		wall.active, wall.scale.y = true, 6
		healthbar_test_settle(&client)
		testing.expect(t, enemy.can_be_seen && enemy.nameplate_alpha == 1, "head visible over a low wall with the feet hidden: shown")
		testing.expect(t, !shared.map_can_see(&world, player_healthbar_eye(&local), enemy.position), "the low wall really does hide the feet")
		// Crouching behind the same wall lowers the head below the sight line.
		enemy.crouch_val, enemy.height = 1, 8
		wall.scale.y = 8.5
		healthbar_test_settle(&client)
		testing.expect(t, !enemy.can_be_seen && enemy.nameplate_alpha == 0, "a crouched enemy fully behind cover is hidden (sight points follow the crouched height)")
		enemy.crouch_val, enemy.height = 0, 11
		healthbar_test_settle(&client)
		testing.expect(t, enemy.can_be_seen, "standing back up over the same cover shows the head again")
		wall.scale.y = 30

		// A wall that covers the centre line but not the hitbox edges.
		wall.scale.x = 2
		healthbar_test_settle(&client)
		testing.expect(t, enemy.can_be_seen && enemy.nameplate_alpha == 1, "a thin pole in front of the centre does not hide a player whose sides are in sight")
		wall.scale.x = 200

		see_through := []shared.Prefab{.WINDOW, .GRASS, .LIGHT_CONE, .RAMP}
		for prefab in see_through {
			wall.prefab = prefab
			healthbar_test_settle(&client)
			testing.expectf(t, enemy.can_be_seen && enemy.nameplate_alpha == 1, "%v is transparent/noShoot and must not block nameplates", prefab)
		}
		wall.prefab = .CUBE
		wall.no_shoot = true
		healthbar_test_settle(&client)
		testing.expect(t, enemy.can_be_seen, "noShoot objects must not block nameplates")
		wall.no_shoot, wall.collision_type = false, .NONE
		healthbar_test_settle(&client)
		testing.expect(t, enemy.can_be_seen, "no-collision objects must not block nameplates")
		wall.collision_type = .BOX

		wall.active = false
		client.game.config.hide_enemy_nametags = true
		healthbar_test_settle(&client)
		testing.expect(t, !enemy.can_be_seen && enemy.nameplate_alpha == 0 && ally.can_be_seen && ally.nameplate_alpha == 1, "Hide Nametags (Enemies) hides only enemy nameplates")
		client.game.config.hide_enemy_nametags = false
		wall.active = true

		local.team, ally.team, enemy.team = 0, 0, 0
		healthbar_test_settle(&client)
		testing.expect(t, !ally.can_be_seen && !enemy.can_be_seen && ally.nameplate_alpha == 0, "in FFA nobody is a teammate, so walls hide every nameplate")

		local.active = false
		local.team, ally.team = 1, 1
		healthbar_test_settle(&client)
		testing.expect(t, !ally.can_be_seen && ally.nameplate_alpha == 0 && !ally.nameplate_tracked, "a dead local player must not keep stale nameplate visibility")
	}

	@(test)
	nameplates_fade_hold_and_follow_peeks :: proc(t: ^testing.T) {
		local := shared.Player{active = true, is_you = true, team = 1, position = {0, 0, 0}, height = 11, health = 100, max_health = 100}
		enemy := shared.Player{active = true, team = 2, position = {0, 0, -80}, height = 11, health = 100, max_health = 100}
		other := shared.Player{active = true, team = 2, position = {30, 0, -80}, height = 11, health = 100, max_health = 100}
		wall := shared.Object{active = true, collision_type = .BOX, position = {0, 0, -40}, scale = {200, 30, 2}}
		world := shared.Map{}
		append(&world.objects, &wall)
		defer delete(world.objects)
		client := Client{me = &local}
		client.game.map_inst = &world
		append(&client.game.players, &local, &enemy, &other)
		defer delete(client.game.players)
		interval := 1/HEALTHBAR_VISIBILITY_RATE
		frame := f32(1)/144

		healthbar_test_settle(&client)
		testing.expect(t, enemy.nameplate_alpha == 0, "start hidden")

		// Peek: the plate starts within one update interval and fades in.
		wall.active = false
		elapsed, partial := healthbar_test_time_to(&client, &enemy, 1)
		testing.expectf(t, elapsed <= interval + NAMEPLATE_FADE_IN + 2*frame, "a peek is fully shown within one update interval plus the fade-in (%.3f s)", elapsed)
		testing.expect(t, !partial, "the plate appears at once, like Krunker's (no fade-in)")

		// Brief occlusion (a pole or prop sweeping across): the hold keeps it.
		wall.active = true
		lowest, _ := healthbar_test_run(&client, &enemy, NAMEPLATE_HOLD - 2*interval - 3*frame)
		wall.active = false
		after, _ := healthbar_test_run(&client, &enemy, 0.3)
		testing.expectf(t, lowest == 1 && after == 1, "a brief occlusion must not flicker the plate (lowest alpha %.2f)", min(lowest, after))

		// Going behind a wall: held, then faded out, never popped.
		wall.active = true
		held, _ := healthbar_test_run(&client, &enemy, NAMEPLATE_HOLD - 2*interval)
		testing.expect(t, held == 1, "the plate is held for the hold time after the last visible test")
		elapsed, partial = healthbar_test_time_to(&client, &enemy, 0)
		testing.expectf(t, !partial && elapsed <= 2*interval + 2*frame, "after the hold the plate goes at once (%.3f s)", elapsed)
		testing.expect(t, !enemy.can_be_seen, "hidden after the fade")

		// Round-robin: each player is tested once per interval, spread over frames.
		healthbar_test_settle(&client)
		wall.active = false
		elapsed_other, _ := healthbar_test_time_to(&client, &other, 1)
		testing.expectf(t, elapsed_other <= interval + NAMEPLATE_FADE_IN + 2*frame, "every player gets its turn within the interval (%.3f s)", elapsed_other)

		// Deaths and respawns never inherit a fade.
		healthbar_test_settle(&client)
		testing.expect(t, enemy.nameplate_alpha == 1, "visible before dying")
		enemy.active = false
		player_healthbars_update_visibility(&client, client.healthbar_visibility_time + frame)
		testing.expect(t, enemy.nameplate_alpha == 0 && !enemy.can_be_seen && !enemy.nameplate_tracked, "death clears the plate at once (no fade-out over a corpse)")
		wall.active = true
		enemy.active = true
		highest_after_respawn: f32
		_, highest_after_respawn = healthbar_test_run(&client, &enemy, 0.5)
		testing.expect(t, highest_after_respawn == 0, "a respawn behind a wall starts hidden, with no stale fade or hold")
		wall.active = false
		enemy.health = 0
		player_healthbars_update_visibility(&client, client.healthbar_visibility_time + frame)
		testing.expect(t, enemy.nameplate_alpha == 0 && !enemy.nameplate_tracked, "zero health counts as dead")
		enemy.health = 100
		player_healthbars_update_visibility(&client, client.healthbar_visibility_time + frame)
		testing.expect(t, enemy.can_be_seen && enemy.nameplate_alpha == 1, "a respawn in sight is tested at once and shown at once")

		// A newly created player (zeroed state) is tested on its first frame.
		newcomer := shared.Player{active = true, team = 2, position = {-30, 0, -80}, height = 11, health = 100, max_health = 100}
		newcomer.nameplate_alpha, newcomer.nameplate_seen_at = 1, client.healthbar_visibility_time // garbage that must not leak
		newcomer.nameplate_tracked = false
		wall.active = true
		append(&client.game.players, &newcomer)
		player_healthbars_update_visibility(&client, client.healthbar_visibility_time + frame)
		testing.expect(t, newcomer.nameplate_tracked && !newcomer.can_be_seen && newcomer.nameplate_alpha == 0, "a new player starts from a clean state")

		// Teammates are at full alpha from their first frame.
		mate := shared.Player{active = true, team = 1, position = {0, 0, -90}, height = 11, health = 100, max_health = 100}
		append(&client.game.players, &mate)
		player_healthbars_update_visibility(&client, client.healthbar_visibility_time + frame)
		testing.expect(t, mate.nameplate_alpha == 1 && mate.can_be_seen, "teammates never fade")

		// The display curve covers the full range.
		testing.expect(t, player_nameplate_display_alpha(0) == 0 && player_nameplate_display_alpha(1) == 1 &&
			player_nameplate_display_alpha(0.25) < player_nameplate_display_alpha(0.5), "display alpha eases from 0 to 1")
	}

	@(test)
	nameplates_skip_players_off_screen :: proc(t: ^testing.T) {
		local := shared.Player{active = true, is_you = true, position = {0, 0, 0}, height = 11, health = 100, max_health = 100}
		enemy := shared.Player{active = true, position = {0, 0, 80}, height = 11, health = 100, max_health = 100}
		client := Client{me = &local, viewport_width = 640, viewport_height = 360}
		client.camera = camera_init(math.PI/2)
		client.camera.position = {0, 9.5, 0}
		append(&client.game.players, &local, &enemy)
		defer delete(client.game.players)
		healthbar_test_settle(&client)
		testing.expect(t, !enemy.can_be_seen && !enemy.nameplate_in_view && enemy.nameplate_alpha == 0, "a player behind the camera is not traced")
		// Turning around: the anchor enters the screen and is tested that frame.
		client.camera.rotation.y = math.PI
		player_healthbars_update_visibility(&client, client.healthbar_visibility_time + 1.0/144)
		testing.expect(t, enemy.nameplate_in_view && enemy.can_be_seen && enemy.nameplate_alpha > 0, "entering the view triggers an immediate test")
	}

	// Krunker-style full scan of every object, without the segment-bounds
	// filter or collision index; the reference for the cost test.
	healthbar_test_can_see_unfiltered :: proc(map_inst: ^shared.Map, from, to: shared.Vec3) -> bool {
		segment := to - from
		for object in map_inst.objects {
			if !shared.map_object_blocks_sight(object) { continue }
			if t, _, hit := shared.ray_box_hit(from, segment, object.position, object.scale); hit && t < 1 { return false }
		}
		return true
	}

	@(test)
	healthbar_visibility_cost_on_bastion :: proc(t: ^testing.T) {
		map_inst, ok := shared.map_load_from_file("assets/maps/bastion.json")
		if !testing.expect(t, ok && map_inst != nil, "bastion loads") { return }
		defer shared.map_destroy(map_inst)
		// Deterministic positions on top of floor-sized boxes across the map.
		floors := make([dynamic]^shared.Object, context.temp_allocator)
		for object in map_inst.objects {
			if shared.map_object_blocks_sight(object) && object.scale.x > 20 && object.scale.z > 20 && object.scale.x < 400 && object.scale.z < 400 { append(&floors, object) }
		}
		if !testing.expect(t, len(floors) > 16) { return }
		players: [17]shared.Player
		client := Client{}
		client.game.map_inst = map_inst
		defer delete(client.game.players)
		seed := u32(12345)
		next :: proc(seed: ^u32) -> f32 { seed^ = seed^*1664525 + 1013904223; return f32(seed^ >> 8)/f32(1 << 24) }
		for &player, i in players {
			floor := floors[int(next(&seed)*f32(len(floors)))]
			player = shared.Player{active = true, team = i32(i % 2) + 1, height = 11, scale = shared.GAME_CONSTANTS.player_scale, health = 100, max_health = 100}
			player.position = floor.position + {(next(&seed)-0.5)*floor.scale.x*0.8, floor.scale.y, (next(&seed)-0.5)*floor.scale.z*0.8}
			append(&client.game.players, &player)
		}
		client.me = &players[0]
		players[0].is_you = true
		for &player in players[1:] { player.team = 2 } // 16 enemies
		eye := player_healthbar_eye(client.me)

		// The segment filter must never change an answer.
		mismatches, rays := 0, 0
		for &player in players[1:] {
			for point in player_healthbar_sight_points(eye, &player) {
				rays += 1
				if shared.map_can_see(map_inst, eye, point) != healthbar_test_can_see_unfiltered(map_inst, eye, point) { mismatches += 1 }
			}
		}
		testing.expectf(t, mismatches == 0, "filtered and full-scan line of sight disagree on %d of %d rays", mismatches, rays)

		REPS :: 200
		// Worst case: all 16 players tested in one frame (5 rays each when hidden).
		start := time.tick_now()
		visible := 0
		for _ in 0 ..< REPS { for &player in players[1:] { if player_healthbar_line_of_sight(map_inst, eye, &player) { visible += 1 } } }
		all_us := time.duration_microseconds(time.tick_since(start))/REPS
		start = time.tick_now()
		for _ in 0 ..< REPS {
			for &player in players[1:] {
				for point in player_healthbar_sight_points(eye, &player) { if healthbar_test_can_see_unfiltered(map_inst, eye, point) { break } }
			}
		}
		full_scan_us := time.duration_microseconds(time.tick_since(start))/REPS

		// Steady state: the real scheduler at 144 fps with every player in view
		// (no viewport, so no frustum skip), averaged over 10 seconds.
		FRAMES :: 1440
		player_healthbars_update_visibility(&client, 0)
		start = time.tick_now()
		for i in 1 ..= FRAMES { player_healthbars_update_visibility(&client, f32(i)/144) }
		frame_us := time.duration_microseconds(time.tick_since(start))/FRAMES
		fmt.printf("[healthbar-cost] bastion, 16 enemies (%d visible): all tested in one frame %.1f us (full scan %.1f us); scheduler at %v Hz per player, 144 fps: %.1f us/frame\n",
			visible/REPS, all_us, full_scan_us, HEALTHBAR_VISIBILITY_RATE, frame_us)
		testing.expectf(t, all_us < full_scan_us, "the segment filter must make line of sight cheaper (%.1f vs %.1f us)", all_us, full_scan_us)
		testing.expectf(t, frame_us < 1000, "nameplate visibility must stay well under a millisecond per frame (%.1f us)", frame_us)
	}

	@(test)
	nameplate_geometry_matches_krunker :: proc(t: ^testing.T) {
		player := shared.Player{position = {4, 2, -9}}
		testing.expect(t, player_nameplate_anchor(&player) == shared.Vec3{4, 13.6, -9}, "standing anchor is position.y + 11.6")
		player.crouch_val = 1
		testing.expect(t, abs(player_nameplate_anchor(&player).y - 10.6) < 1e-4, "full crouch lowers the anchor by 3")
		player.crouch_val = 0.5
		testing.expect(t, abs(player_nameplate_anchor(&player).y - 12.1) < 1e-4, "crouch drop is linear in crouch_val")

		origin := shared.Vec3{}
		testing.expect(t, player_nameplate_scale(origin, {0, 0, 0}) == 1, "full size at the camera")
		testing.expect(t, abs(player_nameplate_scale(origin, {0, 0, -300}) - 0.5) < 1e-5, "half size at 300 units")
		testing.expect(t, abs(player_nameplate_scale(origin, {0, 0, 420}) - 0.3) < 1e-5, "0.3 at 420 units")
		testing.expect(t, abs(player_nameplate_scale(origin, {0, 400, 1000}) - 0.3) < 1e-5, "never below 0.3, using 3D distance")

		screen := shared.Vec2{500, 300}
		bar := player_nameplate_layout(screen, 2, 40, true)
		testing.expect(t, bar.bar_width == 260 && bar.bar_height == 32, "bar is 130x16 canvas units")
		testing.expect(t, bar.bar_left == 370 && bar.bar_top + bar.bar_height == 300, "bar is centred on the anchor with its bottom edge on it")
		testing.expect(t, bar.name_x == bar.bar_left && bar.name_baseline == 300 - 26*2 && bar.name_size == 40,
			"name is 20px, left-aligned with the bar, baseline 10 units above the bar")
		name_only := player_nameplate_layout(screen, 2, 40, false)
		testing.expect(t, name_only.name_x == 500 - 40 && name_only.name_baseline == 300 - 16*2,
			"without a bar Krunker centres the name and uses a 6-unit plate height")
		long := player_nameplate_layout(screen, 1, 850, true)
		testing.expect(t, abs(long.name_size - 10) < 1e-4, "names wider than 425 units are fitted to 425")

		// Krunker projects with the world camera: NDC to canvas, y down.
		identity := shared.Mat4(1)
		projected, visible := player_healthbar_project(identity, {0.5, 0.5, 0}, 800, 600)
		testing.expect(t, visible && projected.x == 600 && projected.y == 150, "projection maps NDC to top-left screen pixels")
		_, inside := player_healthbar_project(identity, {1.5, 0, 0}, 800, 600)
		testing.expect(t, !inside, "anchors outside the frustum get no plate")
	}

	@(test)
	nameplate_names_come_from_the_live_roster :: proc(t: ^testing.T) {
		player := shared.Player{uid = 8}
		client := Client{}
		testing.expect(t, player_nameplate_name(&client, &player) == "Player 8", "native sessions fall back to Player N")
		client.krunker.connected = true
		append(&client.krunker_world.players, kproto.Krunker_World_Player{sid = 7, name = "Seven"}, kproto.Krunker_World_Player{sid = 8, name = "Eight"})
		defer delete(client.krunker_world.players)
		testing.expect(t, player_nameplate_name(&client, &player) == "Eight", "live sessions use the roster name for the player's SID")
		client.krunker_world.players[1].name = ""
		testing.expect(t, player_nameplate_name(&client, &player) == "Player 8", "an unnamed roster entry falls back like the scoreboard")
	}

	@(test)
	nameplate_hud_toggles_persist_and_default_on :: proc(t: ^testing.T) {
		defaults := client_settings_defaults()
		testing.expect(t, !defaults.hud.hide_nametags && !defaults.hud.hide_healthbars, "nametags and healthbars are on by default")
		path := "bin/client-settings-nameplates-test.json"
		defer os.remove(path)
		legacy := `{"version":1,"hud":{"hide_timer":true,"hide_round_score":false,"hide_game_score":false}}`
		testing.expect(t, os.write_entire_file(path, transmute([]u8)legacy) == nil)
		loaded := client_settings_load(path)
		testing.expect(t, loaded.hud.hide_timer && !loaded.hud.hide_nametags && !loaded.hud.hide_healthbars, "older settings files keep both shown")
		loaded.hud.hide_healthbars = true
		testing.expect(t, client_settings_save(loaded, path))
		again := client_settings_load(path)
		testing.expect(t, again.hud.hide_healthbars && !again.hud.hide_nametags, "the two toggles persist independently")

		state := menuui.State{settings_active = true}
		menuui.activate(&state, {action = {kind = .HUD_TOGGLE, index = 4}})
		testing.expect(t, state.settings_draft.hud.hide_nametags && !state.settings_draft.hud.hide_healthbars, "Show nametags toggles only nametags")
		menuui.activate(&state, {action = {kind = .HUD_TOGGLE, index = 5}})
		testing.expect(t, state.settings_draft.hud.hide_healthbars && state.settings_draft.hud.hide_nametags, "Show healthbars toggles only healthbars")
	}

	@(test)
	nameplates_render_names_and_bars_independently :: proc(t: ^testing.T) {
		if !testing.expect(t, bool(glfw.Init())) { return }
		defer glfw.Terminate()
		glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)
		glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 5)
		window := glfw.CreateWindow(1280, 720, "Nameplate regression", nil, nil)
		if !testing.expect(t, window != nil) { return }
		defer glfw.DestroyWindow(window)
		glfw.MakeContextCurrent(window)
		gl.load_up_to(4, 5, glfw.gl_set_proc_address)
		gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
		gl.Viewport(0, 0, 1280, 720)
		gl.ClearColor(0, 0, 0, 1)
		// FFA: every bar is the enemy colour and every name is white.
		local := shared.Player{active = true, is_you = true, uid = 1, position = {0, 0, -40}, height = 11, health = 100, max_health = 100}
		left := shared.Player{active = true, uid = 2, position = {-20, 0, -80}, height = 11, health = 100, max_health = 100}
		right := shared.Player{active = true, uid = 3, position = {20, 0, -80}, height = 11, health = 100, max_health = 100}
		client := Client{in_game = true, viewport_width = 1280, viewport_height = 720, me = &local}
		client.mouse_state.locked = true
		client.camera = camera_init(math.PI/2)
		client.camera.position = {0, 12.8, 0}
		client.scene, client.ui = scene_init(), ui_init()
		append(&client.game.players, &local, &left, &right)
		defer {
			delete(client.game.players)
			ui_fini(client.ui)
			scene_fini(client.scene)
			resource_cache_fini()
		}
		pixels := make([]u8, 1280*720*3, context.temp_allocator)

		both_red, _, both_white := nameplate_test_colors(&client, pixels)
		testing.expectf(t, both_red > 20 && both_white > 20, "both: bars and names render (%d red, %d white)", both_red, both_white)
		when #config(HUD_PREVIEW, false) {
			file := make([dynamic]u8)
			defer delete(file)
			append(&file, ..transmute([]u8)fmt.tprintf("P6\n%d %d\n255\n", 1280, 720))
			for row := 719; row >= 0; row -= 1 { append(&file, ..pixels[row*1280*3:(row+1)*1280*3]) }
			testing.expect(t, os.write_entire_file("bin/nameplates-preview.ppm", file[:]) == nil)
		}
		client.hud_settings.hide_nametags = true
		bar_red, _, bar_white := nameplate_test_colors(&client, pixels)
		testing.expect(t, bar_red == both_red && bar_white == 0, "bar only: names are hidden, bars untouched")
		client.hud_settings.hide_nametags, client.hud_settings.hide_healthbars = false, true
		name_red, _, name_white := nameplate_test_colors(&client, pixels)
		testing.expect(t, name_red == 0 && name_white > 20, "name only: bars are hidden, names still render")
		client.hud_settings.hide_nametags = true
		none_red, _, none_white := nameplate_test_colors(&client, pixels)
		testing.expect(t, none_red == 0 && none_white == 0, "neither: nothing is drawn")
		client.hud_settings = {}

		// Names follow the same line-of-sight gate as bars.
		wall := shared.Object{active = true, collision_type = .BOX, position = {-10, 0, -60}, scale = {2, 40, 12}}
		world := shared.Map{}
		append(&world.objects, &wall)
		defer delete(world.objects)
		client.game.map_inst = &world
		gated_red, _, gated_white := nameplate_test_colors(&client, pixels)
		testing.expectf(t, gated_red > 0 && gated_red < both_red && gated_white > 0 && gated_white < both_white,
			"a player behind a wall loses both the bar and the name; the visible one keeps both (%d/%d red, %d/%d white)", gated_red, both_red, gated_white, both_white)
		client.game.map_inst = nil

		// Names are an unclipped overlay too.
		material := basic_material_init()
		material.unlit, material.no_fog, material.color = true, true, {0, 0, 0, 1}
		cover := mesh_init(create_cube_geo(), &material.base)
		cover.transform.position, cover.transform.scale = {0, -100, -30}, {200, 200, 1}
		scene_add_mesh(client.scene, cover)
		defer mesh_fini(cover)
		covered_red, _, covered_white := nameplate_test_colors(&client, pixels)
		testing.expect(t, covered_red == both_red && covered_white == both_white, "geometry in front never clips names or bars")
		scene_remove_mesh(client.scene, cover)

		// Team modes: teammates' names white, enemies' names in the enemy colour.
		local.team, left.team, right.team = 1, 1, 2
		client.hud_settings.hide_healthbars = true
		team_red, team_green, team_white := nameplate_test_colors(&client, pixels)
		testing.expectf(t, team_red > 20 && team_white > 20 && team_green == 0, "enemy names use the enemy colour, teammate names stay white (%d red, %d white)", team_red, team_white)
		testing.expect(t, gl.GetError() == gl.NO_ERROR, "nameplate rendering must preserve valid OpenGL state")
	}
}
