package main

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import shared "../shared"

RAMP_DT :: f32(3.0 / 1000.0)

ramp_test_player :: proc(game: ^shared.Game, map_inst: ^shared.Map) -> ^shared.Player {
	shared.game_configure(game, nil, []^shared.Map{map_inst}, nil, nil, nil)
	shared.game_init(game, 0, -1, true)
	// Live comp lobbies use fixed movement.
	game.config.fixed_movement = true
	player := shared.player_init(game)
	shared.game_players_add(game, player)
	shared.player_spawn(player, 0)
	player.swap_timer = 0
	return player
}

// Native move 4 accelerates along (cos theta, sin theta) for yaw PI/2 - theta.
ramp_test_walk :: proc(player: ^shared.Player, theta: f32) {
	input := shared.Input{delta = RAMP_DT, move_dir = 4, y_dir = shared.normalize_angle(math.PI / 2 - theta)}
	shared.player_proc_input(player, &input, false, false)
}

// Krunker's surface height for one ramp, written from the browser code
// rather than from SR Client's loader. addRamp(x, y, z, w, h, l, d * PI/2)
// stores the collider centred at y + h/2 with half-height h/2, and the line
// sX/sZ = x/z - F*cos/sin(d), eX/eZ = x/z + F*cos/sin(d), F = (rotated ? l : w)/2.
// Collision samples the player's leading edge (x + scale*cos(d), z +
// scale*sin(d)) and puts the surface at
// (y_centre - h/2) + (2*(h/2) + 0.01) * clamp(progress, 0, 1).
krunker_ramp_height :: proc(raw_position, raw_scale: shared.Vec3, raw_direction: int, player_x, player_z, player_scale: f32) -> f32 {
	dir := f32(raw_direction) * math.PI / 2
	rotated := dir != 0 && dir != math.PI
	f := (rotated ? raw_scale.z : raw_scale.x) / 2
	sx, sz := raw_position.x - f * math.cos(dir), raw_position.z - f * math.sin(dir)
	ex, ez := raw_position.x + f * math.cos(dir), raw_position.z + f * math.sin(dir)
	px, pz := player_x + player_scale * math.cos(dir), player_z + player_scale * math.sin(dir)
	progress := ((ex - sx) * (px - sx) + (ez - sz) * (pz - sz)) / ((ex - sx) * (ex - sx) + (ez - sz) * (ez - sz))
	half := raw_scale.y / 2
	centre := raw_position.y + half
	return centre - half + (2 * half + 0.01) * clamp(progress, 0, 1)
}

// Walk up and back down one collidable ramp of each orientation. Every tick
// on the ramp must sit on Krunker's surface, and walking down must stay
// grounded from the top platform to the floor.
test_ramp_surface_matches_krunker :: proc() -> bool {
	path := shared.concat(shared.assets_path(), "maps/sandstorm_v3.json")
	defer delete(path)
	map_inst, loaded := shared.map_load_from_file(path)
	if !loaded {
		fmt.eprintln("Ramp surface test: could not load Sandstorm")
		return false
	}
	defer shared.map_destroy(map_inst)

	// Raw map values: p, s and d of Sandstorm ramps 7, 8, 11 and 9.
	Raw_Ramp :: struct { position, scale: shared.Vec3, direction: int }
	ramps := []Raw_Ramp{
		{{64, 13, -4}, {44, 20, 36}, 0}, {{-208, 33, 101}, {36, 15, 56}, 1},
		{{80, 33, -106}, {54, 15, 49}, 2}, {{-174, 33, -89}, {48, 11, 32}, 3},
	}
	checked := 0
	for raw in ramps {
		ramp: ^shared.Object
		for object in map_inst.objects { if object.ramp != nil && object.position == raw.position { ramp = object } }
		if ramp == nil || int(ramp.direction) != raw.direction || ramp.collision_type != .BOX {
			fmt.eprintf("Ramp surface test: ramp %v d=%d did not load as a solid ramp\n", raw.position, raw.direction)
			return false
		}
		game := shared.Game{}
		defer shared.game_destroy(&game)
		player := ramp_test_player(&game, map_inst)
		uphill := f32(raw.direction) * math.PI / 2
		length := raw.direction % 2 == 1 ? raw.scale.z : raw.scale.x
		start := shared.Vec3{raw.position.x - (length / 2 + 8) * math.cos(uphill), raw.position.y, raw.position.z - (length / 2 + 8) * math.sin(uphill)}
		player.position, player.last_position = start, start
		top := raw.position.y + raw.scale.y
		reached_top, ramp_ticks, descending := false, 0, false
		for tick in 0 ..< 1400 {
			// Turn back at the high end; past it some ramps end in a drop.
			ramp_test_walk(player, reached_top ? uphill + math.PI : uphill)
			if reached_top && player.on_ramp { descending = true }
			if player.on_ramp {
				ramp_ticks += 1
				expected := krunker_ramp_height(raw.position, raw.scale, raw.direction, player.position.x, player.position.z, player.scale)
				if abs(player.position.y - expected) > 0.0001 {
					fmt.eprintf("Ramp surface test: d=%d tick %d at %v: y %.5f, Krunker surface %.5f\n", raw.direction, tick, player.position, player.position.y, expected)
					return false
				}
			}
			if !reached_top && player.position.y >= top - 0.001 { reached_top = true }
			// Krunker skips a ramp once y reaches its top (`this.y < r.y +
			// r.height`), so stepping off the top platform may be airborne for
			// a tick. Below the top, walking down must stay grounded.
			if descending && !player.on_ground && player.position.y < top - 0.02 {
				fmt.eprintf("Ramp surface test: d=%d walking down left the ground at tick %d, %v\n", raw.direction, tick, player.position)
				return false
			}
			checked += 1
		}
		if !reached_top || ramp_ticks < 200 || abs(player.position.y - raw.position.y) > 0.0001 {
			fmt.eprintf("Ramp surface test: d=%d top=%v ramp_ticks=%d final=%v\n", raw.direction, reached_top, ramp_ticks, player.position)
			return false
		}
	}
	fmt.println("Ramp surface matches Krunker for all four orientations, up and down OK")
	return true
}

// RAMP's map loader passes noCol (`l` or `col`) to addRamp, which then makes
// no collider. Site's 1-unit lip at (75, 42, 147) sits on top of the ramp at
// (94, 32, 147); a solid copy lifted prediction to 43 and dropped it off a
// ledge the server does not have.
test_no_collision_ramps :: proc() -> bool {
	dir := shared.concat(shared.assets_path(), "maps")
	defer delete(dir)
	entries, read_err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if read_err != nil {
		fmt.eprintln("No-collision ramp test: could not list maps")
		return false
	}
	solid, decorative, maps := 0, 0, 0
	for entry in entries {
		if !strings.has_suffix(entry.name, ".json") do continue
		map_inst, loaded := shared.map_load_from_file(entry.fullpath)
		if !loaded do continue
		defer shared.map_destroy(map_inst)
		maps += 1
		for object, index in map_inst.objects {
			if object.prefab != .RAMP do continue
			raw := object.raw_data.(json.Object)
			no_col := false
			for key in ([]string{"l", "col"}) {
				if value, ok := raw[key]; ok {
					#partial switch v in value {
					case json.Null:
					case json.Boolean: no_col ||= bool(v)
					case json.Integer: no_col ||= v != 0
					case json.Float: no_col ||= v != 0
					case: no_col = true
					}
				}
			}
			listed := false
			for collider in map_inst.collision_objects { if int(collider) == index { listed = true } }
			if no_col != (object.collision_type == .NONE) || listed == no_col || object.ramp == nil {
				fmt.eprintf("No-collision ramp test: %s ramp %v noCol=%v collision=%v indexed=%v\n", entry.name, object.position, no_col, object.collision_type, listed)
				return false
			}
			if no_col { decorative += 1 } else { solid += 1 }
		}
	}
	if maps != 48 || decorative != 359 || solid != 725 {
		fmt.eprintf("No-collision ramp coverage changed: maps=%d solid=%d decorative=%d\n", maps, solid, decorative)
		return false
	}

	site_path := shared.concat(shared.assets_path(), "maps/site.json")
	defer delete(site_path)
	site, loaded := shared.map_load_from_file(site_path)
	if !loaded {
		fmt.eprintln("No-collision ramp test: could not load Site")
		return false
	}
	defer shared.map_destroy(site)
	game := shared.Game{}
	defer shared.game_destroy(&game)
	player := ramp_test_player(&game, site)
	player.position = {108, 32, 147}
	player.last_position = player.position
	highest: f32
	for tick in 0 ..< 700 {
		ramp_test_walk(player, math.PI)
		highest = max(highest, player.position.y)
		if player.position.x < 77 && (!player.on_ground || abs(player.position.y - 42) > 0.0001) {
			fmt.eprintf("Site ramp lip test: tick %d at %v grounded=%v; the top platform is at y=42\n", tick, player.position, player.on_ground)
			return false
		}
	}
	if player.position.x > 60 || highest > 42.0101 {
		fmt.eprintf("Site ramp lip test: final %v, highest y %.4f\n", player.position, highest)
		return false
	}
	fmt.printf("No-collision ramps (%d decorative, %d solid in %d maps) and Site ramp lip OK\n", decorative, solid, maps)
	return true
}
