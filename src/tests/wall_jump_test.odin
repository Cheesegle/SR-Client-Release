package main

import "core:fmt"
import "core:math"
import shared "../shared"

wall_jump_place :: proc(player: ^shared.Player, face: int = 0, class: i32 = 2) {
	shared.player_spawn(player, class)
	player.on_ground = false
	player.position = {0, 20, 0}
	distance := 10 + player.scale
	switch face {
	case 0: player.position.x = distance
	case 1: player.position.x = -distance
	case 2: player.position.z = distance
	case 3: player.position.z = -distance
	}
	player.last_position = player.position
}

test_wall_jump :: proc() -> bool {
	map_inst := shared.Map{death_y = -100, config = shared.Map_Config{speed = {1, 1, 1}, air_accel = 1}}
	wall := shared.Object{active = true, collision_type = .BOX, scale = {20, 100, 20}, wall_jumpable = true}
	append(&map_inst.objects, &wall)
	defer delete(map_inst.objects)
	game := shared.Game{}
	player := physics_game_init(&game, &map_inst, true)
	defer shared.game_destroy(&game)

	// Exercise real spawns, including switching back from an eligible class.
	for class, i in shared.CLASSES_LIST {
		shared.player_spawn(player, i32(i))
		if player.wall_jump != class.wall_jump {
			fmt.printf("Wall-jump class wiring failed: %s\n", class.name)
			return false
		}
	}
	configured := shared.CLASSES_LIST[0]
	configured.wall_jump = true
	game.classes = []shared.Class_Config{configured}
	shared.player_spawn(player, 0)
	if !player.wall_jump { return false }
	game.classes = shared.CLASSES_LIST[:]

	press := shared.Input{delta = PHYSICS_DT, move_dir = -1, jump = true}
	release := press
	release.jump = false
	normals := [4]shared.Vec3{{1, 0, 0}, {-1, 0, 0}, {0, 0, 1}, {0, 0, -1}}
	for normal, face in normals {
		wall_jump_place(player, face)
		shared.player_proc_input(player, &press, true, false)
		expected := normal * 0.03 + shared.Vec3{0, 0.058, 0}
		if player.velocity != expected || !player.did_wall_jump || player.on_wall != 0 || player.on_ground {
			fmt.printf("Wall-jump face %d failed: velocity=%v\n", face + 1, player.velocity)
			return false
		}
	}

	// Holding the ground jump must not automatically trigger a wall jump.
	wall_jump_place(player)
	player.did_wall_jump = true
	shared.player_proc_input(player, &press, true, false)
	if player.velocity.y > 0 || player.velocity.x != 0 { return false }
	shared.player_proc_input(player, &release, true, false)
	shared.player_proc_input(player, &press, true, false)
	if math.abs(player.velocity.y - 0.058) > EPSILON || player.velocity.x != 0.03 {
		fmt.eprintln("Wall-jump release/repress failed")
		return false
	}

	// Separate gates: class, server option, map surface, ladder, cylinder,
	// missing contact, and movement lock must all prevent the impulse.
	for gate in 0 ..< 7 {
		wall_jump_place(player, 0, gate == 0 ? 0 : 2)
		game.config.wall_jump = gate == 1 ? 0 : 1
		wall.wall_jumpable = gate != 2
		wall.ladder = gate == 3
		wall.collision_type = gate == 4 ? .CYLINDER : .BOX
		if gate == 5 { player.position.x += 10 }
		shared.player_proc_input(player, &press, true, gate == 6)
		if player.did_wall_jump || player.velocity.y > 0 {
			fmt.printf("Wall-jump gate %d failed\n", gate)
			return false
		}
	}
	wall.ladder = false
	wall.collision_type = .BOX
	wall.wall_jumpable = true
	game.config.wall_jump = 2
	game.mode.config.real_movement = true
	wall_jump_place(player)
	shared.player_proc_input(player, &press, true, false)
	if math.abs(player.velocity.x - 0.042) > EPSILON || math.abs(player.velocity.y - 0.0522) > EPSILON {
		fmt.eprintln("Wall-jump configured impulse failed")
		return false
	}
	game.config.wall_jump = 1
	game.mode.config.real_movement = false

	// Crouching while falling against a wall reduces gravity to 30%.
	wall_jump_place(player)
	player.on_wall = 1
	player.crouch_val = 1
	player.velocity.y = -0.01
	fall := release
	fall.crouch = true
	shared.player_proc_input(player, &fall, true, false)
	if math.abs(player.velocity.y - (-0.01 - PHYSICS_DT * shared.GAME_CONSTANTS.gravity * 0.3)) > 0.000001 {
		fmt.eprintln("Wall slide gravity failed")
		return false
	}

	// Authoritative ticks and client prediction must agree over a complete
	// contact/release/jump/flight sequence, with no manually enabled ability.
	other := shared.player_init(&game)
	shared.game_players_add(&game, other)
	wall_jump_place(player)
	wall_jump_place(other)
	player.did_wall_jump = true
	other.did_wall_jump = true
	for tick in 0 ..< 80 {
		input := press
		input.jump = tick != 1
		shared.player_queue_input(player, &input)
		shared.player_update(player, PHYSICS_DT)
		shared.player_proc_input(other, &input, true, false)
		if player.position != other.position || player.velocity != other.velocity || player.did_wall_jump != other.did_wall_jump || player.on_wall != other.on_wall {
			fmt.printf("Wall-jump prediction parity failed at tick %d\n", tick)
			return false
		}
	}
	fmt.println("Wall-jump class/contact/input/prediction tests OK")
	return true
}

test_movement_animation :: proc() -> bool {
	map_inst := shared.Map{death_y = -100, config = shared.Map_Config{speed = {1, 1, 1}, air_accel = 1}}
	wall := shared.Object{active = true, collision_type = .BOX, scale = {20, 100, 20}, wall_jumpable = true}
	append(&map_inst.objects, &wall)
	defer delete(map_inst.objects)
	game := shared.Game{}
	player := physics_game_init(&game, &map_inst, true)
	defer shared.game_destroy(&game)
	press := shared.Input{delta = PHYSICS_DT, move_dir = -1, jump = true}

	// New predicted inputs produce feedback; snapshot replays must not
	// restart it. Test offline too, through the same movement entry point.
	for path in 0 ..< 3 {
		wall_jump_place(player)
		player.render_you = true
		shared.player_proc_input(player, &press, path != 0, false, path == 1)
		if player.jump_bob_tween.active != (path != 2) { return false }
		if path == 2 { continue }
		shared.player_update_visual_animations(player, 0.05)
		if player.jump_bob_y <= 0 || player.jump_rotate <= 0 { return false }
		shared.player_update_visual_animations(player, 0.85)
		if math.abs(player.jump_bob_y - 0.26) > EPSILON || math.abs(player.jump_rotate) > EPSILON { return false }
	}

	// A real landing must reset the airborne offset even with sliding off.
	wall_jump_place(player)
	player.render_you = true
	shared.player_animate_jump(player, true)
	shared.player_update_visual_animations(player, 0.5)
	game.config.can_slide = false
	player.position = {0, 100.1, 0}
	player.velocity = {0, -0.02, 0}
	land := shared.Input{delta = PHYSICS_DT, move_dir = -1}
	shared.player_proc_input(player, &land, true, false, true)
	if !player.on_ground || !player.land_tween.active { return false }
	shared.player_update_visual_animations(player, 0.1)
	if player.land_bob_y >= 0 || math.abs(player.jump_bob_y) > EPSILON { return false }
	shared.player_update_visual_animations(player, 1.1)
	if math.abs(player.land_bob_y) > EPSILON { return false }

	// Respawn clears effects; ordinary ground jumps also drive the rig.
	shared.player_spawn(player, 2)
	if player.jump_bob_y != 0 || player.jump_rotate != 0 || player.land_bob_y != 0 || player.land_tween.active { return false }
	player.position = {0, 100, 0}
	shared.player_proc_input(player, &press, false, false)
	shared.player_update_visual_animations(player, 0.5)
	if math.abs(player.jump_bob_y - 0.22) > EPSILON { return false }
	fmt.println("Movement animation prediction/landing/respawn tests OK")
	return true
}

// Krunker caps wall jumps per airtime with the class's wallJM ("Walljumps
// Max"): Run N Gun 2, Agent/Trooper 3, Runner/Survivor 100. The count resets
// on landing.
test_wall_jump_limit :: proc() -> bool {
	map_inst := shared.Map{death_y = -100, config = shared.Map_Config{speed = {1, 1, 1}, air_accel = 1}}
	wall := shared.Object{active = true, collision_type = .BOX, scale = {20, 100, 20}, wall_jumpable = true}
	append(&map_inst.objects, &wall)
	defer delete(map_inst.objects)
	game := shared.Game{}
	player := physics_game_init(&game, &map_inst, true)
	defer shared.game_destroy(&game)
	game.config.wall_jump = 1

	press := shared.Input{delta = PHYSICS_DT, move_dir = -1, jump = true}
	release := press
	release.jump = false
	// Back beside the wall in the air, keeping this airtime's count.
	reattach :: proc(player: ^shared.Player) {
		player.on_ground = false
		player.position = {10 + player.scale, 20, 0}
		player.last_position = player.position
		player.velocity = {}
	}
	attempt :: proc(player: ^shared.Player, press, release: ^shared.Input) -> bool {
		reattach(player)
		shared.player_proc_input(player, release, true, false)
		reattach(player)
		shared.player_proc_input(player, press, true, false)
		return player.velocity.y > 0.05
	}

	for class, index in shared.CLASSES_LIST {
		if !class.wall_jump { continue }
		limit := int(class.wall_jump_max)
		wall_jump_place(player, 0, i32(index))
		if player.wall_jump_max != i32(limit) {
			fmt.printf("Wall-jump limit wiring failed for %s: %d != %d\n", class.name, player.wall_jump_max, limit)
			return false
		}
		tries := min(limit, 12) // Runner/Survivor allow 100; a dozen proves no early cap.
		for n in 0 ..< tries {
			if !attempt(player, &press, &release) {
				fmt.printf("%s: wall jump %d of %d was refused\n", class.name, n + 1, limit)
				return false
			}
		}
		if limit <= 12 && attempt(player, &press, &release) {
			fmt.printf("%s: wall jump %d exceeded the limit of %d\n", class.name, limit + 1, limit)
			return false
		}
		// Landing resets the count (Krunker resetStep).
		player.position = {0, 100.5, 0}
		player.last_position = player.position
		player.velocity = {}
		for _ in 0 ..< 8 { shared.player_proc_input(player, &release, true, false) }
		if !player.on_ground || player.wall_jump_count != 0 {
			fmt.printf("%s: landing did not reset the wall-jump count (grounded=%v count=%d)\n", class.name, player.on_ground, player.wall_jump_count)
			return false
		}
		if !attempt(player, &press, &release) {
			fmt.printf("%s: wall jump after landing was refused\n", class.name)
			return false
		}
	}

	// A class with a zero limit can never wall jump, even with the flag set.
	configured := shared.CLASSES_LIST[0]
	configured.wall_jump, configured.wall_jump_max = true, 0
	game.classes = []shared.Class_Config{configured}
	wall_jump_place(player, 0, 0)
	if attempt(player, &press, &release) {
		fmt.eprintln("A zero wall-jump limit still allowed a wall jump")
		return false
	}
	game.classes = shared.CLASSES_LIST[:]
	fmt.println("Wall-jump limits (Run N Gun 2, Agent/Trooper 3, Runner/Survivor 100) and landing reset OK")
	return true
}
