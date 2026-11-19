package main

import "core:fmt"
import shared "../shared"

// Krunker's charge mechanics, as procInputs/shoot/melee run them:
// - Infiltrator's Charge Rifle (chrgTime 700, shootChrg, fullChrgSht,
//   rateChrg, chrgDec .8): plain shots are free and speed up as the charge
//   builds; at full charge the next shot is the blast, which uses the ammo.
// - Knife throws charge while aiming up to throwChrg; held past x1.2 they
//   overcharge (no charge until aim is released).
test_charge_mechanics :: proc() -> bool {
	config := shared.config_load_gameplay()
	defer shared.config_destroy_gameplay(config)
	map_inst := shared.Map{death_y = -1000, config = {speed = {1, 1, 1}, air_accel = 1}}
	game: shared.Game
	shared.game_configure(&game, &config.game, []^shared.Map{&map_inst}, nil, config.weapons, config.classes)
	shared.game_init(&game, 0, 0, true)
	defer shared.game_destroy(&game)
	player := shared.player_init(&game)
	shared.game_players_add(&game, player)
	shared.player_spawn(player, 15) // Infiltrator
	player.swap_timer_ms = 0
	if player.weapon == nil || player.weapon.charge_time != 700 || !player.weapon.full_charge_shot {
		fmt.eprintln("Infiltrator must carry Krunker's Charge Rifle (chrgTime 700, fullChrgSht)")
		return false
	}
	// Hold fire with 3 ms inputs for 690 ms: shots, no ammo used, cooldown shrinking.
	shots, first_gap, last_gap := 0, 0, 0
	since := 0
	for _ in 0 ..< 230 {
		before := player.shot_seq
		input := shared.Input{delta = 0.003, shoot = true}
		shared.player_proc_input(player, &input, true, false, true, true)
		since += 3
		if player.shot_seq != before {
			if shots == 1 { first_gap = since }
			last_gap = since
			since = 0
			shots += 1
		}
	}
	if shots < 4 || player.ammo[player.loadout_index] != 1 {
		fmt.eprintln("Charge Rifle plain shots must be free:", shots, "shots, ammo", player.ammo[player.loadout_index])
		return false
	}
	if !(last_gap < first_gap) {
		fmt.eprintln("rateChrg: the gap between shots must shrink as the charge builds:", first_gap, last_gap)
		return false
	}
	// Keep holding: full charge, then the blast uses the round.
	for _ in 0 ..< 120 {
		input := shared.Input{delta = 0.003, shoot = true}
		shared.player_proc_input(player, &input, true, false, true, true)
		if player.ammo[player.loadout_index] == 0 { break }
	}
	if player.ammo[player.loadout_index] != 0 || player.full_charge {
		fmt.eprintln("The full-charge blast must use the Charge Rifle's round and clear the charge")
		return false
	}

	// Knife: aim to charge the throw (Infiltrator throwChrg 800 ms).
	knife := -1
	for i in 0 ..< int(player.loadout_size) { if config.weapons[player.loadout[i]] != nil && config.weapons[player.loadout[i]].melee { knife = i } }
	if knife < 0 { fmt.eprintln("no knife in the loadout"); return false }
	shared.player_swap_weapon(player, i32(knife), false, false, false)
	player.swap_timer_ms = 0
	player.can_throw = true
	player.aim_val = 1
	for _ in 0 ..< 200 { // 600 ms
		input := shared.Input{delta = 0.003, scope = true}
		shared.player_proc_input(player, &input, true, false, true, true)
	}
	if abs(player.charge_progress - 0.75) > 0.01 || player.over_charged {
		fmt.eprintln("Throw charge after 600 of 800 ms must read 0.75, got", player.charge_progress)
		return false
	}
	// Past throwChrg the charge creeps (0.1*u/(160/(800*0.2)) = 0.1 ms per ms):
	// 960 ms needs about 1.6 s more.
	for _ in 0 ..< 800 {
		input := shared.Input{delta = 0.003, scope = true}
		shared.player_proc_input(player, &input, true, false, true, true)
		if player.over_charged { break }
	}
	if !player.over_charged || player.charge_progress != 0 {
		fmt.eprintln("Holding a throw past 1.2x throwChrg must overcharge it")
		return false
	}
	return true
}
