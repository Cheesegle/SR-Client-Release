package main

import "core:fmt"
import "core:math"
import "core:strings"
import shared "../shared"

// The inline hitbox maths player_shoot (2.0 / 1.6) and player_melee
// (2.2 / 1.8) used before shared.player_hitboxes, copied verbatim.
@(private="file")
legacy_hitboxes :: proc(target: ^shared.Player, body_width, head_width: f32) -> (body_origin, body_scale, head_origin, head_scale: shared.Vec3) {
	body_height := max(0.1, target.height * 0.72)
	body_origin = shared.Vec3{target.position.x, target.position.y, target.position.z}
	body_scale = shared.Vec3{target.scale * body_width, body_height, target.scale * body_width}
	head_height := max(0.1, target.height - body_height)
	head_origin = shared.Vec3{target.position.x, target.position.y + body_height, target.position.z}
	head_scale = shared.Vec3{target.scale * head_width, head_height, target.scale * head_width}
	return
}

test_player_hitboxes_match_inline :: proc() -> bool {
	player: shared.Player
	positions := [?]shared.Vec3{{0, 0, 0}, {12.5, -3.25, 400.125}, {-1234.5, 87.75, 0.3}}
	scales := [?]f32{shared.GAME_CONSTANTS.player_scale, 1, 3.3}
	crouches := [?]f32{0, 0.25, 0.5, 0.999, 1}
	heights := [?]f32{0.05, 0.12, 0.2, 30} // Tiny heights hit both max(0.1, ...) clamps.
	checked := 0
	check :: proc(player: ^shared.Player, checked: ^int) -> bool {
		for kind in shared.Hitbox_Kind {
			bw, hw: f32 = 2.0, 1.6
			if kind == .MELEE { bw, hw = 2.2, 1.8 }
			bo, bs, ho, hs := legacy_hitboxes(player, bw, hw)
			body, head := shared.player_hitboxes(player, kind)
			if body.origin != bo || body.scale != bs || head.origin != ho || head.scale != hs {
				fmt.printf("player_hitboxes mismatch (%v, height %v, scale %v): body %v/%v vs %v/%v, head %v/%v vs %v/%v\n",
					kind, player.height, player.scale, body.origin, body.scale, bo, bs, head.origin, head.scale, ho, hs)
				return false
			}
			checked^ += 1
		}
		return true
	}
	for position in positions {
		for scale in scales {
			player.position, player.scale = position, scale
			for crouch in crouches {
				player.crouch_val = crouch
				shared.player_update_height(&player)
				if !check(&player, &checked) { return false }
			}
			for height in heights {
				player.height = height
				if !check(&player, &checked) { return false }
			}
		}
	}
	fmt.printf("player_hitboxes matches the old inline maths exactly (%d cases) OK\n", checked)
	return true
}

// Both native shot paths must test exactly player_hitboxes: a target whose side
// sits between the shot box (2.0 * scale wide) and the melee box (2.2 * scale)
// is missed by shots and hit by melee, and every shot that hits a player ends
// on the surface of a player_hitboxes box.
test_shot_paths_use_player_hitboxes :: proc() -> bool {
	map_inst := shared.Map{death_y = -100}
	game := shared.Game{}
	maps := []^shared.Map{&map_inst}
	shared.game_configure(&game, nil, maps, nil, nil, nil)
	shared.game_init(&game, 0, 0, true)
	defer shared.game_destroy(&game)

	shooter := shared.player_init(&game)
	shared.game_players_add(&game, shooter)
	shared.player_spawn(shooter)
	target := shared.player_init(&game)
	shared.game_players_add(&game, target)
	shared.player_spawn(target)

	setup :: proc(shooter, target: ^shared.Player, side_offset: f32) {
		shooter.position, shooter.direction = {0, 0, 0}, {0, -math.PI / 2.0} // Facing +x.
		shooter.spread, shooter.recoil_anim_y = 0, 0
		shooter.swap_timer = 0
		target.position = {10, 4, side_offset} // Eye height (9.5) crosses the body box.
		target.health = f32(target.max_health)
		target.active = true
	}

	// Edge offsets between the two widths (target.scale = 2.45: shot half
	// width 2.45, melee half width 2.695).
	half_shot := target.scale * 1.0
	half_melee := target.scale * 1.1
	between := (half_shot + half_melee) * 0.5
	inside := half_shot * 0.9
	outside := half_melee * 1.05

	// Hitscan: find a hitscan slot and fire unspread rays.
	hitscan_slot := -1
	melee_slot := -1
	for i in 0 ..< int(shooter.loadout_size) {
		weapon := game.weapons[shooter.loadout[i]]
		if weapon.melee { melee_slot = i } else if !weapon.projectile && len(weapon.custom_spread) == 0 && hitscan_slot < 0 { hitscan_slot = i }
	}
	if hitscan_slot < 0 || melee_slot < 0 {
		fmt.println("Shot path hitbox test: default loadout lacks a hitscan or melee weapon")
		return false
	}

	shoot :: proc(game: ^shared.Game, shooter, target: ^shared.Player, slot: int, offset: f32) -> (hit_player: bool, ok: bool) {
		setup(shooter, target, offset)
		shooter.loadout_index = i32(slot)
		shooter.weapon = game.weapons[shooter.loadout[slot]]
		saved_inaccuracy := shooter.weapon.inaccuracy
		shooter.weapon.inaccuracy = 0
		defer shooter.weapon.inaccuracy = saved_inaccuracy
		shooter.ammo[slot] = max(shooter.ammo[slot], 1)
		clear(&game.impacts)
		health := target.health
		shared.player_shoot(shooter)
		if len(game.impacts) == 0 { return false, false }
		ok = true
		for impact in game.impacts {
			if impact.kind != .Player { continue }
			hit_player = true
			// The impact must sit on a player_hitboxes box.
			body, head := shared.player_hitboxes(target, .SHOT)
			ray := impact.position - impact.origin
			bt, _, bh := shared.ray_box_hit(impact.origin, ray * 2, body.origin, body.scale)
			ht, _, hh := shared.ray_box_hit(impact.origin, ray * 2, head.origin, head.scale)
			on_box := (bh && abs(bt - 0.5) < 1e-4) || (hh && abs(ht - 0.5) < 1e-4)
			if !on_box {
				fmt.printf("Shot impact %v is not on a player_hitboxes box (body t=%v hit=%v, head t=%v hit=%v)\n", impact.position, bt, bh, ht, hh)
				ok = false
			}
		}
		if hit_player && target.health >= health { ok = false }
		return
	}

	melee :: proc(game: ^shared.Game, shooter, target: ^shared.Player, slot: int, offset: f32) -> bool {
		setup(shooter, target, offset)
		shooter.loadout_index = i32(slot)
		shooter.weapon = game.weapons[shooter.loadout[slot]]
		shooter.can_throw = false
		health := target.health
		shared.player_melee(shooter)
		return target.health < health
	}

	shot_inside, ok1 := shoot(&game, shooter, target, hitscan_slot, inside)
	shot_between, ok2 := shoot(&game, shooter, target, hitscan_slot, between)
	melee_inside := melee(&game, shooter, target, melee_slot, inside)
	melee_between := melee(&game, shooter, target, melee_slot, between)
	melee_outside := melee(&game, shooter, target, melee_slot, outside)
	if !ok1 || !ok2 || !shot_inside || shot_between || !melee_inside || !melee_between || melee_outside {
		fmt.printf("Shot path hitbox test failed: shot inside=%v (%v) between=%v (%v); melee inside=%v between=%v outside=%v\n",
			shot_inside, ok1, shot_between, ok2, melee_inside, melee_between, melee_outside)
		return false
	}

	// And neither path keeps its own copy of the box maths.
	source, read_ok := shared.read_file(fmt.tprintf("%ssrc/shared/player.odin", project_root()))
	if !read_ok {
		fmt.println("Shot path hitbox test: cannot read src/shared/player.odin")
		return false
	}
	defer delete(source)
	text := string(source)
	if strings.count(text, "player_hitboxes(target, .SHOT)") != 1 || strings.count(text, "player_hitboxes(target, .MELEE)") != 1 ||
		strings.contains(text, "target.height * 0.72") || strings.count(text, "!map_object_blocks_shots(object)") != 2 {
		fmt.println("Shot path hitbox test: player_shoot/player_melee must use player_hitboxes and map_object_blocks_shots")
		return false
	}
	fmt.println("Both shot paths test player_hitboxes (shot/melee edges, impact surfaces) OK")
	return true
}
