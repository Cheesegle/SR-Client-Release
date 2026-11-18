package main

import "core:math"
import "core:fmt"
import shared "../shared"
import kproto "../krunker"
import glfw "vendor:glfw"

// Sample independently of rendering and sending; wire durations use whole ms.
KRUNKER_INPUT_RATE :: 30
KRUNKER_INPUT_SECONDS :: 1.0 / KRUNKER_INPUT_RATE
KRUNKER_SEND_SECONDS :: 1.0 / 30.0
KRUNKER_MAX_PREDICTED_INPUTS :: 2 * KRUNKER_INPUT_RATE
// Aim samples per q packet. Movement commands stay at KRUNKER_INPUT_RATE, but
// every command holds the aim latched at the latest sample, so the packet's
// angle deltas are zero and only the absolute [pitch, yaw] anchor goes out.
// Prediction simulates the held aim too, so local and server physics match.
// 1: one anchor per packet (send rate aim). 0: every command (input rate aim).
KRUNKER_AIM_PER_PACKET :: 1

// The local player's state that advances once per physics command and that
// rendering reads: camera position and height, ADS, recoil, and the view
// model's bob, lean and step. Rendering blends the last two commands.
Krunker_Render_Sample :: struct {
	position: shared.Vec3,
	aim: f32,
	crouch_val, height: f32,
	recoil: shared.Vec3,
	recoil_anim, recoil_anim_y: f32,
	bob_anim, lean_anim: shared.Vec3,
	step_val, step_chase: f32,
	swap_timer, reload_timer: f32,
}

// A swap or reload that started during this command set its timer to the full
// duration and then counted it down by the command's delta. Blending from the
// previous command's value (0, or another weapon's timer) would play the
// animation backwards, so begin the blend from the timer's starting value.
krunker_render_restart_timers :: proc(previous: ^Krunker_Render_Sample, current: Krunker_Render_Sample, player: ^shared.Player, delta: f32) {
	if current.swap_timer > previous.swap_timer {
		previous.swap_timer = min(current.swap_timer + delta, max(player.weapon.swap_time, current.swap_timer))
		// The swap cancelled any reload; never show the old one on the new gun.
		previous.reload_timer = current.reload_timer
	} else if current.reload_timer > previous.reload_timer {
		full := player.weapon.reload_time * player.game.config.reload_speed
		previous.reload_timer = min(current.reload_timer + delta, max(full, current.reload_timer))
	}
}

krunker_render_capture :: proc(player: ^shared.Player) -> Krunker_Render_Sample {
	return {
		position = player.position, aim = player.aim_val,
		crouch_val = player.crouch_val, height = player.height,
		recoil = player.recoil, recoil_anim = player.recoil_anim, recoil_anim_y = player.recoil_anim_y,
		bob_anim = player.bob_anim, lean_anim = player.lean_anim,
		step_val = player.step_val, step_chase = player.step_chase,
		swap_timer = player.swap_timer, reload_timer = player.reload_timer,
	}
}

// Writes a sample's pose onto the player. Use only for rendering, between a
// capture of the real state and its restore.
krunker_render_apply :: proc(player: ^shared.Player, sample: Krunker_Render_Sample) {
	player.position, player.aim_val = sample.position, sample.aim
	player.crouch_val, player.height = sample.crouch_val, sample.height
	player.recoil, player.recoil_anim, player.recoil_anim_y = sample.recoil, sample.recoil_anim, sample.recoil_anim_y
	player.bob_anim, player.lean_anim = sample.bob_anim, sample.lean_anim
	player.step_val, player.step_chase = sample.step_val, sample.step_chase
	player.swap_timer, player.reload_timer = sample.swap_timer, sample.reload_timer
}

krunker_client_render_sample :: proc(client: ^Client) -> Krunker_Render_Sample {
	state := &client.krunker
	if !state.render_sample_ready { return krunker_render_capture(client.me) }
	t := clamp(f32(state.input_elapsed / KRUNKER_INPUT_SECONDS), 0, 1)
	a, b := state.render_previous, state.render_current
	return {
		position = a.position + (b.position - a.position) * t,
		aim = a.aim + (b.aim - a.aim) * t,
		crouch_val = a.crouch_val + (b.crouch_val - a.crouch_val) * t,
		height = a.height + (b.height - a.height) * t,
		recoil = a.recoil + (b.recoil - a.recoil) * t,
		recoil_anim = a.recoil_anim + (b.recoil_anim - a.recoil_anim) * t,
		recoil_anim_y = a.recoil_anim_y + (b.recoil_anim_y - a.recoil_anim_y) * t,
		bob_anim = a.bob_anim + (b.bob_anim - a.bob_anim) * t,
		lean_anim = a.lean_anim + (b.lean_anim - a.lean_anim) * t,
		step_val = a.step_val + (b.step_val - a.step_val) * t,
		step_chase = a.step_chase + (b.step_chase - a.step_chase) * t,
		swap_timer = a.swap_timer + (b.swap_timer - a.swap_timer) * t,
		reload_timer = a.reload_timer + (b.reload_timer - a.reload_timer) * t,
	}
}

krunker_client_reset_prediction :: proc(client: ^Client) {
	clear(&client.predicted_inputs)
	clear(&client.krunker.input_commands)
	client.krunker.input_elapsed = 0
	client.krunker.input_duration_remainder_ms = 0
	client.krunker.send_elapsed = 0
	client.krunker.input_swap = 0
	krunker_client_clear_latched(&client.krunker)
	client.krunker.render_sample_ready = false
	client.krunker.acked_has_ramp_fix = false
}

krunker_client_clear_latched :: proc(state: ^Krunker_WS_State) {
	state.latched_jump, state.latched_shoot, state.latched_reload, state.latched_crouch, state.latched_scope = false, false, false, false, false
	state.latched_move = false
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
	shot_time := now < 0 ? glfw.GetTime() : now
	if frame.swap != 0 { state.input_swap = frame.swap }
	look := shared.Vec2{clamp(frame.x_dir, -math.PI/2, math.PI/2), frame.y_dir}
	if !state.bootstrapped || !state.spawned {
		client.me.direction = look
		return
	}
	if !state.render_sample_ready {
		state.render_previous = krunker_render_capture(client.me)
		state.render_current = state.render_previous
		state.command_direction = client.me.direction
		state.render_sample_ready = true
	}
	// Bound catch-up after a paused/stalled window, as the browser bounds delta.
	state.input_elapsed += f64(clamp(frame.delta, 0, 0.1))
	state.send_elapsed += f64(clamp(frame.delta, 0, 0.1))
	// Queue this frame's presses for the next physics tick.
	state.latched_jump ||= frame.jump
	state.latched_shoot ||= frame.shoot
	state.latched_reload ||= frame.reload
	state.latched_crouch ||= frame.crouch
	state.latched_scope ||= frame.scope
	if frame.move_dir >= 0 { state.latched_move, state.latched_move_dir = true, frame.move_dir }
	// Frame delta originates as f32; tolerate its sub-microsecond rounding at
	// an exact command boundary without losing an entire input command.
	for state.input_elapsed + 1e-7 >= KRUNKER_INPUT_SECONDS {
		command := commands > 0 && after_scroll != nil ? after_scroll^ : frame^
		if commands == 0 {
			// The tick's first command carries every press queued since the last.
			command.jump ||= state.latched_jump
			command.shoot ||= state.latched_shoot
			command.reload ||= state.latched_reload
			command.crouch ||= state.latched_crouch
			command.scope ||= state.latched_scope
			if command.move_dir < 0 && state.latched_move { command.move_dir = state.latched_move_dir }
			krunker_client_clear_latched(state)
		}
		command.seq = state.input_sequence
		// Carry fractional milliseconds so each second of commands advances
		// exactly one second (e.g. 16.67 ms ticks go out as 17/17/16 ms).
		// 100 ms is the wire's own duration ceiling.
		duration_ms := clamp(KRUNKER_INPUT_SECONDS * 1000 * f64(client.game.config.delta_mlt), 1, 100) + state.input_duration_remainder_ms
		rounded_ms := math.round(duration_ms)
		state.input_duration_remainder_ms = duration_ms - rounded_ms
		command.delta = f32(rounded_ms) / 1000
		// As the browser: pitch.round(3), and yaw as its unbounded mouse
		// rotation % 2PI (JavaScript remainder, -2PI..2PI), then .round(3).
		// The queue's first command starts the next q packet: latch a new anchor.
		queued := len(state.input_commands)
		when KRUNKER_AIM_PER_PACKET > 1 {
			hold := max(1, int(math.round(krunker_send_seconds(state) / KRUNKER_INPUT_SECONDS / KRUNKER_AIM_PER_PACKET)))
			relatch := queued % hold == 0
		} else {
			relatch := KRUNKER_AIM_PER_PACKET == 0 || queued == 0
		}
		if relatch {
			state.aim_anchor = {
				f32(kproto.krunker_js_round_to(f64(look.x), 3)),
				f32(kproto.krunker_js_round_to(kproto.krunker_js_mod(f64(look.y), kproto.KRUNKER_PI2), 3)),
			}
		}
		command.x_dir, command.y_dir = state.aim_anchor.x, state.aim_anchor.y
		command.swap = state.input_swap
		state.input_swap = 0
		if client.krunker_world.move_lock { command.move_dir = -1; command.jump = false }
		command.krunker_shot_timed = false
		command.krunker_shot_time, command.krunker_shot_progress = 0, 0
		state.render_previous = krunker_render_capture(client.me)
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
		state.render_current = krunker_render_capture(client.me)
		krunker_render_restart_timers(&state.render_previous, state.render_current, client.me, command.delta)
		state.input_sequence += 1
		state.input_elapsed = max(0, state.input_elapsed - KRUNKER_INPUT_SECONDS)
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
	predicted_crouch := player.crouch_val
	predicted_weapon := player.weapon
	reload_timer, swap_timer := player.reload_timer, player.swap_timer
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
			player.reload_timer, player.swap_timer = reload_timer, swap_timer
			player.did_shoot, player.burst_count = did_shoot, burst_count
		}
	}
	if respawned || !state.render_sample_ready {
		state.render_previous = krunker_render_capture(player)
		state.render_current = state.render_previous
		state.command_direction = player.direction
		state.render_sample_ready = true
	} else {
		// Preserve interpolation within the current command after a correction.
		correction := player.position - predicted_position
		state.render_previous.position += correction
		state.render_current.position += correction
		// Replay can also move crouch; shift it the same way, inside 0..1.
		previous := &state.render_previous
		previous.crouch_val = clamp(previous.crouch_val + player.crouch_val - predicted_crouch, 0, 1)
		previous.height = shared.GAME_CONSTANTS.player_height - previous.crouch_val * shared.GAME_CONSTANTS.crouch_distance
		state.render_current.crouch_val, state.render_current.height = player.crouch_val, player.height
		state.prediction_corrections += 1
		error := math.sqrt(correction.x*correction.x + correction.y*correction.y + correction.z*correction.z)
		if error >= 2 || state.prediction_corrections <= 3 || state.prediction_corrections % 30 == 0 {
			pending_ms: f32
			for input in client.predicted_inputs { pending_ms += input.delta * 1000 }
			kproto.network_log("prediction", fmt.tprintf("ack=%d correction=%.3f delta=%v server_position=%v pending_commands=%d pending_ms=%.0f unsent=%d next_seq=%d", source.ack_seq, error, correction, source.position, len(client.predicted_inputs), pending_ms, len(state.input_commands), state.input_sequence))
		}
	}
}
