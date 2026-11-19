package main

import "core:math"
import "core:fmt"
import shared "../shared"
import kproto "../krunker"
import menuui "../menu"
import glfw "vendor:glfw"

// Sample independently of rendering and sending; wire durations use whole ms.
// Settings > Experimental > Inputs per second (menuui.INPUT_RATES, default 720 = Krunker's netRate 360).
KRUNKER_INPUT_RATE_DEFAULT :: 720
KRUNKER_INPUT_RATE_MAX :: 1000
g_krunker_input_rate := KRUNKER_INPUT_RATE_DEFAULT
krunker_input_seconds :: #force_inline proc() -> f64 { return 1.0 / f64(g_krunker_input_rate) }
KRUNKER_SEND_SECONDS :: 1.0 / 30.0
KRUNKER_MAX_PREDICTED_INPUTS :: 2 * KRUNKER_INPUT_RATE_MAX

Krunker_Render_Sample :: struct {
	position: shared.Vec3,
	aim: f32,
}

krunker_client_render_sample :: proc(client: ^Client) -> Krunker_Render_Sample {
	state := &client.krunker
	if !state.render_sample_ready { return {client.me.position, client.me.aim_val} }
	alpha := clamp(f32(state.input_elapsed / krunker_input_seconds()), 0, 1)
	return {
		state.render_previous.position + (state.render_current.position - state.render_previous.position) * alpha,
		state.render_previous.aim + (state.render_current.aim - state.render_previous.aim) * alpha,
	}
}

krunker_client_reset_prediction :: proc(client: ^Client) {
	clear(&client.predicted_inputs)
	clear(&client.krunker.input_commands)
	client.krunker.input_elapsed = 0
	client.krunker.input_duration_remainder_ms = 0
	client.krunker.send_elapsed = 0
	client.krunker.input_swap = 0
	client.krunker.render_sample_ready = false
	client.krunker.acked_has_ramp_fix = false
	// Fixed-clock mode: drop the commands not sent yet, keep the ids going.
	when SR_DEV { if g_net_thread.running { krunker_input_clock_reset(&g_input_clock, -1, false) } }
}

// One display frame of live input. after_scroll is the frame's command
// without its Scroll press. Returns true when the frame built no command, so
// a Scroll press must wait for the next frame instead of being dropped.
krunker_client_predict_frame :: proc(client: ^Client, frame: ^shared.Input, after_scroll: shared.Input, now: f64 = -1) -> (scroll_pending: bool) {
	rest := after_scroll
	rest.seq, rest.delta, rest.x_dir, rest.y_dir, rest.scope = frame.seq, frame.delta, frame.x_dir, frame.y_dir, frame.scope
	commands := krunker_client_predict_input(client, frame, now, &rest)
	return commands == 0 && client.krunker.bootstrapped && client.krunker.spawned
}

// Store and predict exactly the commands that q will transmit. Rendering frames
// never acquire sequence numbers or enter the authoritative replay history.
// after_scroll, when set, replaces frame for every command after the first:
// a Scroll press is held for one command, as Krunker releases key 20000
// right after the input packet that read it. Returns the commands built.
krunker_client_predict_input :: proc(client: ^Client, frame: ^shared.Input, now: f64 = -1, after_scroll: ^shared.Input = nil) -> (commands: int) {
	state := &client.krunker
	g_krunker_input_rate = int(menuui.input_rate_value(client.hud_settings.input_rate))
	shot_time := now < 0 ? glfw.GetTime() : now
	if frame.swap != 0 { state.input_swap = frame.swap }
	look := shared.Vec2{clamp(frame.x_dir, -math.PI/2, math.PI/2), frame.y_dir}
	if !state.bootstrapped || !state.spawned {
		if krunker_input_clock_active(client) { krunker_input_clock_publish(&g_input_clock, {}) }
		client.me.direction = look
		return
	}
	// Settings > Experimental > Inputs on a fixed clock (Dev build).
	if krunker_input_clock_active(client) { return krunker_client_predict_clock(client, frame, after_scroll, look) }
	if !state.render_sample_ready {
		state.render_previous = {client.me.position, client.me.aim_val}
		state.render_current = state.render_previous
		state.command_direction = client.me.direction
		state.render_sample_ready = true
	}
	// Bound catch-up after a paused/stalled window, as the browser bounds delta.
	state.input_elapsed += f64(clamp(frame.delta, 0, 0.1))
	state.send_elapsed += f64(clamp(frame.delta, 0, 0.1))
	// Frame delta originates as f32; tolerate its sub-microsecond rounding at
	// an exact command boundary without losing an entire input command.
	for state.input_elapsed + 1e-7 >= krunker_input_seconds() {
		command := commands > 0 && after_scroll != nil ? after_scroll^ : frame^
		command.seq = state.input_sequence
		// Carry fractional milliseconds so a second of commands advances exactly one second,
		// rather than 1.08 seconds from rounding every command to 3 ms.
		duration_ms := clamp(krunker_input_seconds() * 1000 * f64(client.game.config.delta_mlt), 1, 33) + state.input_duration_remainder_ms
		rounded_ms := math.round(duration_ms)
		state.input_duration_remainder_ms = duration_ms - rounded_ms
		command.delta = f32(rounded_ms) / 1000
		// As the browser: pitch.round(3), and yaw as its unbounded mouse
		// rotation % 2PI (JavaScript remainder, -2PI..2PI), then .round(3).
		command.x_dir = f32(kproto.krunker_js_round_to(f64(look.x), 3))
		command.y_dir = f32(kproto.krunker_js_round_to(kproto.krunker_js_mod(f64(look.y), kproto.KRUNKER_PI2), 3))
		command.swap = state.input_swap
		state.input_swap = 0
		if client.krunker_world.move_lock { command.move_dir = -1; command.jump = false }
		command.krunker_shot_timed = false
		command.krunker_shot_time, command.krunker_shot_progress = 0, 0
		state.render_previous = {client.me.position, client.me.aim_val}
		client.me.direction = state.command_direction
		shot_seq := client.me.shot_seq
		shared.player_proc_input(client.me, &command, true, client.krunker_world.move_lock, true, true)
		if client.me.shot_seq != shot_seq {
			kproto.krunker_input_stamp_shot(&client.krunker_world, &command, shot_time)
			when HITREG_AUDIT { if commands == 0 { hitreg_audit_shot(client, shot_time) } } // once per frame's first shot
		}
		command.predicted_ramp_fix, command.predicted_has_ramp_fix = client.me.ramp_fix, client.me.has_ramp_fix
		append(&state.input_commands, command)
		// Keep client-only impulse metadata produced by prediction for replay.
		append(&client.predicted_inputs, command)
		client_cap_predicted_inputs(client, KRUNKER_MAX_PREDICTED_INPUTS)
		state.command_direction = client.me.direction
		state.render_current = {client.me.position, client.me.aim_val}
		state.input_sequence += 1
		state.input_elapsed = max(0, state.input_elapsed - krunker_input_seconds())
		commands += 1
	}
	// Mouse look remains responsive on every display frame.
	client.me.direction = look
	return
}

krunker_client_apply_motion :: proc(client: ^Client, player: ^shared.Player, source: ^kproto.Krunker_World_Player, respawned: bool) {
	state := &client.krunker
	is_you := player.is_you
	if is_you && source.position_revision != state.local_position_revision {
		// lm is an explicit server reset, not an ACK to replay past inputs over.
		krunker_client_reset_prediction(client)
		state.input_reset = true
		state.local_position_revision = source.position_revision
		state.local_sync_revision = source.sync_revision
		player.position, player.velocity, player.direction = source.position, source.velocity, source.direction
		player.crouch_val, player.on_ground, player.on_ladder = source.crouch_val, source.on_ground, source.on_ladder
		shared.player_update_height(player)
		state.command_direction = source.direction
		return
	}
	if !is_you {
		// Remote poses are sampled from their timestamped buffer each display
		// frame. Metadata and shot packets must never snap them to the latest k.
		if respawned {
			player.position, player.direction = source.position, source.direction
			player.crouch_val, player.aim_val = source.crouch_val, source.aim_val
			player.on_ground = source.on_ground
			shared.player_update_height(player)
		}
		player.interpolate = false
		if player.loadout_index != source.weapon_slot { shared.player_swap_weapon(player, source.weapon_slot, true, true, true) }
		return
	}
	fresh_sync := source.has_ack && source.sync_revision != state.local_sync_revision
	// Roster/remote updates cannot replay an old local l snapshot.
	if is_you && !respawned && !fresh_sync { return }
	predicted_aim, predicted_aim_time := player.aim_val, player.aim_time
	predicted_direction := player.direction
	predicted_position := player.position
	predicted_weapon := player.weapon
	reload_timer_ms, swap_timer_ms := player.reload_timer_ms, player.swap_timer_ms
	did_shoot, burst_count := player.did_shoot, player.burst_count
	player.position = source.position
	player.velocity = source.velocity
	if !is_you || respawned { player.direction = source.direction }
	player.on_ground = source.on_ground
	player.on_ladder = source.on_ladder
	player.on_terrain = source.on_terrain
	player.did_jump = source.did_jump
	player.did_wall_jump = source.did_wall_jump
	player.wall_jump_count = max(source.wall_jump_count, 0)
	player.on_wall = u8(clamp(source.on_wall, 0, 255))
	player.slide_timer = source.slide_timer
	player.can_slide = source.can_slide
	player.can_slide_timer = source.can_slide_timer
	player.x_vel_cylinder, player.z_vel_cylinder = source.cylinder_velocity.x, source.cylinder_velocity.y
	player.crouch_val = clamp(source.crouch_val, 0, 1)
	player.aim_val = clamp(source.aim_val, 0, 1)
	// k/l transmit a loadout slot, not a weapon registry ID. Selecting the
	// wrong weapon also gives prediction the wrong movement multiplier.
	if player.loadout_index != source.weapon_slot { shared.player_swap_weapon(player, source.weapon_slot, true, true, true) }
	shared.player_update_height(player)
	if is_you && source.has_ack {
		state.local_sync_revision = source.sync_revision
		// l omits rampFix, the snap target that ramp contact leaves for the next
		// tick. Replaying with the newest prediction's value instead snaps a
		// player who has just left a ramp back onto it and grounds them, so a
		// held jump fires early and the next correction undoes it in Y. Use the
		// value predicted after the acknowledged command.
		for input in client.predicted_inputs {
			if input.seq > source.ack_seq { break }
			state.acked_ramp_fix, state.acked_has_ramp_fix = input.predicted_ramp_fix, input.predicted_has_ramp_fix
		}
		player.ramp_fix, player.has_ramp_fix = state.acked_ramp_fix, state.acked_has_ramp_fix
		client_discard_acked_inputs(client, source.ack_seq)
		for &input in client.predicted_inputs {
			shared.player_proc_input(player, &input, true, client.krunker_world.move_lock)
			input.predicted_ramp_fix, input.predicted_has_ramp_fix = player.ramp_fix, player.has_ramp_fix
		}
		state.input_sequence = max(state.input_sequence, source.ack_seq + 1)
	}
	if !is_you { return }
	if !respawned {
		player.direction = predicted_direction
		// View ADS follows current input, without restarting on a delayed ACK.
		if player.weapon == predicted_weapon && !player.weapon.no_aim {
			player.aim_val, player.aim_time = predicted_aim, predicted_aim_time
		}
		if player.weapon == predicted_weapon {
			player.reload_timer_ms, player.swap_timer_ms = reload_timer_ms, swap_timer_ms
			player.did_shoot, player.burst_count = did_shoot, burst_count
		}
	}
	if respawned || !state.render_sample_ready {
		state.render_previous = {player.position, player.aim_val}
		state.render_current = state.render_previous
		state.command_direction = player.direction
		state.render_sample_ready = true
	} else {
		// Preserve interpolation within the current command after a correction.
		correction := player.position - predicted_position
		state.render_previous.position += correction
		state.render_current.position += correction
		state.prediction_corrections += 1
		error := math.sqrt(correction.x*correction.x + correction.y*correction.y + correction.z*correction.z)
		when TESTER_EXPORT {
			sync_pending_ms: f32
			for input in client.predicted_inputs { sync_pending_ms += input.delta * 1000 }
			tester_export_sync(error, sync_pending_ms)
		}
		if error >= 2 || state.prediction_corrections <= 3 || state.prediction_corrections % 30 == 0 {
			pending_ms: f32
			for input in client.predicted_inputs { pending_ms += input.delta * 1000 }
			cfg := client.game.config
			kproto.network_log("prediction", fmt.tprintf("ack=%d correction=%.3f delta=%v server_position=%v pending_commands=%d pending_ms=%.0f unsent=%d next_seq=%d crouch=%.3f on_ground=%v on_wall=%d rate=%d head_clip_fix=%v ramp_fix=%v map_ramp_fix=%v", source.ack_seq, error, correction, source.position, len(client.predicted_inputs), pending_ms, len(state.input_commands), state.input_sequence, player.crouch_val, player.on_ground, player.on_wall, g_krunker_input_rate, cfg.head_clip_fix, cfg.ramp_fix, client.game.map_inst != nil && client.game.map_inst.ramp_fix))
		}
	}
}
