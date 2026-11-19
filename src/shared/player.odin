package shared

import "core:math"
import "core:math/rand"

// SR_TEST_SPAWN (tests only): offline games always use this spawn; -1 = off.
g_test_spawn := -1

player_init :: proc(game: ^Game) -> ^Player {
	player := new(Player)
	player.game = game
	player.slid_cont = 1
	player.scale = GAME_CONSTANTS.player_scale
	player.secondary_id = 2
	player.class_slide_time, player.class_slide_accel = 1, 1
	player.throw_charge_ms, player.melee_rate = 900, 1
	return player
}

player_update_height :: proc(player: ^Player) {
	player.height_old = player.height // Krunker's updateHeight: heightOld = height first
	player.height = GAME_CONSTANTS.player_height - player.crouch_val * GAME_CONSTANTS.crouch_distance
}

// Invalid/unsupported choices fall back to the default pistol.
secondary_weapon_id :: proc(weapons: []^Weapon, requested: i32) -> i32 {
	if requested >= 0 && int(requested) < len(weapons) && weapons[requested] != nil && weapons[requested].secondary && !weapons[requested].melee { return requested }
	return 2
}

player_spawn :: proc(player: ^Player, class_index: i32 = 0, secondary_id: i32 = -1) {
	player.active = true
	player.frozen, player.speed_boost = false, 0
	player.class_index = class_index
	player.respawn_timer = 0
	player.last_damage_time = -1000

	if player.team == 0 && player.game != nil && player.game.mode != nil && player.game.mode.config.teams {
		team_counts: [3]i32
		for other in player.game.players {
			if other != player && other.team > 0 && other.team < len(team_counts) {
				team_counts[other.team] += 1
			}
		}
		player.team = team_counts[1] <= team_counts[2] ? 1 : 2
	}

	// Resolve stats from the configured classes when available (the game's list
	// is built from the class JSON plus optional TOML overrides), falling back
	// to the same JSON-derived defaults.
	class: Class_Config
	if player.game != nil && class_index >= 0 && class_index < i32(len(player.game.classes)) {
		class = player.game.classes[class_index]
	} else if class_index >= 0 && class_index < i32(len(CLASSES_LIST)) {
		class = CLASSES_LIST[class_index]
	} else {
		class = CLASSES_LIST[0]
	}

	player.speed = class.speed
	player.wall_jump = class.wall_jump
	player.wall_jump_max = i32(max(class.wall_jump_max, 0))
	player.wall_jump_count = 0
	// Krunker resetStep: slideTimer *= (h.config.slT||1), velocity *= h.config.slA.
	// Every stock class sets slA (Spray N Pray .98, others 1); 0 means unset.
	player.class_slide_time = class.slide_time != 0 ? class.slide_time : 1
	player.class_slide_accel = class.slide_accel != 0 ? class.slide_accel : 1
	// Krunker: throwCharge = config.throwChrg || 900; melee cooldown x melRate.
	player.throw_charge_ms = class.throw_charge > 0 ? f64(class.throw_charge) : 900
	player.melee_rate = class.melee_rate > 0 ? class.melee_rate : 1
	player.charge_time_ms, player.full_charge, player.over_charged, player.charge_progress = 0, false, false, 0
	player.health = f32(class.health)
	player.max_health = class.health

	weapons := player.game.weapons if player.game != nil && len(player.game.weapons) > 0 else g_weapons()
	player.secondary_id = secondary_weapon_id(weapons, secondary_id >= 0 ? secondary_id : player.secondary_id)

	// Build the full loadout: the class's configured primary weapons, plus the
	// sidearm (when the class has one) and the melee knife. The C port shipped a
	// fixed [primary, pistol, knife] loadout; deriving it from the class keeps
	// weapon switching (Q/E) working for every class.
	composed: [dynamic]i32
	defer delete(composed)

	for weapon_id in class.loadout {
		if weapon_id >= 0 && weapon_id < i32(len(weapons)) && weapons[weapon_id] != nil {
			append(&composed, weapon_id)
		}
	}

	has_secondary := false
	has_melee := false
	for weapon_id in composed {
		if weapon_id >= 0 && int(weapon_id) < len(weapons) && weapons[weapon_id] != nil {
			if weapons[weapon_id].secondary {
				has_secondary = true
			}
			if weapons[weapon_id].melee {
				has_melee = true
			}
		}
	}

	if class.secondary && !has_secondary && (player.game == nil || !player.game.config.no_secondaries) {
		if int(player.secondary_id) < len(weapons) && weapons[player.secondary_id] != nil {
			append(&composed, player.secondary_id)
		}
	}

	if !has_melee {
		// Combat Knife is the default melee (index 12 in the weapon registry).
		if 12 < len(weapons) && weapons[12] != nil {
			append(&composed, 12)
		}
	}

	delete(player.loadout)
	delete(player.ammo)
	delete(player.reloads_ms)
	clear(&player.input_queue)

	player.loadout_size = i32(len(composed))
	player.loadout = make([]i32, player.loadout_size)
	player.ammo = make([]u32, player.loadout_size)
	player.reloads_ms = make([]f64, player.loadout_size)
	copy(player.loadout, composed[:])

	if player.game != nil && player.game.map_inst != nil {
		for i in 0 ..< player.loadout_size {
			player.ammo[i] = weapons[player.loadout[i]].ammo
		}
	}

	player.velocity = Vec3{0, 0, 0}
	player.crouch_val = 0.0
	player.aim_val = 0.0
	player.spread_plus = 0
	player.projectile_shot_seq = 0
	player.recoil = {}
	player.inspecting = false
	player.recoil_force = 0.0
	player.recoil_anim = 0.0
	player.recoil_anim_y = 0.0
	player.view_kick = {}
	player.view_kick_phase = 0
	player.melee_pose = {}
	player.melee_phase = 0
	player_reset_movement_animation(player)

	player.on_ground = true
	player.on_wall = 0
	player.on_terrain = false
	player.on_ladder = false

	player.can_slide = true
	player.can_throw = true

	player.did_jump = false
	player.did_wall_jump = false
	player.did_act = false

	player.air_time = 0.0
	player.covered_distance = 0.0
	player.aim_time = 0.0

	player.swap_timer_ms = 0.0
	player.slide_timer = 0.0
	player.can_slide_timer = 0.0
	player.jump_timer = 0.0
	player.reload_timer_ms = 0.0

	player_update_height(player)
	player_swap_weapon(player, 0, true, false, false)
	player_update_spread(player, 0, 0, 0)

	if player.game != nil && player.game.map_inst != nil && len(player.game.map_inst.spawns) > 0 {
		eligible: [dynamic]^Spawn
		defer delete(eligible)
		for spawn in player.game.map_inst.spawns {
			if player.team != 0 && spawn.team != 0 && spawn.team != player.team {
				continue
			}
			occupied := false
			if player.game.players != nil {
				for other in player.game.players {
					if other != nil && other != player && other.active {
						dx := other.position.x - spawn.position.x
						dz := other.position.z - spawn.position.z
						if dx * dx + dz * dz < 100.0 {
							occupied = true
							break
						}
					}
				}
			}
			if !occupied {
				append(&eligible, spawn)
			}
		}
		spawn := player.game.map_inst.spawns[rand.int_max(len(player.game.map_inst.spawns))]
		if len(eligible) > 0 {
			spawn = eligible[rand.int_max(len(eligible))]
		}
		// Performance and delay tests (SR_TEST_SPAWN=<n> at launch, off
		// otherwise): always the same spawn, so every run sees the same view.
		if g_test_spawn >= 0 { spawn = player.game.map_inst.spawns[g_test_spawn % len(player.game.map_inst.spawns)] }

		player.position = spawn.position
		player.direction.x = 0.0
		player.direction.y = -math.PI / 2.0 * (1.0 + f32(spawn.direction))
	}
}

player_kill :: proc(player: ^Player, killer: ^Player, kill_info: ^Player_Kill_Info, skip_rewards: bool) {
	if !player.active {
		return
	}

	player.active = false
	player.health = 0
	player.velocity = {}
	player.deaths += 1
	player.death_streak += 1
	clear(&player.input_queue)
	if player.game != nil {
		player.respawn_timer = max(0.0, player.game.config.respawn_delay)
	}

	if player.game != nil {
		event := Kill_Event{victim_uid = player.uid, killer_uid = -1, weapon_id = -1}
		if killer != nil { event.killer_uid = killer.uid }
		if kill_info != nil { event.weapon_id, event.headshot = kill_info.weapon_id, kill_info.headshot }
		game_push_kill_event(player.game, event)
	}

	if killer != nil && killer != player {
		killer.kills += 1
		killer.death_streak = 0
		if !skip_rewards && killer.game != nil && killer.game.config.kill_rewards {
			killer.score += 100
		}
	}
}

player_apply_damage :: proc(victim, attacker: ^Player, amount: f32, weapon_id: i32, headshot: bool) -> bool {
	if victim == nil || !victim.active || victim.god_mode || amount <= 0 {
		return false
	}
	if attacker != nil && attacker != victim && victim.team != 0 && victim.team == attacker.team && !victim.game.mode.config.dmg_team {
		return false
	}

	final_damage := amount
	if attacker != nil && attacker.team == 1 {
		final_damage *= victim.game.config.team1_damage
	} else if attacker != nil && attacker.team == 2 {
		final_damage *= victim.game.config.team2_damage
	}

	previous_health := victim.health
	victim.health = max(0.0, victim.health - final_damage)
	if victim.health < previous_health {
		player_emit_presentation(victim, .DAMAGE, attacker != victim ? attacker : nil)
		if attacker != nil && attacker != victim {
			game_emit_presentation(victim.game, {kind = .HIT, uid = attacker.uid, headshot = headshot, lethal = victim.health == 0})
		}
	}
	victim.last_damage_time = victim.game.now
	if victim.health == 0 {
		info := Player_Kill_Info{weapon_id = weapon_id, headshot = headshot}
		player_kill(victim, attacker, &info, false)
	}
	return true
}

player_queue_input :: proc(player: ^Player, input: ^Input) {
	append(&player.input_queue, input^)
}

player_reset_step :: proc(player: ^Player, recon: bool) {
	if player.velocity.y != 0 { player.land_velocity = player.velocity.y }
	if !recon && player.render_you && player.velocity.y != 0 {
		player_animate_land(player)
	}

	if !player.game.config.can_slide || player.game.mode.config.real_movement || player.crouch_val == 0 || !player.can_slide || player.can_slide_timer > 0 {
		return
	}

	player.can_slide = false
	player.can_slide_timer = 0.1

	player.slide_timer = GAME_CONSTANTS.slide_time *
		player.game.config.slide_time *
		player.game.map_inst.config.slide_time *
		player.class_slide_time *
		player.crouch_val

	slide_mlt := (player.on_terrain ? GAME_CONSTANTS.player_terrain_slide_velocity_mlt : GAME_CONSTANTS.player_slide_velocity_mlt) * player.game.map_inst.config.slide_accel * player.class_slide_accel * player.game.config.slide_speed

	player.velocity.x *= slide_mlt
	player.velocity.z *= slide_mlt
}

player_collides :: proc(player: ^Player, object: ^Object, pad: f32) -> bool {
	switch object.collision_type {
	case .NONE:
		return false
	case .BOX:
		border := 0.0 if (player.game.config.disable_borders || !object.is_border) else GAME_CONSTANTS.border_height

		in_x := player.position.x + player.scale > object.position.x - (object.scale.x * 0.5 + pad) && player.position.x - player.scale < object.position.x + (object.scale.x * 0.5 + pad)
		in_z := player.position.z + player.scale > object.position.z - (object.scale.z * 0.5 + pad) && player.position.z - player.scale < object.position.z + (object.scale.z * 0.5 + pad)
		in_y := player.position.y + player.height >= object.position.y && player.position.y <= object.position.y + object.scale.y + border

		return in_x && in_y && in_z
	case .CYLINDER:
		border := 0.0 if (player.game.config.disable_borders || !object.is_border) else GAME_CONSTANTS.border_height

		in_y := player.position.y + player.height > object.position.y && player.position.y < object.position.y + object.scale.y + border
		dist := math.sqrt((player.position.x - object.position.x) * (player.position.x - object.position.x) + (player.position.z - object.position.z) * (player.position.z - object.position.z))

		return in_y && dist <= object.scale.x * 0.5 + player.scale + pad
	}

	return false
}

player_do_map_collisions :: proc(player: ^Player, input: ^Input, move_dir: f32, can_jump: bool, delta: f32, recon: bool) {
	max_ramp_height: f32
	has_max_ramp_height: bool

	// Loaded maps list the objects a player can touch, in map order, so
	// order-dependent resolution is unchanged. Hand-built maps scan everything.
	map_inst := player.game.map_inst
	count := map_inst.collision_indexed ? len(map_inst.collision_objects) : len(map_inst.objects)
	for i in 0 ..< count {
		obj := map_inst.objects[map_inst.collision_indexed ? int(map_inst.collision_objects[i]) : i]

		if !obj.active || !player_collides(player, obj, GAME_CONSTANTS.collision_padding) {
			continue
		}

		collides := player_collides(player, obj, 0.0)

		if obj.jump_pad {
			bounce_vel := obj.bounce * 0.1 * (player.crouch_val == 1.0 && obj.crouch ? 0.5 : 1.0)

			player.velocity.y = bounce_vel
			player.on_ground = false
		} else if obj.score_zone {
			// TODO: score
		} else if !obj.objective && !obj.bomb_site && !obj.premium && !obj.verified && (!obj.team_zone || player.game.mode.config.teams && obj.team != u32(player.team)) {
			if obj.teleporter {
				continue
			}

			if obj.checkpoint {
				continue
			}

			if obj.pickup {
				continue
			}

			if obj.flag {
				continue
			}

			if obj.trigger {
				continue
			}

			if obj.kill && !player.god_mode {
				player_kill(player, nil, nil, false)
				continue
			}

			if obj.ladder {
				if player.position.y >= obj.position.y + obj.scale.y || player.crouch_val != 0 {
					continue
				}

				player.velocity.y = 0.0
				player.on_ladder = true
				player.on_terrain = false

				if input.move_dir >= 0 {
					ladder_dir := math.PI * 0.5 * f32(obj.direction)
					dir := (math.abs(normalize_angle(ladder_dir - (move_dir - player.direction.y))) - math.PI * 0.5) / (math.PI * 0.5)

					if dir > 0.0 {
						player.position.y += GAME_CONSTANTS.ladder_speed * player.game.map_inst.config.ladder_accel * player.weapon.speed_mlt * dir * delta
						player.position.y = clamp(player.position.y, obj.position.y, obj.position.y + obj.scale.y)
					}
				}

				continue
			}

			if obj.ramp == nil && obj.collision_type != .CYLINDER && !can_jump && obj.position.y + obj.scale.y - player.position.y > GAME_CONSTANTS.climb_height && obj.wall_jumpable {
				if player.last_position.x - player.scale >= obj.position.x + obj.scale.x * 0.5 - GAME_CONSTANTS.collision_padding {
					player.on_wall = 1
				} else if player.last_position.x + player.scale <= obj.position.x - obj.scale.x * 0.5 + GAME_CONSTANTS.collision_padding {
					player.on_wall = 2
				} else if player.last_position.z - player.scale >= obj.position.z + obj.scale.z * 0.5 - GAME_CONSTANTS.collision_padding {
					player.on_wall = 3
				} else if player.last_position.z + player.scale <= obj.position.z - obj.scale.z * 0.5 + GAME_CONSTANTS.collision_padding {
					player.on_wall = 4
				}
			}

			if !collides {
				continue
			}

			if obj.ramp != nil {
				if player.position.y >= obj.position.y + obj.scale.y {
					continue
				}

				ramp_direction := math.PI * 0.5 * f32(obj.direction)
				player_dir := Vec2{player.position.x + player.scale * math.cos(ramp_direction), player.position.z + player.scale * math.sin(ramp_direction)}

				progress := clamp(progress_on_line(obj.ramp.start, obj.ramp.end, player_dir), 0.0, 1.0)
				collision_height := obj.position.y + (obj.scale.y + 0.01) * progress
				// Krunker: (config.rampFix || map.rampFix) && height - oldY > 3 &&
				// oldY - bottom < 3 && blockRampSide(obj) skips the ramp.
				if (player.game.config.ramp_fix || map_inst.ramp_fix) && collision_height - player.last_position.y > GAME_CONSTANTS.climb_height && player.last_position.y - obj.position.y < GAME_CONSTANTS.climb_height && player_block_ramp_side(player, obj) {
					continue
				}

				if !has_max_ramp_height {
					has_max_ramp_height = true
					max_ramp_height = collision_height
				}

				if (player.position.y <= collision_height || can_jump) && (!has_max_ramp_height || max_ramp_height <= collision_height) {
					if has_max_ramp_height {
						max_ramp_height = collision_height
					}

					if obj.ramp.boost != 0 {
						player.position.y = collision_height

						boost_velocity := obj.ramp.boost * GAME_CONSTANTS.booster_speed * delta
						boost_direction := math.asin(obj.scale.y / math.sqrt(obj.scale.y * obj.scale.y + obj.scale.z * obj.scale.z))

						player.velocity.x += boost_velocity * math.sin(-ramp_direction + math.PI * 0.5) * math.cos(boost_direction)
						player.velocity.z += boost_velocity * math.cos(-ramp_direction + math.PI * 0.5) * math.cos(boost_direction)
						player.velocity.y += boost_velocity * math.sin(boost_direction)
					} else {
						if player.last_position.y > player.position.y {
							player_reset_step(player, recon)
						}

						player.position.y = collision_height
						player.velocity.y = 0.0
						player.on_wall = 0
						player.on_ground = true
						player.on_terrain = false

						player.has_ramp_fix = true
						player.on_ramp = true
						player.ramp_fix = obj.position.y + obj.scale.y * math.round(progress)
					}
				}

				continue
			}

			if obj.collision_type == .CYLINDER {
				y_collision := true

				if player.last_position.y >= obj.position.y + obj.scale.y {
					if !recon && player.render_you && player.last_position.y > player.position.y && player.velocity.y != 0 {
						player_animate_land(player)
					}
					player.position.y = obj.position.y + obj.scale.y
					player.velocity.y = 0.0
					player.on_ground = true
					player.on_terrain = false
				} else if player.last_position.y + player.height <= obj.position.y {
					player.position.y = obj.position.y - player.height
					player.velocity.y = 0.0
				} else if player.position.y < obj.position.y + obj.scale.y && obj.position.y + obj.scale.y - player.position.y <= GAME_CONSTANTS.climb_height && player.last_position.y < obj.position.y + obj.scale.y && can_jump {
					player.position.y += (obj.position.y + obj.scale.y - player.position.y) * 0.3
					player.on_ground = true
					player.on_terrain = false
				} else {
					direction := math.atan2(player.position.z - obj.position.z, player.position.x - obj.position.x)

					player.position.x = obj.position.x + (obj.scale.x * 0.5 + player.scale) * math.cos(direction)
					player.position.z = obj.position.z + (obj.scale.x * 0.5 + player.scale) * math.sin(direction)

					y_collision = false
				}

				if y_collision {
					direction := math.atan2(player.position.z - obj.position.z, player.position.x - obj.position.x) - obj.spin * delta * GAME_CONSTANTS.disk_spin
					distance := math.sqrt((player.position.x - obj.position.x) * (player.position.x - obj.position.x) + (player.position.z - obj.position.z) * (player.position.z - obj.position.z))

					old_x := player.position.x
					old_z := player.position.z

					player.position.x = obj.position.x + distance * math.cos(direction)
					player.position.z = obj.position.z + distance * math.sin(direction)

					player.x_vel_cylinder = player.position.x - old_x
					player.z_vel_cylinder = player.position.z - old_z
				}

				continue
			}

			if (!obj.is_border || player.game.config.disable_borders) &&
			   player.position.y < obj.position.y + obj.scale.y &&
			   obj.position.y + obj.scale.y - player.position.y <= GAME_CONSTANTS.climb_height &&
			   player.last_position.y < obj.position.y + obj.scale.y && can_jump {
				player.position.y += delta * 30.0
				player.position.y = min(player.position.y, obj.position.y + obj.scale.y)

				player.on_ground = true
				player.on_terrain = false
			} else if player.last_position.y >= obj.position.y + obj.scale.y + (obj.is_border && !player.game.config.disable_borders ? GAME_CONSTANTS.border_height : 0.0) {
				if player.last_position.y > player.position.y {
					player_reset_step(player, recon)
				}

				player.position.y = obj.position.y + obj.scale.y + (obj.is_border && !player.game.config.disable_borders ? GAME_CONSTANTS.border_height : 0.0)
				player.velocity.y = 0.0
				player.on_ground = true
				player.on_terrain = false
			} else if player.last_position.x - player.scale >= obj.position.x + obj.scale.x * 0.5 - 0.00001 {
				player.position.x = obj.position.x + obj.scale.x * 0.5 + player.scale
				player.velocity.x = 0.0
			} else if player.last_position.x + player.scale <= obj.position.x - obj.scale.x * 0.5 + 0.00001 {
				player.position.x = obj.position.x - obj.scale.x * 0.5 - player.scale
				player.velocity.x = 0.0
			} else if player.last_position.z - player.scale >= obj.position.z + obj.scale.z * 0.5 - 0.00001 {
				player.position.z = obj.position.z + obj.scale.z * 0.5 + player.scale
				player.velocity.z = 0.0
			} else if player.last_position.z + player.scale <= obj.position.z - obj.scale.z * 0.5 + 0.00001 {
				player.position.z = obj.position.z - obj.scale.z * 0.5 - player.scale
				player.velocity.z = 0.0
			} else if player.last_position.y + player.height <= obj.position.y {
				// Krunker: stopCrouch, and with headClipFix the previous height when
				// the crouch was already held by an underside.
				player.stop_crouch = true
				head_clip_fix := player.game.config.head_clip_fix
				player.position.y = obj.position.y - (player.was_stop_crouch && head_clip_fix ? player.height_old : player.height)
				player.velocity.y = 0.0
			} else if player.game.config.head_clip_fix && player.last_position.y + player.height_old <= obj.position.y {
				player.stop_crouch = true
				player.position.y = obj.position.y - player.height
				player.velocity.y = 0.0
			}
		}
	}
}

// Krunker's blockRampSide: with Solid Ramp Sides, a ramp's side is a wall.
// Its tolerance is the collision padding, not the boxes' 0.00001.
@(private = "file")
player_block_ramp_side :: proc(player: ^Player, obj: ^Object) -> bool {
	pad := GAME_CONSTANTS.collision_padding
	half_x, half_z := obj.scale.x * 0.5, obj.scale.z * 0.5
	if player.last_position.x - player.scale >= obj.position.x + half_x - pad {
		player.position.x = obj.position.x + half_x + player.scale
		player.velocity.x = 0
	} else if player.last_position.x + player.scale <= obj.position.x - half_x + pad {
		player.position.x = obj.position.x - half_x - player.scale
		player.velocity.x = 0
	} else if player.last_position.z - player.scale >= obj.position.z + half_z - pad {
		player.position.z = obj.position.z + half_z + player.scale
		player.velocity.z = 0
	} else if player.last_position.z + player.scale <= obj.position.z - half_z + pad {
		player.position.z = obj.position.z - half_z - player.scale
		player.velocity.z = 0
	} else {
		return false
	}
	return true
}

player_jump :: proc(player: ^Player) {
	player.did_act = true
	player.jump_timer = (player.terrain_slipping ? GAME_CONSTANTS.player_slipping_jump_cooldown : 0.0) * player.game.map_inst.config.jump_cooldown
	player.did_jump = true
	player.did_wall_jump = true
	player.on_terrain = false

	jump_push := GAME_CONSTANTS.jump_push * player.game.config.jump_mlt
	jump_vel := GAME_CONSTANTS.jump_velocity * player.game.config.jump_mlt * (player.game.mode.config.real_movement ? 0.92 : 1.0)
	vel := math.sqrt(player.velocity.x * player.velocity.x + player.velocity.z * player.velocity.z)

	weapon_jump_mlt := player.weapon.jump_mlt != 0 ? player.weapon.jump_mlt : player.weapon.speed_mlt
	player.velocity.y += jump_vel * (1.0 - GAME_CONSTANTS.crouch_jump * player.crouch_val) * weapon_jump_mlt * (player.aim_val != 1.0 ? 1.0 : GAME_CONSTANTS.jump_aim_slow)

	player.velocity.x -= vel * jump_push * math.sin(player.direction.y)
	player.velocity.z -= vel * jump_push * math.cos(player.direction.y)
}

player_swap_weapon :: proc(player: ^Player, index: i32, force_swap, instant_swap, recon: bool) {
	if player == nil || player.loadout_size <= 0 || index < 0 || index >= player.loadout_size {
		return
	}

	loadout_changed := force_swap || player.loadout_index != index
	player.loadout_index = index

	if !instant_swap && loadout_changed {
		player.reload_timer_ms = 0.0
		player.charge_time_ms, player.full_charge = 0, false
		player.did_shoot = false
		player.burst_count = 0
	}

	weapons := player.game.weapons if player.game != nil && len(player.game.weapons) > 0 else g_weapons()
	player.weapon = weapons[player.loadout[player.loadout_index]]

	if player.weapon == nil {
		player.weapon = weapons[player.loadout[0]]

		if player.weapon != nil {
			player.loadout_index = 0
			loadout_changed = true
		}
	}

	if !instant_swap && player.weapon != nil {
		if !recon && loadout_changed {
			player.swap_timer_ms = weapon_seconds_to_ms(player.weapon.swap_time)
		}
	}
	if loadout_changed {
		player.melee_pose = {}
		player.melee_phase = 0
		player.view_kick = {}
		player.view_kick_phase = 0
		if player.weapon != nil && player.weapon.melee && player.aim_val == 0 {
			player.melee_pose[MELEE_ARM_R] = -0.3
			player.melee_pose_start = player.melee_pose
			player.melee_pose_target = {}
			player.melee_phase = 3
			player.melee_time = 0
			player.melee_duration = 0.31
		}
	}
}

player_reload :: proc(player: ^Player) {
	if player.reload_timer_ms != 0 || player.ammo[player.loadout_index] >= player.weapon.ammo {
		return
	}

	player.reload_timer_ms = player_reload_duration_ms(player)
	player.burst_count = 0
}

player_apply_recoil :: proc(player: ^Player, force_mlt: f32 = 1) {
	if player == nil || player.weapon == nil {
		return
	}

	player.recoil_force += player.weapon.recoil * force_mlt // Krunker: x3.5 for a charge blast

	rand_recoil := (rand.float32() - 0.5) * 2.0 * math.PI
	player.recoil.x += player.weapon.recoil_r * math.sin(rand_recoil)
	player.recoil.z += player.weapon.recoil_r * 0.3 * math.cos(rand_recoil)
}

// Indices match v3's armR, armT, armY, lArm, armM, armS, armE,
// weaR, weaM, flipW, rArm channels.
MELEE_ARM_R :: 0
MELEE_ARM_T :: 1
MELEE_ARM_Y :: 2
MELEE_L_ARM :: 3
MELEE_ARM_M :: 4
MELEE_ARM_S :: 5
MELEE_ARM_E :: 6
MELEE_WEA_R :: 7
MELEE_WEA_M :: 8
MELEE_FLIP_W :: 9
MELEE_R_ARM :: 10

player_start_view_kick :: proc(player: ^Player) {
	if player.weapon == nil || player.weapon.melee {
		return
	}
	time := player.weapon.view_kick_time != 0 ? player.weapon.view_kick_time : player.weapon.rate
	time *= player.game.config.fire_rate > 0 ? player.game.config.fire_rate : 1
	if player.aim_val >= 1 && player.weapon.view_kick_aim_time != 0 {
		time = player.weapon.view_kick_aim_time
	}
	player.view_kick_start = player.view_kick
	player.view_kick_phase = 1
	player.view_kick_time = 0
	player.view_kick_duration = max(0.001, time * 0.15)
	player.view_kick_return = max(0.001, time * 0.95)
}

player_start_melee_animation :: proc(player: ^Player, kind: i32) {
	backhand := player.melee_phase != 0 && player.melee_pose[MELEE_ARM_M] >= 2
	player.melee_pose = {}
	player.melee_pose_target = {}
	player.melee_punch_left = !player.melee_punch_left
	player.melee_kind = kind
	player.melee_phase = 1
	player.melee_time = 0
	if kind == 1 {
		player.melee_duration = backhand ? 0.286 : 0.22
		if backhand {
			player.melee_pose[MELEE_WEA_R] = -1.1
			player.melee_pose[MELEE_ARM_R] = 0.4
			player.melee_pose[MELEE_WEA_M] = 0.9
			player.melee_pose[MELEE_FLIP_W] = math.PI
		}
		player.melee_pose_start = player.melee_pose
		player.melee_pose_target = player.melee_pose
		player.melee_pose_target[MELEE_ARM_R] = backhand ? 0.4 : -0.4
		player.melee_pose_target[MELEE_L_ARM] = 1
		player.melee_pose_target[MELEE_ARM_T] = backhand ? -0.2 : -0.8
		player.melee_pose_target[MELEE_ARM_Y] = -3
		player.melee_pose_target[MELEE_ARM_M] = backhand ? -10 : 13
		player.melee_pose_target[MELEE_ARM_E] = -2
		player.melee_pose_target[MELEE_WEA_R] = backhand ? -1.1 : -1.6
		player.melee_pose_target[MELEE_WEA_M] = backhand ? 0.9 : 0.7
	} else if kind == 2 {
		player.melee_duration = 0.01
		player.melee_pose_start = player.melee_pose
		player.melee_pose_target[player.melee_punch_left ? MELEE_L_ARM : MELEE_R_ARM] = -2.7
	} else {
		player.melee_duration = 0.3
		player.melee_pose = {-1.3, 1, 2.9, 0, 1.7, 1.7, 1.1, -0.6, 0, 0, 0}
		player.melee_pose_start = player.melee_pose
		player.melee_pose_target = player.melee_pose
		player.melee_pose_target[MELEE_ARM_Y] = -9
		player.melee_pose_target[MELEE_ARM_S] = -0.1
		player.melee_pose_target[MELEE_ARM_E] = -7.5
		player.melee_pose_target[MELEE_ARM_M] = -1.5
		player.melee_pose_target[MELEE_L_ARM] = 0.5
		player.melee_pose_target[MELEE_WEA_R] = -3
	}
}

player_update_visual_animations :: proc(player: ^Player, delta: f32) {
	player_update_movement_animation(player, delta)
	if player.view_kick_phase != 0 {
		player.view_kick_time += delta
		k := min(1.0, player.view_kick_time / player.view_kick_duration)
		if player.view_kick_phase == 1 {
			for i in 0 ..< 4 {
				player.view_kick[i] = player.view_kick_start[i] + (player.weapon.view_kick[i] - player.view_kick_start[i]) * k
			}
		} else {
			e := 1.0 + (k - 1.0) * (k - 1.0) * (2.70158 * (k - 1.0) + 1.70158)
			for i in 0 ..< 4 {
				player.view_kick[i] = player.view_kick_start[i] * (1.0 - e)
			}
		}
		if k >= 1 {
			if player.view_kick_phase == 1 {
				player.view_kick_phase = 2
				player.view_kick_start = player.view_kick
				player.view_kick_duration = player.view_kick_return
				player.view_kick_time = 0
			} else {
				player.view_kick_phase = 0
			}
		}
	}
	if player.melee_phase != 0 {
		player.melee_time += delta
		if player.melee_kind == 2 && player.melee_phase == 2 && player.melee_time < 0.1 {
			return
		}
		elapsed := player.melee_time - (player.melee_kind == 2 && player.melee_phase == 2 ? 0.1 : 0.0)
		k := min(1.0, elapsed / player.melee_duration)
		e := player.melee_phase == 3 ? math.sin(k * math.PI * 0.5) : player.melee_kind == 2 ? k : 1.0 + (k - 1.0) * (k - 1.0) * (k - 1.0)
		for i in 0 ..< 11 {
			player.melee_pose[i] = player.melee_pose_start[i] + (player.melee_pose_target[i] - player.melee_pose_start[i]) * e
		}
		if k >= 1 {
			if player.melee_phase == 1 {
				player.melee_phase = 2
				player.melee_pose_start = player.melee_pose
				player.melee_pose_target = {}
				player.melee_duration = player.melee_kind == 2 ? 0.15 : 0.35
				player.melee_time = 0
			} else {
				player.melee_phase = 0
			}
		}
	}
}

player_update_recoil :: proc(player: ^Player, delta: f32) {
	if player == nil || player.weapon == nil {
		return
	}

	delta := min(delta, GAME_CONSTANTS.max_delta)
	if player.recoil_force != 0 {
		player.recoil_anim += player.recoil_force * delta
		player.recoil_anim_y += player.recoil_force * (player.weapon.recoil_y != 0 ? player.weapon.recoil_y : 1.0) * (1.0 - player.crouch_val * 0.3) * delta
		player.recoil_force *= math.pow(player.weapon.recover_f, delta * 1000.0)
	}

	if player.recoil_anim != 0 {
		player.recoil_anim *= math.pow(player.weapon.recover, delta * 1000.0)
	}

	if player.recoil_anim_y != 0 {
		player.recoil_anim_y *= math.pow(player.weapon.recover_y != 0 ? player.weapon.recover_y : player.weapon.recover, delta * 1000.0)
	}
}

// Fresh client prediction may play movement effects. Reconciliation replays
// leave predict_effects false so snapshots cannot restart the same animation.

player_proc_input :: proc(player: ^Player, input: ^Input, recon, move_lock: bool, predict_effects: bool = false, predict_combat: bool = false) {
	// Capture fresh actions once. Reconciliation replays only restore motion.
	was_grounded, was_wall_jump := player.on_ground, player.did_wall_jump
	previous_reload, previous_slide := player.reload_timer_ms, player.slide_timer
	previous_weapon, previous_shot := player.loadout_index, player.shot_seq
	emit_presentation := player.game != nil && player.game.presentation_enabled && (!recon || predict_effects)
	player.land_velocity = 0
	defer {
		if emit_presentation {
			if player.shot_seq != previous_shot { player_emit_presentation(player, .FIRE) }
			if previous_weapon != player.loadout_index { player_emit_presentation(player, .SWAP) }
			if previous_reload <= 0 && player.reload_timer_ms > 0 { player_emit_presentation(player, .RELOAD) }
			// Krunker's endReload sound: the reload finished (not cancelled by a swap).
			if previous_reload > 0 && player.reload_timer_ms <= 0 && previous_weapon == player.loadout_index { player_emit_presentation(player, .RELOAD_END) }
			if was_grounded && !player.on_ground && player.velocity.y > 0 || !was_wall_jump && player.did_wall_jump { player_emit_presentation(player, .JUMP) }
			// Krunker plays the landing in resetStep, before a bhop's next jump.
			if !was_grounded && player.land_velocity != 0 { player_emit_presentation(player, .LAND) }
			if previous_slide <= 0 && player.slide_timer > 0 { player_emit_presentation(player, .SLIDE) }
		}
	}
	delta := min(input.delta, GAME_CONSTANTS.max_delta)
	move_dir := -math.PI / 2.0 + math.PI / 4.0 * f32(input.move_dir)

	if player.noclip {
		player.on_ground = true
	}

	pitch_delta := normalize_angle(input.x_dir - player.direction.x)
	yaw_delta := normalize_angle(input.y_dir - player.direction.y)
	animate_local := player.render_you && (!recon || predict_effects)
	if animate_local {
		// These deltas are new - old; the reference uses old - new.
		player.lean_anim.x = clamp(player.lean_anim.x + yaw_delta * GAME_CONSTANTS.lean_sensitivity, -GAME_CONSTANTS.lean_max, GAME_CONSTANTS.lean_max)
		player.lean_anim.y = clamp(player.lean_anim.y + pitch_delta * GAME_CONSTANTS.lean_sensitivity, -GAME_CONSTANTS.lean_max, GAME_CONSTANTS.lean_max)
		player.lean_anim.x *= math.pow(GAME_CONSTANTS.lean_pull, delta * 1000)
		player.lean_anim.y *= math.pow(GAME_CONSTANTS.lean_pull, delta * 1000)
		player.lean_anim.z *= math.pow(GAME_CONSTANTS.lean_pull_z, delta * 1000)
		player.bob_anim.y *= math.pow(GAME_CONSTANTS.bob_pull_y, delta * 1000)
		player.bob_anim.z *= math.pow(GAME_CONSTANTS.bob_pull_z, delta * 1000)
	}

	player.direction.x = clamp(input.x_dir, -math.PI / 2.0, math.PI / 2.0)
	player.direction.y = input.y_dir
	if player.frozen {
		player.velocity = {}
		return
	}

	// Krunker's swap codes (wSwap): 1 swapSecondary, 2 swapMelee, 3 the Primary
	// key: swapWeapon to loadout slot 0 (nothing when already there), 4
	// swapEquipment.
	if input.swap == 3 && player.loadout_size > 1 {
		if player.loadout_index != 0 { player_swap_weapon(player, 0, false, false, recon && !predict_combat) }
	} else if input.swap != 0 && player.loadout_size > 1 {
		swap_secondary := input.swap == 1
		swap_melee := input.swap == 2
		swap_equipment := input.swap == 4

		swap_to: i32 = -1
		// Resolve swap targets from the active data-driven registry. Custom
		// weapon flags must affect secondary/melee selection as they do in the
		// native configured loadout.
		weapons := player.game.weapons if player.game != nil && len(player.game.weapons) > 0 else g_weapons()

		for i in 0 ..< player.loadout_size {
			weapon := player.loadout[i]

			if swap_secondary && weapons[weapon].secondary {
				swap_to = i32(i)
				break
			}

			if swap_melee && weapons[weapon].melee {
				swap_to = i32(i)
				break
			}

			if swap_equipment && weapons[weapon].equipment {
				swap_to = i32(i)
				break
			}
		}

		if swap_to >= 0 {
			if player.loadout_index == swap_to {
				swap_to = 0
			}

			player_swap_weapon(player, swap_to, false, false, recon && !predict_combat)
		}
	}

	// Krunker advances recoil here, once per input command and before aiming
	// and shooting, so this command's shot already uses the recoil built up so
	// far. Its flag is the one swapWeapon gets: a reconciliation replay never
	// runs it again, while the first, live prediction of a command does. Recoil
	// is integrated in steps (anim += force * dt), so stepping by display frame
	// instead gave a curve that changed with FPS and missed the server's.
	if !recon || predict_combat {
		player_update_recoil(player, delta)
	}

	player.last_position = player.position

	if player.weapon.no_aim && player.aim_val > 0.0 {
		player.aim_val = 0.0
	} else if player.weapon.zoom != 0 && (!player.weapon.no_aim || player.swap_timer_ms > 0.0) {
		can_scope := player.reload_timer_ms <= 0.0 && player.swap_timer_ms <= 0.0 && (!player.weapon.melee || (player.can_throw && player.game.config.throwable_melees))

		if input.scope && player.aim_val < 1.0 && can_scope {
			player.aim_val += 1.0 / player.weapon.aim_speed * delta
			player.aim_val = min(1.0, player.aim_val)
		} else if !can_scope || !input.scope && player.aim_val > 0.0 {
			player.aim_val -= 1.0 / player.weapon.aim_speed * delta
			player.aim_val = max(0.0, player.aim_val)
		}

		if player.aim_val == 1.0 {
			player.aim_time += delta
		} else {
			player.aim_time = 0.0
		}
	}

	// Krunker: wasStopCrouch = config.headClipFix && stopCrouch; stopCrouch = false;
	// the crouch only changes when the head did not hit an underside last command.
	player.was_stop_crouch = player.game != nil && player.game.config.head_clip_fix && player.stop_crouch
	player.stop_crouch = false
	if player.was_stop_crouch {
		// crouch held as it is
	} else if input.crouch && player.crouch_val < 1.0 && !player.on_ladder {
		player.crouch_val = min(1.0, player.crouch_val + GAME_CONSTANTS.crouch_speed * delta)

		if player.on_ground {
			if animate_local { player.bob_anim.y -= GAME_CONSTANTS.crouch_anim * 1.4 * delta }
		} else {
			player.position.y += GAME_CONSTANTS.crouch_speed * delta
		}
	} else if !input.crouch && player.crouch_val > 0.0 {
		player.crouch_val = max(0.0, player.crouch_val - GAME_CONSTANTS.crouch_speed * delta)

		if player.on_ground {
			if animate_local { player.bob_anim.y += GAME_CONSTANTS.crouch_anim * delta }
		} else {
			player.position.y -= GAME_CONSTANTS.crouch_speed * delta
		}
	}
	// Krunker: crouchVal && (crouchVal = crouchVal.round(3)).
	if player.crouch_val != 0 { player.crouch_val = f32(math.floor(f64(player.crouch_val) * 1000 + 0.5) / 1000) }

	player_update_height(player)

	contact := player.on_ground || player.on_ladder

	if !move_lock {
		accel: f32

		if contact {
			accel = (player.terrain_slipping ? GAME_CONSTANTS.slipping_speed : GAME_CONSTANTS.player_speed) * player.speed
		} else {
			accel = GAME_CONSTANTS.air_speed * player.game.map_inst.config.air_accel * (player.game.mode.config.real_movement ? 0.72 : 1.0)
		}

		accel *= player.aim_val == 1.0 ? GAME_CONSTANTS.aim_slow : 1.0
		accel *= player.crouch_val != 0 ? GAME_CONSTANTS.crouch_slow : 1.0
		accel *= player.game.mode.config.speed_mlt[player.team]
		accel *= player.weapon.speed_mlt
		if player.speed_boost != 0 { accel *= player.speed_boost }
		accel *= (player.noclip ? 2.0 : 1.0) * delta

		decel: f32

		if player.on_ladder {
			decel = GAME_CONSTANTS.ladder_decel
		} else if player.terrain_slipping {
			decel = GAME_CONSTANTS.terrain_slip_decel
		} else if player.on_terrain {
			decel = GAME_CONSTANTS.terrain_decel
		} else if player.on_ground {
			decel = GAME_CONSTANTS.ground_decel
		} else {
			decel = GAME_CONSTANTS.air_decel
		}

		player.can_slide_timer = max(0, player.can_slide_timer - delta)
		if player.crouch_val <= 0.5 {
			player.can_slide = true
		}

		if !player.on_ground || player.crouch_val == 0 {
			player.slide_timer = 0.0
		}

		if player.slide_timer != 0 {
			player.slide_timer = max(0.0, player.slide_timer - delta)

			if player.slide_timer > 0.0 {
				accel *= 0.25
				decel = player.on_terrain ? GAME_CONSTANTS.terrain_slide_decel : GAME_CONSTANTS.slide_decel

				vel := math.sqrt(player.velocity.x * player.velocity.x + player.velocity.z * player.velocity.z)
				dir := math.PI / 2.0 - player.direction.y

				if player.slid_cont != 0 {
					player.velocity.x = vel * math.cos(dir + math.PI)
					player.velocity.z = vel * math.sin(dir + math.PI)
				} else {
					vel_dir := math.atan2(-player.velocity.z, -player.velocity.x)
					angle_delta := normalize_angle(vel_dir - dir) * 0.18

					player.velocity.x = vel * math.cos(vel_dir + math.PI - angle_delta)
					player.velocity.z = vel * math.sin(vel_dir + math.PI - angle_delta)
				}
			}
		}

		player.jump_timer = max(0.0, player.jump_timer - delta)

		if player.jump_timer <= 0.0 && (player.on_ground || player.game.map_inst.config.infinite_jump) {
			if player.did_jump && !input.jump {
				player.did_jump = false
			}

			if input.jump && (!player.did_jump || player.game.config.auto_jump) {
				player_jump(player)
				if player.render_you && (!recon || predict_effects) {
					player_animate_jump(player, false)
				}
			}
		}

		if !contact {
			wall_mlt: f32 = player.velocity.y < 0.0 && player.wall_jump && player.on_wall != 0 && player.game.config.wall_jump > 0.0 && player.crouch_val != 0 ? 0.3 : 1.0
			player.velocity.y -= delta * GAME_CONSTANTS.gravity * player.game.config.gravity_mlt * wall_mlt
		}

		if input.move_dir >= 0 {
			yaw_origin := player.direction.y
			// The browser boosts diagonal inputs before applying acceleration.
			// Omitting this loses about ten world units per second with the SMG.
			if input.move_dir % 2 != 0 && !player.game.mode.config.real_movement {
				accel *= player.game.config.strafe_speed
			}

			player.velocity.x += accel * math.cos(move_dir - yaw_origin)
			player.velocity.z += accel * math.sin(move_dir - yaw_origin)

			if player.noclip {
				player.velocity.y += accel * player.direction.x * (input.move_dir > 2 && input.move_dir < 6 ? -1.0 : 1.0)
			}
		}

		if !contact {
			if player.x_vel_cylinder != 0 {
				player.velocity.x += player.x_vel_cylinder * 0.07
				player.x_vel_cylinder = 0.0
			}

			if player.z_vel_cylinder != 0 {
				player.velocity.z += player.z_vel_cylinder * 0.07
				player.z_vel_cylinder = 0.0
			}
		}

		if player.game.config.fixed_movement && !player.noclip {
			// fixMov integrates exponential drag over the entire command. Comp
			// lobbies send this setting; the Euler path travels farther each tick.
			ms := delta * 1000
			decay := math.pow(decel, ms)
			travel := decel == 1 ? ms : (decay - 1) / math.ln(decel)
			player.position.x += player.velocity.x * travel * player.game.map_inst.config.speed.x
			player.position.z += player.velocity.z * travel * player.game.map_inst.config.speed.z
			player.velocity.x = crop(player.velocity.x * decay, GAME_CONSTANTS.min_decel)
			player.velocity.z = crop(player.velocity.z * decay, GAME_CONSTANTS.min_decel)
			vertical_decay := math.pow(f32(0.9993), ms)
			player.position.y += player.velocity.y * (vertical_decay - 1) / math.ln(f32(0.9993)) * player.game.map_inst.config.speed.y
			player.velocity.y *= vertical_decay
		} else {
			if player.velocity.x != 0 {
				player.position.x += player.velocity.x * player.game.map_inst.config.speed.x * delta * 1000.0
				player.velocity.x *= math.pow(decel, delta * 1000.0)
				player.velocity.x = crop(player.velocity.x, GAME_CONSTANTS.min_decel)
			}

			if player.velocity.y != 0 {
				player.position.y += player.velocity.y * player.game.map_inst.config.speed.y * delta * 1000.0

				if player.noclip {
					player.velocity.y *= math.pow(decel, delta * 1000.0)
				} else if player.velocity.y > 0.0 {
					player.velocity.y -= delta * 0.032
				} else if player.velocity.y < -0.3 {
					player.velocity.y = -0.3
				}
			}

			if player.velocity.z != 0 {
				player.position.z += player.velocity.z * player.game.map_inst.config.speed.z * delta * 1000.0
				player.velocity.z *= math.pow(decel, delta * 1000.0)
				player.velocity.z = crop(player.velocity.z, GAME_CONSTANTS.min_decel)
			}
		}

		can_jump := player.on_ground && !player.did_jump

		player.on_ground = player.noclip
		player.on_ladder = false
		player.on_wall = 0
		player.on_ramp = false

		if !player.noclip {
			// Collision's recon flag suppresses landing effects only; physics is
			// identical for fresh prediction and reconciliation replay.
			player_do_map_collisions(player, input, move_dir, can_jump, delta, recon && !predict_effects)
		}

		if !player.did_jump && player.has_ramp_fix && math.abs(player.position.y - player.ramp_fix) <= GAME_CONSTANTS.climb_height {
			if !player.on_ramp {
				player.position.y = player.ramp_fix
				player.on_ground = true
				player.velocity.y = 0.0

				player.has_ramp_fix = false
			}
		} else {
			player.has_ramp_fix = false
		}

		player.air_time = player.on_ground ? 0 : player.air_time + delta
	}

	delta_pos2D := math.sqrt((player.position.x - player.last_position.x) * (player.position.x - player.last_position.x) + (player.position.z - player.last_position.z) * (player.position.z - player.last_position.z))
	player.covered_distance += delta_pos2D
	// Krunker updates spreadPlus/spread only on fresh inputs (inside its
	// !recon block). Replaying pending inputs after an ACK must not add their
	// movement spread again or decay it again: that made SR's spread settle
	// faster than the server's after a strafe stop.
	if !recon || predict_effects || predict_combat {
		player_update_spread(player, delta_pos2D, player.position.y - player.last_position.y, delta)
	}
	if (!recon || predict_effects) && player.game.map_inst.config.model != .SPRITE {
		// Cadence follows actual displacement, including slopes and ladders.
		delta_y := player.position.y - player.last_position.y
		distance := math.sqrt(delta_pos2D * delta_pos2D + delta_y * delta_y) * (player.render_you && player.on_ladder ? 1.4 : 1.0)
		stepping := contact && input.move_dir >= 0 && !move_lock
		if player.is_you && stepping { player_step(player, distance) }
		if animate_local {
			player.bob_anim.z += delta_pos2D * GAME_CONSTANTS.bob_mlt_z
			player.bob_anim.y += delta_y * GAME_CONSTANTS.bob_mlt_y
			if stepping {
				player.lean_anim.z -= distance * GAME_CONSTANTS.lean_mlt_z * (player.weapon.z_lean_mlt != 0 ? player.weapon.z_lean_mlt : 1.0) * math.cos(move_dir)
			} else {
				player.step_val *= math.pow(GAME_CONSTANTS.step_pull, delta * 1000)
			}
			player.step_chase += (player.step_val - player.step_chase) * 0.15
		}
	}

	// Live Krunker predicts magazine/reload state and shot presentation once,
	// while movement reconciliation never repeats these effects.
	velocity_before_combat := player.velocity
	if (!recon || predict_combat) && player.game.map_inst.config.model != .SPRITE {
		player_charge_step(player, input, input_delta_ms(delta))
		if input.reload && !player.game.mode.config.no_reloads {
			player_reload(player)
		}

		// Krunker's f64 millisecond timers (weapon_timers.odin).
		delta_ms := input_delta_ms(delta)
		if player.reload_timer_ms > 0.0 {
			weapon_timer_tick(&player.reload_timer_ms, delta_ms)

			if player.reload_timer_ms == 0 {
				player.did_shoot = false
				player.ammo[player.loadout_index] = player.weapon.ammo
			}
		}

		weapon_timer_tick(&player.swap_timer_ms, delta_ms)

		for i in 0 ..< player.loadout_size {
			weapon_timer_tick(&player.reloads_ms[i], delta_ms)
		}

		if player.weapon != nil && !move_lock {
			will_shoot := player.burst_count != 0 || !player.weapon.no_auto && input.shoot

			if player.did_shoot && !input.shoot {
				player.did_shoot = false
			}

			if !player.did_shoot && input.shoot {
				will_shoot = true
			}

			if will_shoot && player.reloads_ms[player.loadout_index] <= 0.0 && player.swap_timer_ms <= 0.0 && player.reload_timer_ms <= 0.0 {
				if player.weapon.melee {
					player_melee(player, recon)
				} else {
					if player.ammo[player.loadout_index] > 0 || player.unlimited_ammo {
						// Krunker: fullCharge ? shoot(..., blast) : shoot(...).
						player_shoot(player, recon, player.full_charge)
					} else if !player.game.mode.config.no_reloads {
						player_reload(player)
					}
				}
			}
		}
	}

	// Reapply the recorded movement impulse after restoring an authoritative
	// snapshot. Replay must preserve the boost without firing/consuming ammo.
	if predict_combat {
		input.predicted_weapon_impulse = player.velocity - velocity_before_combat
	} else if recon && !move_lock && input.predicted_weapon_impulse != (Vec3{}) {
		player.velocity += input.predicted_weapon_impulse
		player.on_ground = false
	}

	// Krunker resets the wall-jump count on landing (resetStep) and allows a
	// wall jump only while wallJumpC < wallJumpMax (the class's wallJM).
	if player.on_ground {
		player.wall_jump_count = 0
	}

	if !move_lock && player.wall_jump && player.wall_jump_count < player.wall_jump_max && !player.on_ground && !player.on_ladder && player.on_wall != 0 && player.game.config.wall_jump > 0.0 {
		if player.did_wall_jump && !input.jump {
			player.did_wall_jump = false
		}

		if !player.did_wall_jump && input.jump {
			player.did_wall_jump = true
			player.wall_jump_count += 1
			if player.render_you && (!recon || predict_effects) {
				player_animate_jump(player, true)
			}

			velocity: f32 = (player.game.mode.config.real_movement ? 0.7 : 1.0) * 0.03
			player.velocity.y = (player.game.mode.config.real_movement ? 0.9 : 1.0) * 0.058

			switch player.on_wall {
			case 1:
				player.velocity.x = velocity * player.game.config.wall_jump
			case 2:
				player.velocity.x = -velocity * player.game.config.wall_jump
			case 3:
				player.velocity.z = velocity * player.game.config.wall_jump
			case 4:
				player.velocity.z = -velocity * player.game.config.wall_jump
			}

			player.on_wall = 0
		}
	}
}

player_step :: proc(player: ^Player, distance: f32) {
	if distance <= 0 { return }
	step_distance := distance * (!player.render_you && player.crouch_val != 0 ? 1.6 : 1.0)
	player.step_val += step_distance * 0.25 * (player.step_dir_neg ? -1.0 : 1.0)
	if (player.step_val >= math.PI / 2 && !player.step_dir_neg) || (player.step_val <= -math.PI / 2 && player.step_dir_neg) {
		player.step_dir_neg = !player.step_dir_neg
		player_emit_presentation(player, .STEP)
	}
}

player_melee :: proc(player: ^Player, presentation_only: bool = false) {
	is_throw := player.can_throw && player.weapon.can_throw && player.aim_val == 1.0

	// Krunker: rate * fiRat * ... * config.melRate (the class), then the
	// throw charge resets.
	player.reloads_ms[player.loadout_index] = player_fire_cooldown_ms(player) * weapon_timer_multiplier(player.melee_rate > 0 ? player.melee_rate : 1)
	player.charge_time_ms, player.full_charge = 0, false
	player.did_shoot = true
	player.did_act = true

	player.shot_seq += 1
	player_start_melee_animation(player, is_throw ? 3 : player.can_throw ? 1 : 2)

	if is_throw {
		player.can_throw = player.unlimited_ammo
	} else {
		if presentation_only { return }
		shot_height := player.position.y + player.height - GAME_CONSTANTS.camera_height
		shot_angles := Vec2{player.direction.x, player.direction.y}
		range := max(15.0, player.weapon.range)

		shot_origin := Vec3{player.position.x, shot_height, player.position.z}
		shot_dir := Vec3{
			range * math.sin(shot_angles.y + math.PI) * math.cos(shot_angles.x),
			range * math.sin(shot_angles.x),
			range * math.cos(shot_angles.y + math.PI) * math.cos(shot_angles.x),
		}

		nearest_t: f32 = 2.0
		nearest_player: ^Player

		if player.game != nil && player.game.map_inst != nil {
			for object in player.game.map_inst.objects {
				if !map_object_blocks_shots(object) {
					continue
				}
				t, _, hit := ray_box_hit(shot_origin, shot_dir, object.position, object.scale)
				if hit && t < nearest_t {
					nearest_t = t
				}
			}

			if player.game.players != nil {
				for target in player.game.players {
					if target == nil || target == player || !target.active || target.team != 0 && target.team == player.team && !player.game.mode.config.dmg_team {
						continue
					}

					body, head := player_hitboxes(target, .MELEE)
					body_t, _, body_hit := ray_box_hit(shot_origin, shot_dir, body.origin, body.scale)
					head_t, _, head_hit := ray_box_hit(shot_origin, shot_dir, head.origin, head.scale)

					hit_t := body_t
					if head_hit && (!body_hit || head_t <= body_t) {
						hit_t = head_t
					} else if !body_hit {
						continue
					}

					if hit_t < nearest_t {
						nearest_t = hit_t
						nearest_player = target
					}
				}
			}
		}

		if nearest_player != nil {
			damage := player.weapon.damage > 0 ? player.weapon.damage : 50.0
			player_apply_damage(nearest_player, player, damage, player.loadout[player.loadout_index], false)
		}
	}
}

// Krunker's charge step (procInputs, fresh inputs, after aiming): charge
// weapons charge while firing (shootChrg) and melee weapons charge their
// throw while aiming; ovrChrg cancels a charge held past 1.2x its time.
// Krunker's aimVal runs the other way (1 = hip), so its aimVal<1 is
// aim_val > 0 here and its aimVal==1 is aim_val == 0.
KRUNKER_OVERCHARGE :: 1.2 // Krunker mS
player_charge_step :: proc(player: ^Player, input: ^Input, u: f64) {
	weapon := player.weapon
	if weapon == nil || player.game == nil || !player.game.config.charge_weapons { return }
	charging := weapon.shoot_charge ? input.shoot : player.aim_val > 0
	full_time := weapon.charge_time > 0 ? f64(weapon.charge_time) : player.throw_charge_ms
	if full_time <= 0 { return }
	can_charge := weapon.charge_time > 0 && (player.ammo[player.loadout_index] > 0) || player.can_throw && weapon.can_throw
	if charging && !player.over_charged && player.swap_timer_ms <= 0 && can_charge {
		player.charge_time_ms += player.charge_time_ms >= full_time ? 0.1*u/(160/(full_time*(KRUNKER_OVERCHARGE-1))) : u
		if weapon.over_charge {
			if player.charge_time_ms >= full_time*KRUNKER_OVERCHARGE { player.charge_time_ms, player.full_charge, player.over_charged = 0, false, true }
		} else if player.charge_time_ms >= full_time {
			player.full_charge, player.charge_time_ms = true, full_time
		}
		player.charge_progress = f32(player.charge_time_ms/full_time)
	} else if weapon.charge_dec > 0 && player.charge_time_ms > 0 {
		player.charge_time_ms -= f64(weapon.charge_dec)*u
		player.full_charge = false
		if player.charge_time_ms <= 0 {
			player.charge_time_ms = 0
			if player.aim_val == 0 { player.over_charged = false }
		}
		player.charge_progress = f32(player.charge_time_ms/full_time)
	} else {
		player.full_charge, player.charge_time_ms = false, 0
		if player.aim_val == 0 { player.over_charged = false }
	}
	// this.makingMProg||f||(this.interMProg=0)
	if player.charge_time_ms <= 0 { player.charge_progress = 0 }
}

player_shoot :: proc(player: ^Player, presentation_only: bool = false, blast: bool = false) {
	weapon := player.weapon
	// Krunker: B=!unlimitedAmmo; fullChrgSht&&!blast -> B=false (only the
	// full-charge blast uses ammo).
	if !player.unlimited_ammo && !(weapon.full_charge_shot && !blast) && player.ammo[player.loadout_index] > 0 {
		player.ammo[player.loadout_index] -= 1
	}

	player.did_act = true
	player.shot_seq += 1
	if !weapon.bypass_charge {
		player.did_shoot = true
		player.charge_time_ms, player.full_charge = 0, false
	}
	// rateChrg: the cooldown shrinks as the charge builds (x1.5 .. x0.7).
	rate_mlt: f64 = 1
	if weapon.rate_charge && weapon.charge_time > 0 {
		rate_mlt = max(0.7, 1.5*(1 - min(1, player.charge_time_ms/f64(weapon.charge_time))))
	}
	if blast {
		player.full_charge, player.charge_time_ms = false, 0
	} else {
		player.did_shoot = true
	}

	if player.burst_count != 0 {
		player.burst_count -= 1
	} else {
		player.burst_count = weapon.burst ? i32(weapon.burst_count) - 1 : 0
	}

	player.reloads_ms[player.loadout_index] = player_fire_cooldown_ms(player, player.burst_count != 0 && weapon.burst) * rate_mlt

	player_apply_recoil(player, blast ? 3.5 : 1)
	player_start_view_kick(player)

	is_projectile := player.weapon.projectile && (!player.weapon.projectile_disable || player.game.config.bullet_drop)
	shot_height := player.position.y + player.height - GAME_CONSTANTS.camera_height

	shot_angles := Vec2{0, 0}

	if is_projectile {
		player.projectile_shot_seq += 1
		shot_angles = player_projectile_angles(player)
		projectile_spawn(player, shot_angles)
	}

	if !is_projectile || player.weapon.physical_power != 0 {
		shots: u32 = player.weapon.shots != 0 ? player.weapon.shots : 1

		start: i32 = player.weapon.physical_power != 0 ? -1 : 0
		// Projectile weapons still probe for a boost, but their projectile owns damage.
		end := is_projectile ? 0 : i32(shots)
		for i := start; i < end; i += 1 {
			shot_angles = player_hitscan_angles(player, i)
			if i == 0 { player.last_shot_angles = shot_angles }

			range := i < 0 ? player.weapon.physical_range : player.weapon.range

			shot_origin := Vec3{player.position.x, shot_height, player.position.z}
			shot_dir := Vec3{
				range * math.sin(shot_angles.y + math.PI) * math.cos(shot_angles.x),
				range * math.sin(shot_angles.x),
				range * math.cos(shot_angles.y + math.PI) * math.cos(shot_angles.x),
			}

			nearest_t: f32 = 2.0
			nearest_normal := Vec3{}
			nearest_object_index: i32 = -1
			nearest_player: ^Player
			headshot := false

			for object, object_index in player.game.map_inst.objects {
				if !map_object_blocks_shots(object) {
					continue
				}
				t, normal, hit := ray_box_hit(shot_origin, shot_dir, object.position, object.scale)
				if hit && t < nearest_t {
					nearest_t = t
					nearest_normal = normal
					nearest_object_index = i32(object_index)
				}
			}

			// The extra, unspread ray is a self-impulse probe, never a damage
			// pellet. Its nearest surface can block boosting via map flags.
			if i < 0 {
				if nearest_object_index >= 0 && nearest_t >= 0 && nearest_t < 1 && range > 0 {
					object := player.game.map_inst.objects[nearest_object_index]
					strength := (1 - nearest_t) * player.weapon.physical_power * player.game.config.impulse_mlt
					if !object.no_impulse && !object.no_player_collision && strength != 0 {
						player.velocity -= shot_dir * (strength / range)
						player.on_ground = false
					}
				}
				continue
			}

			skip_players := presentation_only && player.game.server_hits_players
			for target in player.game.players {
				if skip_players { break }
				if target == player || !target.active || target.team != 0 && target.team == player.team && !player.game.mode.config.dmg_team {
					continue
				}

				body, head := player_hitboxes(target, .SHOT)
				body_t, _, body_hit := ray_box_hit(shot_origin, shot_dir, body.origin, body.scale)
				head_t, _, head_hit := ray_box_hit(shot_origin, shot_dir, head.origin, head.scale)

				hit_t := body_t
				is_head := false
				if head_hit && (!body_hit || head_t <= body_t) {
					hit_t = head_t
					is_head = true
				} else if !body_hit {
					continue
				}

				if hit_t < nearest_t {
					nearest_t = hit_t
					nearest_player = target
					nearest_normal = {}
					nearest_object_index = -1
					headshot = is_head
				}
			}

			if nearest_player != nil && !presentation_only {
				distance := range * nearest_t
				damage := player.weapon.damage
				if player.weapon.range > player.weapon.drop_start && distance > player.weapon.drop_start {
					drop_progress := clamp((distance - player.weapon.drop_start) / (player.weapon.range - player.weapon.drop_start), 0.0, 1.0)
					damage = max(0.0, damage - player.weapon.damage_drop * drop_progress)
				}
				if headshot {
					damage *= player.weapon.headshot_mlt
				}
				player_apply_damage(nearest_player, player, damage, player.loadout[player.loadout_index], headshot)
			}

			trace_hit := nearest_t <= 1.0
			impact := Bullet_Impact{
				origin   = shot_origin,
				position = shot_origin + shot_dir * (trace_hit ? nearest_t : 1.0),
				normal   = nearest_normal,
				hit      = trace_hit,
				kind = !trace_hit ? .Miss : nearest_player != nil ? .Player : .World,
				object_index = nearest_object_index,
				weapon_id = player.loadout[player.loadout_index],
				shooter_uid = player.uid,
			}

			// Every bullet emits a bounded path event with its hit surface.
			if len(player.game.impacts) >= 256 {
				ordered_remove(&player.game.impacts, 0)
			}
			append(&player.game.impacts, impact)
		}
	}
}

player_update :: proc(player: ^Player, delta: f32) {
	if !player.active {
		return
	}

	player_update_visual_animations(player, delta)

	if game_is_authority(player.game) && player.game.config.health_regen && !player.game.mode.config.no_regen && player.health < f32(player.max_health) && player.game.now - player.last_damage_time >= player.game.config.regen_delay {
		class := &player.game.classes[player.class_index]
		player.health = min(f32(player.max_health), player.health + f32(player.max_health) * class.regen * delta)
	}

	if len(player.input_queue) > 0 {
		for i in 0 ..< len(player.input_queue) {
			player_proc_input(player, &player.input_queue[i], false, player.game.move_lock)
		}

		clear(&player.input_queue)
	}

	player.idle_anim += GAME_CONSTANTS.idle_anim_speed * delta

	if player.hp_chase > player.health / f32(player.max_health) {
		player.hp_chase = max(0.0, player.hp_chase - delta * 0.2)
	} else {
		player.hp_chase = player.health / f32(player.max_health)
	}

	if player.interpolate {
		player_interpolate(player, delta)
	}
}

player_interpolate :: proc(player: ^Player, delta: f32) {
	if !player.interpolate {
		return
	}

	player.dt += delta

	progress := clamp(
		player.dt * player.send_rate / GAME_CONSTANTS.interpolation / player.game.config.delta_mlt,
		0.0,
		1.0,
	)

	player.last_position = player.position

	player.position.x = player.interp_pos_start.x + (player.interp_pos_end.x - player.interp_pos_start.x) * progress
	player.position.y = player.interp_pos_start.y + (player.interp_pos_end.y - player.interp_pos_start.y) * progress
	player.position.z = player.interp_pos_start.z + (player.interp_pos_end.z - player.interp_pos_start.z) * progress
	player.direction.x = player.interp_dir_start.x + (player.interp_dir_end.x - player.interp_dir_start.x) * progress
	player.direction.y = player.interp_dir_start.y + normalize_angle(player.interp_dir_end.y - player.interp_dir_start.y) * progress

	if player.on_ground {
		player_step(player, math.sqrt((player.last_position.x - player.position.x) * (player.last_position.x - player.position.x) + (player.last_position.z - player.position.z) * (player.last_position.z - player.position.z)))
	}
}

player_destroy :: proc(player: ^Player) {
	delete(player.loadout)
	delete(player.ammo)
	delete(player.reloads_ms)
	delete(player.input_queue)

	free(player)
}
