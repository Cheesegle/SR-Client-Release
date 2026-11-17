package main

import shared "../shared"
import kproto "../krunker"
import "core:fmt"

krunker_client_live_class_window :: proc(client: ^Client, now: f64) -> bool {
	world := &client.krunker_world
	if !client.krunker.connected || !(world.is_comp || world.is_ranked) { return false }
	if world.countdown == .WAITING { return true }
	return (world.countdown == .WARMUP || world.countdown == .INTERMISSION) &&
		world.countdown_remaining > f32(max(0, now-world.countdown_received_at))
}

// Comp servers refuse `cd` team/class changes once the game is in progress and
// say so with chi "ranked.progress" ("Game in Progress") or "ranked.switch"
// ("Can't switch while in-game"). The roster class stays authoritative and is
// what the next START equips, so drop the refused pick instead of waiting for it.
krunker_client_apply_notice :: proc(client: ^Client, packet: []kproto.Krunker_Msgpack_Value) {
	if len(packet) < 4 { return }
	key, ok := packet[3].(string)
	if !ok || key != "ranked.progress" && key != "ranked.switch" { return }
	server_class: i32 = -1
	for player in client.krunker_world.lobby_players {
		if player.id == client.krunker_world.local_connection_uid { server_class = player.class_index }
	}
	if server_class < 0 {
		for player in client.krunker_world.players {
			if player.sid == client.krunker_world.local_sid { server_class = player.class_index }
		}
	}
	if client.team_pending {
		client.team_pending, client.requested_team = false, client.lobby_team
	}
	if server_class < 0 || int(server_class) >= len(client.game.classes) || server_class == client.selected_class { return }
	client.selected_class = server_class
	client.krunker.class_index = server_class
	client.krunker.secondary_index = client_secondary_request(client, server_class)
	client_selection_status(client, fmt.tprintf("%s; keeping %s.", key == "ranked.switch" ? "Can't switch while in-game" : "Game in Progress", client.game.classes[server_class].name))
}

krunker_client_respawn_remaining :: proc(client: ^Client, now: f64) -> f32 {
	if !client.krunker.connected { return 0 }
	return f32(max(0, client.krunker_world.respawn_available_at-now))
}

krunker_client_countdown_label :: proc(client: ^Client, now: f64) -> string {
	if !client.krunker.connected { return "" }
	world := &client.krunker_world
	remaining := max(0, int(world.countdown_remaining-f32(max(0, now-world.countdown_received_at))+0.999))
	switch world.countdown {
	case .WAITING: return "Waiting for players"
	case .WARMUP: return fmt.tprintf("Warmup ends in %02d:%02d", remaining/60, remaining%60)
	case .STARTING: return fmt.tprintf("Match starts in %02d:%02d", remaining/60, remaining%60)
	case .INTERMISSION: return fmt.tprintf("Intermission %02d:%02d", remaining/60, remaining%60)
	case .NONE:
	}
	return ""
}

krunker_client_apply_metadata :: proc(client: ^Client, player: ^shared.Player, source: ^kproto.Krunker_World_Player) {
	if source.health < player.health { shared.player_emit_presentation(player, .DAMAGE) }
	player.health, player.max_health = source.health, i32(source.max_health)
	player.score, player.kills, player.deaths = source.score, source.kills, source.deaths
	if source.controls_revision > 0 {
		player.noclip, player.frozen, player.unlimited_ammo = source.noclip, source.frozen, source.unlimited_ammo
		player.speed_boost = source.speed_boost
	}
	if player.is_you { player.interact_progress = client.krunker_world.interact_progress }
}

krunker_client_timer_label :: proc(client: ^Client) -> string {
	world := &client.krunker_world
	if client.krunker.connected && world.has_match && world.timer_kind != 0 && len(world.timer_text) > 0 { return world.timer_text }
	remaining := max(0, int(client.game.match.time_remaining + 0.999))
	return fmt.tprintf("%02d:%02d", remaining/60, remaining%60)
}

// Advance display clocks from the last server value. Never run local scoring,
// objective rotation, overtime, or round transitions for a live socket.
krunker_client_sync_match :: proc(client: ^Client, now: f64) {
	world := &client.krunker_world
	if !world.has_match { return }
	client.game.match = world.match
	match := &client.game.match
	if kproto.krunker_world_clocks_running(world) {
		if world.timer_kind == 0 { match.time_remaining = max(0, match.time_remaining - f32(max(0, now-world.timer_received_at))) }
		match.objective.rotation_remaining = max(0, match.objective.rotation_remaining - f32(max(0, now-world.objective_received_at)))
	}
	if match.phase == .WARMUP { match.phase_remaining = max(0, match.phase_remaining - f32(max(0, now-world.lockout_received_at))) }
	match.objective.active_object_index, match.objective.active_zone = -1, -1
	if client.game.map_inst == nil { return }
	for index in client.game.objective_indices {
		object := client.game.map_inst.objects[index]
		if object.objective_id != world.objective_uid { continue }
		match.objective.active_object_index, match.objective.active_zone = index, object.objective_id
		// uobj contains occupant count, never a team ID. Team ownership cannot
		// be inferred from this message.
		match.objective.contested = client.game.mode != nil && !client.game.mode.config.teams && world.objective_occupants > 1
		break
	}
}

krunker_client_match_reason :: proc(client: ^Client) -> string {
	world := &client.krunker_world
	if !client.krunker.connected || !world.has_match { return "" }
	if world.match.phase == .ENDED {
		if world.timer_kind == 3 { return "Match abandoned; waiting for the next round" }
		return "Match over; waiting for the next round"
	}
	return ""
}

