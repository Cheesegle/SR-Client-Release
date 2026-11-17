package main

import "core:encoding/json"
import "core:fmt"
import "core:path/filepath"
import "core:strings"

import shared "../shared"

// Krunker's loader (Krunker's client):
//   O=="OBJECTIVE" ? this.manager.addObjective(G,J,ee,le,M,xe,{objId:parseInt(s.obi)||0})
//   addObjective(x,y,z,w,l,h,S): uid = S.objId ? clamp(objId,1,10)-1 : next free uid;
//     objectives.push({uid, x, z, y: y+h/2, width: w/2, length: l/2, height: h/2})
//   marker: addCube(x,y,z,w,5,l,{src:"objective_4"}), visible only while its uid is active
//   getNextObjective: the objective whose uid == activeObjective+1, else uid 0.
// Frontier authors its four sites out of object order (obi 2,1,4,3).

@(private = "file")
Frontier_Site :: struct {
	obi:      i32,
	position: shared.Vec3,
	scale:    shared.Vec3,
}

// Straight from assets/maps/frontier.json (`p`, and `xyz[si]` for the size).
@(private = "file")
FRONTIER_SITES := [4]Frontier_Site{
	{2, {-346, 200, 336}, {83, 35, 56}},
	{1, {208, 210, -140}, {81, 37, 70}},
	{4, {-342, 210, -195}, {69, 37, 83}},
	{3, {124, 196, 234}, {96, 35, 45}},
}

@(private = "file")
objective_site_fail :: proc(format: string, args: ..any) -> bool {
	fmt.eprint("Objective sites: ")
	fmt.eprintfln(format, ..args)
	return false
}

@(private = "file")
objective_site_game :: proc(game: ^shared.Game, map_inst: ^shared.Map) {
	config := shared.DEFAULT_GAME_CONFIG
	config.objective_rotation_time = 60
	config.objective_score_rate = 1
	maps := []^shared.Map{map_inst}
	shared.game_configure(game, &config, maps, nil, nil, nil)
	shared.game_init(game, 0, 0, true)
}

test_frontier_objective_sites :: proc() -> bool {
	map_path := fmt.tprintf("%sassets/maps/frontier.json", project_root())
	map_inst, ok := shared.map_load_from_file(map_path)
	if !ok do return objective_site_fail("frontier.json did not load")
	defer shared.map_destroy(map_inst)

	// Positions, sizes and IDs.
	found := 0
	for object in map_inst.objects {
		if !object.objective do continue
		if found >= len(FRONTIER_SITES) do return objective_site_fail("Frontier has more than four sites")
		want := FRONTIER_SITES[found]
		found += 1
		if object.prefab != .OBJECTIVE || object.collision_type != .BOX {
			return objective_site_fail("site %d is not an objective capture box", want.obi)
		}
		if object.position != want.position || object.scale != want.scale {
			return objective_site_fail("site obi=%d at %v size %v, want %v size %v", want.obi, object.position, object.scale, want.position, want.scale)
		}
		if object.objective_id != want.obi - 1 {
			return objective_site_fail("site at %v has uid %d, Krunker gives obi-1 = %d", object.position, object.objective_id, want.obi - 1)
		}
	}
	if found != len(FRONTIER_SITES) do return objective_site_fail("Frontier has %d sites, want 4", found)

	game := shared.Game{}
	objective_site_game(&game, map_inst)
	defer shared.game_destroy(&game)
	if len(game.objective_indices) != 4 do return objective_site_fail("game found %d sites", len(game.objective_indices))

	player := shared.player_init(&game)
	player.team = 1
	shared.game_players_add(&game, player)
	shared.player_spawn(player)

	// Rotation: uid 0 (obi 1) first, then 1, 2, 3 and back to 0.
	now: f32 = 0
	for step in 0 ..< 5 {
		state := &game.match.objective
		uid := i32(step % 4)
		if state.active_zone != uid {
			return objective_site_fail("rotation step %d is on uid %d, want %d", step, state.active_zone, uid)
		}
		zone := map_inst.objects[state.active_object_index]
		want := FRONTIER_SITES[0]
		for site in FRONTIER_SITES { if site.obi - 1 == uid do want = site }
		if zone.objective_id != uid || zone.position != want.position {
			return objective_site_fail("active uid %d resolved to the site at %v, want %v", uid, zone.position, want.position)
		}

		// Capture works when standing inside the site (on its floor, at its
		// center) and not just outside its edge.
		player.position = zone.position
		before := game.match.team_scores[1]
		now += 1.25; shared.game_tick(&game, now, 1.25)
		if state.owner_team != 1 || game.match.team_scores[1] <= before {
			return objective_site_fail("standing inside uid %d at %v does not capture", uid, zone.position)
		}
		player.position = zone.position + {zone.scale.x * 0.5 + player.scale + 1, 0, 0}
		now += 0.05; shared.game_tick(&game, now, 0.05)
		if state.owner_team != 0 {
			return objective_site_fail("standing outside uid %d still captures", uid)
		}
		player.position = zone.position + {0, zone.scale.y + 1, 0}
		player.velocity = {}
		now += 0.05; shared.game_tick(&game, now, 0.05)
		if state.owner_team != 0 {
			return objective_site_fail("standing above uid %d still captures", uid)
		}

		shared.game_rotate_objective(&game)
	}

	fmt.println("Frontier objective site tests OK")
	return test_objective_sites_all_maps()
}

// Every bundled map: uids follow `obi` (or Krunker's next-free rule), are
// unique, and the rotation walks them in uid order. Lists the maps whose
// authored order differs from their object order.
test_objective_sites_all_maps :: proc() -> bool {
	pattern := fmt.tprintf("%sassets/maps/*.json", project_root())
	paths, glob_err := filepath.glob(pattern, context.temp_allocator)
	if glob_err != nil || len(paths) == 0 do return objective_site_fail("no maps found at %s", pattern)

	reordered: [dynamic]string
	defer delete(reordered)
	maps_with_sites := 0
	for path in paths {
		map_inst, ok := shared.map_load_from_file(path)
		if !ok do continue
		defer shared.map_destroy(map_inst)

		uids: [dynamic]i32
		defer delete(uids)
		in_object_order := true
		for object in map_inst.objects {
			if !object.objective do continue
			want := i32(len(uids))
			if raw, is_object := object.raw_data.(json.Object); is_object {
				if obi, has := raw["obi"]; has {
					if n := i32(shared.get_json_f32(obi)); n != 0 do want = clamp(n, 1, 10) - 1
				}
			}
			if object.objective_id != want {
				return objective_site_fail("%s: site at %v has uid %d, want %d", filepath.base(path), object.position, object.objective_id, want)
			}
			for uid in uids {
				if uid == want do return objective_site_fail("%s: duplicate uid %d", filepath.base(path), want)
			}
			if want != i32(len(uids)) do in_object_order = false
			append(&uids, want)
		}
		if len(uids) == 0 do continue
		maps_with_sites += 1
		if !in_object_order do append(&reordered, strings.trim_suffix(filepath.base(path), ".json"))

		game := shared.Game{}
		objective_site_game(&game, map_inst)
		defer shared.game_destroy(&game)
		for step in 0 ..< len(uids) {
			uid := game.match.objective.active_zone
			if uid != i32(step) || map_inst.objects[game.match.objective.active_object_index].objective_id != uid {
				return objective_site_fail("%s: rotation step %d is on uid %d", filepath.base(path), step, uid)
			}
			shared.game_rotate_objective(&game)
		}
		if game.match.objective.active_zone != 0 {
			return objective_site_fail("%s: rotation does not wrap back to uid 0", filepath.base(path))
		}
	}
	fmt.printfln("Objective sites OK on %d maps; authored out of object order: %v", maps_with_sites, reordered[:])
	return true
}
