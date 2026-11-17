package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import shared "../shared"

// Exercise actual exported collision objects in isolation, so other map
// geometry cannot mask a missing collider. Use both movement entry points.
test_map_collision_drop :: proc(object: ^shared.Object, config: shared.Map_Config, predicted: bool) -> bool {
	map_inst := shared.Map{death_y = -10000, config = config}
	append(&map_inst.objects, object)
	defer delete(map_inst.objects)
	maps := []^shared.Map{&map_inst}
	game := shared.Game{}
	shared.game_configure(&game, nil, maps, nil, nil, nil)
	shared.game_init(&game, 0, 0, predicted)
	defer shared.game_destroy(&game)
	if !predicted do game.server = rawptr(&game)
	player := shared.player_init(&game)
	shared.game_players_add(&game, player)
	shared.player_spawn(player, 2)
	top := object.position.y + object.scale.y
	player.position = {object.position.x, top + 20, object.position.z}
	player.last_position = player.position
	player.velocity = {}
	player.on_ground = false
	for tick in 0 ..< 128 {
		input := shared.Input{delta = PHYSICS_DT, move_dir = -1}
		if predicted {
			shared.player_proc_input(player, &input, true, false)
		} else {
			shared.player_queue_input(player, &input)
			shared.game_tick(&game, f32(tick + 1) * PHYSICS_DT, PHYSICS_DT)
		}
	}
	if !player.on_ground || abs(player.position.y - top) > 0.01 || abs(player.velocity.y) > 0.001 {
		fmt.eprintf("Sandstorm hidden collider drop failed: object=%v predicted=%v expected_y=%f actual_y=%f grounded=%v\n",
			object.position, predicted, top, player.position.y, player.on_ground)
		return false
	}
	return true
}

// A player dropped onto the object in isolation falls straight through it.
test_map_object_falls_through :: proc(object: ^shared.Object, config: shared.Map_Config, predicted: bool) -> bool {
	map_inst := shared.Map{death_y = -10000, config = config}
	append(&map_inst.objects, object)
	defer delete(map_inst.objects)
	maps := []^shared.Map{&map_inst}
	game := shared.Game{}
	shared.game_configure(&game, nil, maps, nil, nil, nil)
	shared.game_init(&game, 0, 0, predicted)
	defer shared.game_destroy(&game)
	if !predicted do game.server = rawptr(&game)
	player := shared.player_init(&game)
	shared.game_players_add(&game, player)
	shared.player_spawn(player, 2)
	top := object.position.y + object.scale.y
	player.position = {object.position.x, top + 20, object.position.z}
	player.last_position = player.position
	player.velocity = {}
	player.on_ground = false
	for tick in 0 ..< 128 {
		input := shared.Input{delta = PHYSICS_DT, move_dir = -1}
		if predicted {
			shared.player_proc_input(player, &input, true, false)
		} else {
			shared.player_queue_input(player, &input)
			shared.game_tick(&game, f32(tick + 1) * PHYSICS_DT, PHYSICS_DT)
		}
	}
	if player.position.y > object.position.y - 1 {
		fmt.eprintf("Non-solid %v at %v stopped a falling player: predicted=%v y=%f grounded=%v\n", object.prefab, object.position, predicted, player.position.y, player.on_ground)
		return false
	}
	return true
}

// Krunker marks SIGN, SHOWCASE and RUNE noCol. Site's four site-label signs
// are drawn by neither client here, so as solid boxes they were invisible
// slabs players could stand on. Hidden (`v`) cubes stay solid, as in Krunker,
// where `v` only skips the mesh.
test_site_signs_not_solid :: proc() -> bool {
	path := shared.concat(shared.assets_path(), "maps/site.json")
	defer delete(path)
	map_inst, loaded := shared.map_load_from_file(path)
	if !loaded {
		fmt.eprintln("Site collision test: could not load map")
		return false
	}
	defer shared.map_destroy(map_inst)

	signs, hidden := 0, 0
	for object in map_inst.objects {
		#partial switch object.prefab {
		case .SIGN, .SHOWCASE, .RUNE:
			if object.collision_type != .NONE {
				fmt.eprintf("Site collision test: %v at %v is solid\n", object.prefab, object.position)
				return false
			}
			if object.prefab == .SIGN {
				signs += 1
				if !test_map_object_falls_through(object, map_inst.config, true) || !test_map_object_falls_through(object, map_inst.config, false) {
					return false
				}
			}
		case .CUBE:
			raw := object.raw_data.(json.Object)
			if "v" in raw && !("l" in raw || "col" in raw) {
				hidden += 1
				if object.collision_type != .BOX {
					fmt.eprintf("Site collision test: hidden cube at %v lost its collision\n", object.position)
					return false
				}
			}
		}
	}
	if signs != 4 || hidden != 7 {
		fmt.eprintf("Site collision coverage changed: signs=%d hidden cubes=%d\n", signs, hidden)
		return false
	}
	fmt.println("Site signs non-solid / hidden cubes solid OK")
	return true
}

test_sandstorm_hidden_colliders :: proc() -> bool {
	path := shared.concat(shared.assets_path(), "maps/sandstorm_v3.json")
	defer delete(path)
	map_inst, loaded := shared.map_load_from_file(path)
	if !loaded {
		fmt.eprintln("Sandstorm collision test: could not load map")
		return false
	}
	defer shared.map_destroy(map_inst)

	hidden_count, drop_count, decoration_count := 0, 0, 0
	for object in map_inst.objects {
		if object.prefab != .CUBE do continue
		raw := object.raw_data.(json.Object)
		if "l" in raw || "col" in raw {
			if object.collision_type != .NONE {
				fmt.eprintf("Sandstorm collision test: decoration became solid at %v\n", object.position)
				return false
			}
			decoration_count += 1
			continue
		}
		if !("v" in raw) do continue
		hidden_count += 1
		if !object.is_border {
			if !test_map_collision_drop(object, map_inst.config, true) || !test_map_collision_drop(object, map_inst.config, false) {
				return false
			}
			drop_count += 1
		}
		if object.collision_type != .BOX {
			fmt.eprintf("Sandstorm collision test: hidden block lost its collision at %v\n", object.position)
			return false
		}
	}
	if hidden_count != 46 || drop_count != 4 || decoration_count != 681 {
		fmt.eprintf("Sandstorm collision coverage changed: hidden=%d drop=%d decoration=%d\n", hidden_count, drop_count, decoration_count)
		return false
	}
	fmt.println("Sandstorm hidden collider landing/prediction/authority tests OK")
	return true
}

Collision_Trace_State :: struct {
	position, velocity: shared.Vec3,
	ramp_fix: f32,
	has_ramp_fix, on_ramp, on_ground: bool,
}

// Replays a recorded movement trace on a fresh player. With full_scan the map
// is treated as unindexed, so collision walks every object as it used to.
collision_trace :: proc(map_inst: ^shared.Map, name: string, full_scan: bool) -> (states: [dynamic]Collision_Trace_State, matches_recording: bool) {
	path := fmt.tprintf("%ssrc/tests/inputs/%s", project_root(), name)
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil do return
	json_val, parse_err := json.parse_string(string(data))
	if parse_err != .None do return
	defer json.destroy_value(json_val)
	ticks_arr, arr_ok := json_val.(json.Array)
	if !arr_ok || len(ticks_arr) == 0 do return
	ticks := make([]Tick, len(ticks_arr))
	defer {
		for tick in ticks { if tick.expected.ramp_fix != nil { free(tick.expected.ramp_fix) } }
		delete(ticks)
	}
	for raw, i in ticks_arr {
		ok: bool
		ticks[i], ok = parse_tick(raw)
		if !ok do return
	}

	indexed := map_inst.collision_indexed
	map_inst.collision_indexed = !full_scan
	defer map_inst.collision_indexed = indexed
	maps := []^shared.Map{map_inst}
	game := shared.Game{}
	shared.game_configure(&game, nil, maps, nil, nil, nil)
	shared.game_init(&game, 0, -1, true)
	defer shared.game_destroy(&game)
	player := shared.player_init(&game)
	shared.game_players_add(&game, player)
	shared.player_spawn(player)
	player.position = ticks[0].expected.position

	matches_recording = true
	for &tick, i in ticks {
		if matches_recording && !validate_tick(player, &tick.expected, i) { matches_recording = false }
		shared.player_proc_input(player, &tick.input, false, false)
		append(&states, Collision_Trace_State{player.position, player.velocity, player.ramp_fix, player.has_ramp_fix, player.on_ramp, player.on_ground})
	}
	return
}

// The collidable-object index must leave movement bit-for-bit unchanged,
// including ramp contact (walk_ramp) and order-dependent wall resolution.
test_collision_index_matches_full_scan :: proc() -> bool {
	path := fmt.tprintf("%ssrc/tests/fixtures/maps/sandstorm.json", project_root())
	map_inst, loaded := shared.map_load_from_file(path)
	if !loaded {
		fmt.eprintln("Collision index test: could not load sandstorm fixture")
		return false
	}
	defer shared.map_destroy(map_inst)
	no_collision := 0
	for obj in map_inst.objects { if obj.collision_type == .NONE { no_collision += 1 } }
	ordered := true
	for i in 1 ..< len(map_inst.collision_objects) { ordered &&= map_inst.collision_objects[i-1] < map_inst.collision_objects[i] }
	if !map_inst.collision_indexed || !ordered || len(map_inst.collision_objects) + no_collision != len(map_inst.objects) {
		fmt.eprintf("Collision index test: index must list every colliding object once, in map order (indexed=%v ordered=%v listed=%d none=%d total=%d)\n",
			map_inst.collision_indexed, ordered, len(map_inst.collision_objects), no_collision, len(map_inst.objects))
		return false
	}
	traces := []string{"walk_ramp.json", "collide.json", "walk_ladder.json", "jump.json"}
	for name in traces {
		indexed, indexed_ok := collision_trace(map_inst, name, false)
		defer delete(indexed)
		full, _ := collision_trace(map_inst, name, true)
		defer delete(full)
		ramp_ticks := 0
		for state in indexed { if state.has_ramp_fix { ramp_ticks += 1 } }
		if !indexed_ok || len(indexed) == 0 || len(indexed) != len(full) || (name == "walk_ramp.json" && ramp_ticks == 0) {
			fmt.eprintf("Collision index test: %s failed to replay (matches_recording=%v ticks=%d/%d ramp_ticks=%d)\n", name, indexed_ok, len(indexed), len(full), ramp_ticks)
			return false
		}
		for state, i in indexed {
			if state != full[i] {
				fmt.eprintf("Collision index test: %s diverged at tick %d: indexed=%v full=%v\n", name, i, state, full[i])
				return false
			}
		}
	}
	fmt.println("Collision index matches full scan OK")
	return true
}
