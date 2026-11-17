package shared

// Optional, client-consumed effects. Dedicated servers never enable this queue.
// These events do not affect simulation or go over the network.
Presentation_Kind :: enum { FIRE, RELOAD, SWAP, STEP, JUMP, LAND, SLIDE, DAMAGE, HIT, EXPLOSION }
Presentation_Event :: struct {
	kind: Presentation_Kind,
	uid, weapon_id: i32,
	position: Vec3,
	value: f32,
	headshot: bool,
	lethal: bool, // HIT only: the damage killed the victim.
	// DAMAGE only: where the attacker stood, for hit indicators.
	source: Vec3,
	has_source: bool,
}

game_emit_presentation :: proc(game: ^Game, event: Presentation_Event) {
	if game == nil || !game.presentation_enabled { return }
	if len(game.presentation_events) >= 256 { ordered_remove(&game.presentation_events, 0) }
	append(&game.presentation_events, event)
}

player_emit_presentation :: proc(player: ^Player, kind: Presentation_Kind, source: ^Player = nil) {
	if player == nil || player.game == nil || !player.game.presentation_enabled { return }
	weapon_id: i32 = -1
	if player.loadout_index >= 0 && player.loadout_index < player.loadout_size { weapon_id = player.loadout[player.loadout_index] }
	game_emit_presentation(player.game, {
		kind = kind, uid = player.uid, weapon_id = weapon_id,
		// Krunker's playerSound/playSound emit from the player's x, y, z (feet).
		position = player.position,
		value = player.crouch_val,
		source = source != nil ? source.position : {}, has_source = source != nil,
	})
}

// Kill events feed the killfeed. Unlike presentation events they are recorded
// on every authority (the native server forwards them to its clients), so the
// queue is bounded in case nothing drains it.
game_push_kill_event :: proc(game: ^Game, event: Kill_Event) {
	if game == nil { return }
	if len(game.kill_events) >= KILL_EVENTS_CAPACITY { ordered_remove(&game.kill_events, 0) }
	append(&game.kill_events, event)
}
