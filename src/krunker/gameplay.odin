package krunker

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import shared "../shared"

// All retained data is owned here, never borrowed from the decoded packet.
krunker_world_bounded_number :: proc(value: Krunker_Msgpack_Value, low, high: f64) -> (f64, bool) {
	n, ok := krunker_world_number(value)
	return n, ok && !math.is_nan(n) && !math.is_inf(n) && n >= low && n <= high
}

// END's didWin and team winner. The server's team winner is getWinTeam's
// for..in key of teamScores, so normal team endings send "1"/"2" as strings;
// draws and FFA send -1, and a winnerless forfeit sends null. The browser
// only tests these loosely (-1 ==, truthiness, == 1), so null reads as 0.
krunker_world_end_number :: proc(value: Krunker_Msgpack_Value, high: i32) -> (i32, bool) {
	#partial switch typed in value {
	case Krunker_Msgpack_Nil: return 0, true
	case string:
		n, ok := strconv.parse_int(typed, 10)
		return i32(n), ok && n >= -1 && n <= int(high)
	}
	n, ok := krunker_world_bounded_number(value, -1, f64(high))
	return i32(n), ok
}

krunker_world_parse_time :: proc(text: string) -> (f32, bool) {
	if len(text) == 0 || len(text) > 64 { return 0, false }
	seconds: f32
	part: f32
	for c in text {
		if c == ':' { seconds = seconds * 60 + part; part = 0 }
		else if c >= '0' && c <= '9' { part = part * 10 + f32(c-'0') }
		else { return 0, false }
	}
	return min(604800, seconds * 60 + part), true
}

krunker_world_set_timer_text :: proc(state: ^Krunker_World_State, value: Krunker_Msgpack_Value) -> bool {
	text, ok := value.(string)
	if !ok || len(text) > 64 { return false }
	delete(state.timer_text)
	state.timer_text = strings.clone(text)
	state.timer_received_at = state.received_at
	if seconds, valid := krunker_world_parse_time(text); valid { state.match.time_remaining = seconds }
	return true
}

krunker_world_clocks_running :: proc(state: ^Krunker_World_State) -> bool {
	return state.match.phase == .LIVE && !state.move_lock && state.countdown == .NONE
}

// Account for elapsed time under the PREVIOUS state before a packet changes
// locks or phases. Rebase even when paused so unlocking cannot eat the break.
krunker_world_rebase_clocks :: proc(state: ^Krunker_World_State) {
	if !state.has_match { return }
	if krunker_world_clocks_running(state) {
		if state.timer_kind == 0 { state.match.time_remaining = max(0, state.match.time_remaining - f32(max(0, state.received_at-state.timer_received_at))) }
		state.match.objective.rotation_remaining = max(0, state.match.objective.rotation_remaining - f32(max(0, state.received_at-state.objective_received_at)))
	}
	state.match.phase_remaining = max(0, state.match.phase_remaining - f32(max(0, state.received_at-state.lockout_received_at)))
	state.countdown_remaining = max(0, state.countdown_remaining - f32(max(0, state.received_at-state.countdown_received_at)))
	state.timer_received_at, state.objective_received_at, state.lockout_received_at, state.countdown_received_at = state.received_at, state.received_at, state.received_at, state.received_at
}

krunker_world_team_scores :: proc(target: ^[3]u32, value: Krunker_Msgpack_Value) {
	rows, ok := krunker_world_array(value); if !ok { return }
	for row in rows {
		pair, valid := krunker_world_array(row); if !valid || len(pair) < 2 { continue }
		team, team_ok := krunker_world_bounded_number(pair[0], 0, 2)
		score, score_ok := krunker_world_bounded_number(pair[1], 0, 2147483647)
		if team_ok && score_ok { target[int(team)] = u32(score) }
	}
}

krunker_world_init_match :: proc(state: ^Krunker_World_State, packet: []Krunker_Msgpack_Value) {
	state.match = {phase = .LIVE, round_current = 1, objective = {active_zone = -1, active_object_index = -1}}
	state.has_match = true
	state.game_state, state.timer_kind = 3, 0
	state.rounds_total = 1
	state.objective_uid, state.objective_occupants = -1, 0
	state.objective_weapon = -1
	clear(&state.projectile_events)
	state.move_lock = false
	state.countdown, state.countdown_remaining = .NONE, 0
	state.countdown_received_at, state.respawn_available_at = state.received_at, 0
	state.final_round_counted = false
	state.interact_progress, state.interact_manual_progress = 0, 0
	state.interact_manual_visible = false
	state.lives = 0
	state.hit_revision, state.last_hit_at = 0, 0
	state.damage_revision = 0
	state.winner_team, state.end_result = -1, -1
	state.end_received = false
	// A new match starts with an empty board until the next UPDATE_LEADERS.
	state.has_leaders = false
	state.end_index = 0
	krunker_world_clear_end(state)
	for &player in state.players { player.leader_rank = 0 }
	state.timer_received_at, state.objective_received_at, state.lockout_received_at = state.received_at, state.received_at, state.received_at
	delete(state.timer_text); state.timer_text = ""
	if len(packet) > 4 { krunker_world_team_scores(&state.match.round_wins, packet[4]) }
	if len(packet) > 5 { krunker_world_team_scores(&state.match.team_scores, packet[5]) }
	if len(packet) > 7 {
		if config, ok := packet[7].([]Krunker_Msgpack_Map_Entry); ok {
			for entry in config {
				if key, text := entry.key.(string); text && key == "gamRounds" {
					if n, valid := krunker_world_bounded_number(entry.value, 1, 10000); valid { state.rounds_total = u32(n) }
				}
			}
		}
	}
	if len(packet) > 20 { if ms, ok := krunker_world_bounded_number(packet[20], 0, 604800000); ok { state.match.time_remaining = f32(ms)/1000 } }
	if len(packet) > 22 {
		if n, valid := krunker_world_bounded_number(packet[22], 0, 5); valid {
			state.game_state = i32(n)
			state.match.phase = .WARMUP if n < 3 else (.LIVE if n == 3 else .ENDED)
		}
	}
	if len(packet) <= 12 { return }
	entries, ok := packet[12].([]Krunker_Msgpack_Map_Entry); if !ok { return }
	for entry in entries {
		key, textual := entry.key.(string); if !textual { continue }
		switch key {
		case "lck": state.move_lock = krunker_world_bool(entry.value)
		case "lockT":
			if ms, valid := krunker_world_bounded_number(entry.value, 0, 604800000); valid {
				state.match.phase_remaining = f32(ms)/1000
				if ms > 0 && state.match.phase != .ENDED { state.match.phase = .WARMUP }
			}
		case "obj":
			if args, valid := krunker_world_array(entry.value); valid { krunker_world_set_objective(state, args) }
		case "roundC":
			if n, valid := krunker_world_bounded_number(entry.value, 0, 10000); valid { state.match.round_current = state.rounds_total - min(state.rounds_total, u32(n)) }
		}
	}
}

krunker_world_set_objective :: proc(state: ^Krunker_World_State, args: []Krunker_Msgpack_Value) -> bool {
	if len(args) < 2 { return false }
	uid: f64 = -1
	if _, absent := args[0].(Krunker_Msgpack_Nil); !absent {
		n, ok := krunker_world_bounded_number(args[0], -1, 1000000); if !ok { return false }; uid = n
	}
	ms, ok := krunker_world_bounded_number(args[1], 0, 604800000); if !ok { return false }
	state.objective_uid, state.objective_occupants = i32(uid), 0
	state.objective_received_at = state.received_at
	state.match.objective = {active_object_index = -1, active_zone = -1, rotation_remaining = f32(ms)/1000}
	return true
}

krunker_world_end_lives :: proc(state: ^Krunker_World_State) {
	state.in_game = false
	state.interact_progress, state.interact_manual_progress = 0, 0
	state.interact_manual_visible = false
	for &player in state.players {
		player.active, player.life_ended = false, true
		player.pose_count = 0
		player.revision += 1
	}
}

// Browser mode.leaderStats, indexed by the server mode ID. UPDATE_LEADERS ('7')
// records are [sid, stat...] in this order, already sorted and capped at 16
// by the server's syncLeaders. Only schemas checked against the browser
// registry are listed; an unknown mode is not guessed.
KRUNKER_LEADER_STATS_FFA := [?]string{"score", "kills", "deaths"}
KRUNKER_LEADER_STATS_POINT := [?]string{"score", "objective", "kills"}
KRUNKER_LEADER_STATS_CTF := [?]string{"caps", "score"}
KRUNKER_LEADER_STATS_GUN := [?]string{"weaponTier", "kills"}
KRUNKER_LEADER_STATS_CONFIRM := [?]string{"confirms", "score", "denies"}
KRUNKER_LEADER_STATS_OBJECTIVE := [?]string{"objective", "score"}
KRUNKER_LEADER_STATS_SCORE_KILLS := [?]string{"score", "kills"}

krunker_mode_leader_stats :: proc(mode_index: i32) -> ([]string, bool) {
	switch mode_index {
	case 0, 1, 13, 21: return KRUNKER_LEADER_STATS_FFA[:], true // FFA, TDM, Classic FFA, Sharp Shooter
	case 2: return KRUNKER_LEADER_STATS_POINT[:], true // Hardpoint
	case 3: return KRUNKER_LEADER_STATS_CTF[:], true
	case 10: return KRUNKER_LEADER_STATS_GUN[:], true // Gun Game
	case 19: return KRUNKER_LEADER_STATS_CONFIRM[:], true // Kill Confirmed
	case 28, 30: return KRUNKER_LEADER_STATS_OBJECTIVE[:], true // Team Defender, Carrier
	case 33, 36: return KRUNKER_LEADER_STATS_SCORE_KILLS[:], true // Chaos Snipers, Impulsed
	}
	return nil, false
}

// Browser mode.endStats for the same modes; FFA-style modes use the default
// list. The END table's stride is the full list, including sid and name.
KRUNKER_END_STATS_DEFAULT := [?]string{"sid", "name", "score", "kills", "deaths", "reward"}
KRUNKER_END_STATS_TDM := [?]string{"sid", "name", "score", "kills", "deaths", "assists", "reward"}
KRUNKER_END_STATS_POINT := [?]string{"sid", "name", "score", "kills", "deaths", "obj", "dmg", "reward"}
KRUNKER_END_STATS_CTF := [?]string{"sid", "name", "score", "kills", "deaths", "caps", "reward"}
KRUNKER_END_STATS_GUN := [?]string{"sid", "name", "weapon", "kills", "melees", "setbacks", "reward"}
KRUNKER_END_STATS_CONFIRM := [?]string{"sid", "name", "score", "kills", "deaths", "confirms", "denies", "reward"}
KRUNKER_END_STATS_OBJECTIVE := [?]string{"sid", "name", "score", "kills", "deaths", "obj", "reward"}

krunker_mode_end_stats :: proc(mode_index: i32) -> ([]string, bool) {
	switch mode_index {
	case 0, 13, 21, 33, 36: return KRUNKER_END_STATS_DEFAULT[:], true
	case 1: return KRUNKER_END_STATS_TDM[:], true
	case 2: return KRUNKER_END_STATS_POINT[:], true
	case 3: return KRUNKER_END_STATS_CTF[:], true
	case 10: return KRUNKER_END_STATS_GUN[:], true
	case 19: return KRUNKER_END_STATS_CONFIRM[:], true
	case 28, 30: return KRUNKER_END_STATS_OBJECTIVE[:], true
	}
	return nil, false
}

krunker_world_clear_end :: proc(state: ^Krunker_World_State) {
	for entry in state.end_entries {
		delete(entry.name)
		for cell in entry.cells { delete(cell) }
	}
	clear(&state.end_entries)
	delete(state.end_timer_text)
	state.end_timer_text = ""
}

// The browser renders `ed` cells as-is (`|| 0`). Names are [name, displayName]
// pairs and skin rewards [amount, skin]; both use the first useful element.
krunker_world_end_cell :: proc(value: Krunker_Msgpack_Value, prefer_second := false) -> string {
	#partial switch typed in value {
	case string: return strings.clone(typed[:min(len(typed), 64)])
	case i64: return strings.clone(fmt.tprintf("%d", typed))
	case f64:
		if math.is_nan(typed) || math.is_inf(typed) { return strings.clone("0") }
		if typed == math.trunc(typed) && abs(typed) < 1e15 { return strings.clone(fmt.tprintf("%d", i64(typed))) }
		return strings.clone(fmt.tprintf("%.2f", typed))
	case bool: return strings.clone(typed ? "1" : "0")
	case []Krunker_Msgpack_Value:
		if prefer_second && len(typed) > 1 { if text, ok := typed[1].(string); ok && len(text) > 0 { return krunker_world_end_cell(typed[1]) } }
		if len(typed) > 0 { return krunker_world_end_cell(typed[0]) }
	}
	return strings.clone("0")
}

// Replaces the end table with END's endData.ed. Unknown schemas are ignored.
krunker_world_apply_end_table :: proc(state: ^Krunker_World_State, value: Krunker_Msgpack_Value) -> bool {
	stats, known := krunker_mode_end_stats(state.mode_index); if !known { return false }
	values, ok := krunker_world_array(value); if !ok || len(values)%len(stats) != 0 { return false }
	for offset := 0; offset < len(values); offset += len(stats) {
		if _, valid := krunker_world_bounded_number(values[offset], 0, 2147483647); !valid { return false }
	}
	for offset := 0; offset < len(values); offset += len(stats) {
		entry := Krunker_End_Entry{sid = krunker_world_i32(values[offset]), name = krunker_world_end_cell(values[offset+1], true)}
		for i in 2..<min(len(stats), KRUNKER_END_MAX_STATS+2) { entry.cells[i-2] = krunker_world_end_cell(values[offset+i]) }
		append(&state.end_entries, entry)
	}
	return true
}

krunker_world_apply_leaders :: proc(state: ^Krunker_World_State, value: Krunker_Msgpack_Value) -> bool {
	stats, known := krunker_mode_leader_stats(state.mode_index); if !known { return false }
	stride := len(stats) + 1
	score_offset, kills_offset, deaths_offset := -1, -1, -1
	for stat, i in stats {
		switch stat {
		case "score": score_offset = i + 1
		case "kills": kills_offset = i + 1
		case "deaths": deaths_offset = i + 1
		}
	}
	values, ok := krunker_world_array(value); if !ok || len(values)%stride != 0 { return false }
	// Validate the complete batch before making any changes.
	for offset := 0; offset < len(values); offset += stride {
		for i in 0..<stride { if _, valid := krunker_world_bounded_number(values[offset+i], 0, 2147483647); !valid { return false } }
	}
	// Each batch replaces the whole board: players absent from it are unranked.
	for &player in state.players { player.leader_rank = 0 }
	state.leader_stat_count = len(stats)
	state.has_leaders = true
	for offset := 0; offset < len(values); offset += stride {
		player := krunker_world_upsert_player(state, krunker_world_i32(values[offset]))
		player.leader_rank = i32(offset/stride) + 1
		for i in 0..<len(stats) { player.leader_stats[i] = krunker_world_i32(values[offset+1+i]) }
		if score_offset > 0 { player.score = u32(krunker_world_i32(values[offset+score_offset])) }
		if kills_offset > 0 { player.kills = u32(krunker_world_i32(values[offset+kills_offset])) }
		if deaths_offset > 0 { player.deaths = u32(krunker_world_i32(values[offset+deaths_offset])) }
		player.revision += 1
	}
	return true
}

krunker_world_apply_gameplay :: proc(state: ^Krunker_World_State, packet: []Krunker_Msgpack_Value, opcode: string) -> bool {
	switch opcode {
	case "gmsg":
		message := ""
		if len(packet) > 1 { text, ok := packet[1].(string); if !ok { return false }; message = strings.trim_space(text) }
		kind: Krunker_Countdown
		switch message {
		case "wt": kind = .WAITING
		case "warmup ends": kind = .WARMUP
		case "match starting in", "match starts in": kind = .STARTING
		case "intermission": kind = .INTERMISSION
		case: // Empty and objective messages clear the previous countdown.
		}
		remaining: f32
		if kind != .NONE && kind != .WAITING && len(packet) > 2 {
			text, ok := packet[2].(string); if !ok { return false }
			seconds, valid := krunker_world_parse_time(text); if !valid { return false }; remaining = seconds
		}
		state.countdown, state.countdown_remaining = kind, remaining
		state.countdown_received_at = state.received_at
		return true
	case "ts":
		if len(packet) < 2 { state.match.team_scores = {}; return true }
		if _, reset := packet[1].(Krunker_Msgpack_Nil); reset { state.match.team_scores = {}; return true }
		team, valid := krunker_world_bounded_number(packet[1], 0, 2); if !valid { return false }
		score: f64
		if len(packet) > 2 { if _, absent := packet[2].(Krunker_Msgpack_Nil); !absent { n, ok := krunker_world_bounded_number(packet[2], 0, 2147483647); if !ok { return false }; score = n } }
		state.match.team_scores[int(team)] = u32(score)
		return true
	case "t":
		if len(packet) < 2 { return false }
		kind: i32
		if len(packet) > 2 { n, ok := krunker_world_bounded_number(packet[2], 0, 3); if !ok { return false }; kind = i32(n) }
		if kind == 0 {
			if !krunker_world_set_timer_text(state, packet[1]) { return false }
			if len(packet) > 3 { if ms, ok := krunker_world_bounded_number(packet[3], 0, 604800000); ok { state.match.time_remaining = f32(ms)/1000 } }
		} else if kind == 1 {
			// "Next Round in {0}" on the end screen; it never replaces the game clock.
			text, ok := packet[1].(string); if !ok || len(text) > 64 { return false }
			delete(state.end_timer_text)
			state.end_timer_text = strings.clone(text)
		}
		state.timer_kind = kind
		return true
	case "lkt":
		if len(packet) < 2 { return false }
		ms, ok := krunker_world_bounded_number(packet[1], 0, 604800000); if !ok { return false }
		state.match.phase_remaining = f32(ms)/1000
		state.lockout_received_at = state.received_at
		state.match.phase = .WARMUP if ms > 0 else .LIVE
		return true
	case "gsc":
		if len(packet) < 2 { return false }
		n, ok := krunker_world_bounded_number(packet[1], 0, 5); if !ok { return false }
		state.game_state = i32(n)
		state.match.phase = .WARMUP if n < 3 else (.LIVE if n == 3 else .ENDED)
		if n >= 4 { krunker_world_end_lives(state) }
		return true
	case "end":
		if len(packet) < 5 { return false }
		result, ok := krunker_world_end_number(packet[2], 1); if !ok { return false }
		winner, valid := krunker_world_end_number(packet[4], 2); if !valid { return false }
		state.end_result, state.winner_team = result, winner
		state.end_received = true
		// The final normal round sends END instead of RDS. Its winner is
		// authoritative; abnormal endings (forfeit/abandon) award no extra win.
		normal_end := len(packet) <= 5
		if len(packet) > 5 { _, absent := packet[5].(Krunker_Msgpack_Nil); normal_end = absent || krunker_world_i32(packet[5], -1) == 0 }
		state.end_index = len(packet) > 5 ? krunker_world_i32(packet[5], 0) : 0
		if !state.final_round_counted && normal_end && state.rounds_total > 1 && winner >= 1 && winner <= 2 {
			state.match.round_wins[int(winner)] += 1
		}
		state.final_round_counted = true
		state.countdown = .NONE
		state.match.phase = .ENDED
		state.move_lock = true
		krunker_world_end_lives(state)
		krunker_world_clear_end(state)
		if entries, mapped := packet[3].([]Krunker_Msgpack_Map_Entry); mapped {
			for entry in entries {
				key, textual := entry.key.(string); if !textual { continue }
				if key == "tms" { krunker_world_team_scores(&state.match.team_scores, entry.value) }
				if key == "ed" { krunker_world_apply_end_table(state, entry.value) }
			}
		}
		return true
	case "obj": return krunker_world_set_objective(state, packet[1:])
	case "wep":
		// This is the objective weapon ID, not a loadout-slot change.
		if len(packet) < 2 { return false }
		id, ok := krunker_world_bounded_number(packet[1], -1, 1000000); if !ok { return false }
		state.objective_weapon = i32(id)
		return true
	case "uobj":
		if len(packet) < 3 { return false }
		uid, ok := krunker_world_bounded_number(packet[1], 0, 1000000); if !ok { return false }
		count, valid := krunker_world_bounded_number(packet[2], 0, 1000); if !valid { return false }
		if state.objective_uid == i32(uid) { state.objective_occupants = i32(count) }
		return true
	case "ulm":
		state.move_lock = false
		if state.countdown == .STARTING || state.countdown == .INTERMISSION { state.match.phase = .LIVE }
		state.countdown, state.countdown_remaining = .NONE, 0
		return true
	case "lm":
		if state.local_sid < 0 || len(packet) < 5 { return false }
		values: [4]f32
		for i in 0..<4 { n, ok := krunker_world_bounded_number(packet[i+1], -1e7, 1e7); if !ok { return false }; values[i] = f32(n) }
		player := krunker_world_upsert_player(state, state.local_sid)
		player.position, player.velocity = {values[0], values[1], values[2]}, {}
		player.position.y += 0.01 // Browser resetPosition lifts off the surface.
		player.crouch_val = 0
		player.on_ladder, player.on_terrain, player.did_jump, player.did_wall_jump = false, false, false, false
		player.on_wall = 0
		player.direction.y = values[3]
		player.has_position = true
		player.position_revision += 1
		player.revision += 1
		state.move_lock = true
		return true
	case "chgp":
		// The target is a socket ID, not a numeric simulation SID. Arguments
		// after xyz are reconcile, resetVelocity, and an optional quarter-turn.
		if len(packet) < 5 { return false }
		id, ok := packet[1].(string); if !ok { return false }
		position: shared.Vec3
		for i in 0..<3 { n, valid := krunker_world_bounded_number(packet[i+2], -1e7, 1e7); if !valid { return false }; position[i] = f32(n) }
		for &player in state.players {
			if player.socket_id != id { continue }
			player.position = position
			if len(packet) > 6 && krunker_world_bool(packet[6]) { player.velocity = {} }
			if len(packet) > 7 {
				if turn, valid := krunker_world_bounded_number(packet[7], -1000, 1000); valid { player.direction.y = -f32(turn+1)*math.PI/2 }
			}
			player.has_position = true
			player.pose_count = 0
			krunker_world_buffer_pose(&player, state.received_at)
			player.position_revision += 1
			player.revision += 1
			return true
		}
		return false
	case "rds":
		if len(packet) < 3 { return false }
		remaining, ok := krunker_world_bounded_number(packet[1], 0, 10000); if !ok { return false }
		state.match.round_current = state.rounds_total - min(state.rounds_total, u32(remaining))
		if !krunker_world_bool(packet[2]) {
			krunker_world_end_lives(state)
			state.move_lock = true
			state.countdown = .INTERMISSION
			state.match.objective.rotation_remaining = 0
		}
		if len(packet) > 4 {
			// Browser teamRoundWins is an object with string team keys.
			if entries, mapped := packet[4].([]Krunker_Msgpack_Map_Entry); mapped {
				state.match.round_wins = {}
				for entry in entries {
					team := krunker_world_i32(entry.key, -1)
					if key, text := entry.key.(string); text { if key == "1" { team = 1 } else if key == "2" { team = 2 } }
					if n, valid := krunker_world_bounded_number(entry.value, 0, 10000); valid && team >= 1 && team <= 2 { state.match.round_wins[team] = u32(n) }
				}
			}
			// Retain compatibility with servers sending an indexed array.
			if wins, valid := krunker_world_array(packet[4]); valid {
				for value, i in wins { if i < 3 { if n, valid := krunker_world_bounded_number(value, 0, 10000); valid { state.match.round_wins[i] = u32(n) } } }
			}
		}
		return true
	case "tm":
		if len(packet) < 3 { return false }
		sid, ok := krunker_world_bounded_number(packet[1], 0, 2147483647); if !ok { return false }
		team, valid := krunker_world_bounded_number(packet[2], 0, 2); if !valid { return false }
		player := krunker_world_upsert_player(state, i32(sid))
		player.team = i32(team); player.revision += 1
		if player.sid == state.local_sid {
			for &member in state.lobby_players { if member.id == state.local_connection_uid { member.team = i32(team) } }
		}
		return true
	case "7":
		if len(packet) < 2 { return false }; return krunker_world_apply_leaders(state, packet[1])
	case "4":
		// Hit confirmation is presentation only. Health arrives separately in h.
		// DO_DAMAGE (sid, damage, headshot, kill, ...). Every argument is
		// optional in the browser's handler: objects, spawnables and nukes get a
		// bare DO_DAMAGE and spectators get (sid, damage, headshot); each one
		// still plays hit_0/crit_0 and shows the hitmarker (showHit(!!kill)).
		if len(packet) > 2 {
			if _, ok := krunker_world_bounded_number(packet[2], -10000, 10000); !ok { return false }
		}
		state.last_hit_at, state.hit_headshot, state.hit_lethal = state.received_at, len(packet) > 3 && krunker_world_bool(packet[3]), len(packet) > 4 && krunker_world_bool(packet[4])
		state.hit_events[state.hit_event_next] = {state.received_at, len(packet) > 1 ? krunker_world_i32(packet[1], -1) : -1, state.hit_headshot, state.hit_lethal, len(packet) > 2 ? krunker_world_f32(packet[2]) : 0}
		state.hit_event_next = (state.hit_event_next + 1) % len(state.hit_events)
		state.hit_revision += 1
		return true
	case "6":
		// The first argument is a medal array, not the kill counter.
		if len(packet) < 4 || state.local_sid < 0 { return false }
		kills, valid := krunker_world_bounded_number(packet[3], 0, 2147483647); if !valid { return false }
		player := krunker_world_upsert_player(state, state.local_sid)
		player.kills = u32(kills); player.revision += 1
		// GET_KILL (medals, kill sound index, kills): -1 when kill rewards are
		// off. getKillSnd answers headshot_0 for every headshot kill.
		sound := krunker_world_i32(packet[2], -1)
		if sound >= 0 {
			state.kill_sound_headshot = sound == KRUNKER_HEADSHOT_SOUND_INDEX || state.hit_headshot && state.hit_lethal
			state.kill_revision += 1
		}
		return true
	case "5", "noc", "frz", "spb", "unl", "p", "mp", "lv":
		if len(packet) < 2 || state.local_sid < 0 { return false }
		n, ok := krunker_world_bounded_number(packet[1], -2147483647, 2147483647); if !ok { return false }
		if opcode == "spb" && (n < 0 || n > 1000) { return false }
		player := krunker_world_upsert_player(state, state.local_sid)
		switch opcode {
		case "5":
			if len(packet) <= 2 || !krunker_world_bool(packet[2]) {
				absolute := len(packet) > 3 && krunker_world_bool(packet[3])
				player.score = u32(clamp(n + (0 if absolute else f64(player.score)), 0, 2147483647))
			}
		case "noc": player.noclip = n != 0; player.controls_revision += 1
		case "frz": player.frozen = n != 0; player.controls_revision += 1
		case "spb":
			player.speed_boost = f32(n); player.controls_revision += 1
		case "unl": player.unlimited_ammo = n != 0; player.controls_revision += 1
		case "p": state.interact_progress = f32(clamp(n, 0, 1))
		case "mp":
			state.interact_manual_progress = f32(clamp(n, 0, 1))
			state.interact_manual_visible = n > 0 || len(packet) > 2 && krunker_world_bool(packet[2])
		case "lv": state.lives = i32(max(0, n))
		}
		player.revision += 1
		return true
	}
	return false
}

// "headshot_0" in Krunker's sound list (the index GET_KILL sends).
KRUNKER_HEADSHOT_SOUND_INDEX :: 37
