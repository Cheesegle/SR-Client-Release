package krunker

import "core:math"
import "core:fmt"
import shared "../shared"

KRUNKER_MAX_INPUT_BATCH :: 32

krunker_display_time :: proc(now: f64, send_rate: f32) -> f64 {
	return now - 1/f64(send_rate > 0 ? send_rate : 10)
}

krunker_input_stamp_shot :: proc(state: ^Krunker_World_State, input: ^shared.Input, now: f64) {
	input.krunker_shot_timed = false
	input.krunker_shot_time, input.krunker_shot_progress = 0, 0
	if !state.has_server_time { return }
	input.krunker_shot_timed = true
	input.krunker_shot_time = state.server_time
	if state.has_previous_sync && state.sync_received_at > state.previous_sync_received_at {
		display_time := krunker_display_time(now, state.send_rate)
		progress := (display_time-state.sync_received_at) / (state.previous_sync_received_at-state.sync_received_at)
		// Keep the browser's negative progress after a late snapshot: the server
		// clamps it to zero. Sending/omitting zero would retain its OLD progress
		// because that receiver only applies truthy values. Cap the older end to
		// match our renderer's held pose. Timing keys use two decimal places.
		input.krunker_shot_progress = krunker_js_round_to(min(progress, 1), 2) // .round(2), JavaScript halves
		// A zero is not applied by Krunker's receiver, which then keeps the
		// PREVIOUS shot's progress (up to a whole snapshot off). 0.01 is the
		// nearest value it does apply (about a millisecond).
		if input.krunker_shot_progress == 0 { input.krunker_shot_progress = 0.01 }
	}
}

// Native forward is 0 (-PI/2); the browser's direction table starts at
// -3PI/4, so its forward is 1. Keep -1 as the no-movement sentinel.
krunker_input_move_direction :: proc(direction: i32) -> i32 {
	return direction < 0 ? -1 : (direction + 1) % 8
}

// JavaScript's Math.round: halves round up (toward +infinity), so -2.5 -> -2.
// Odin's math.round rounds them away from zero.
krunker_js_round :: proc(x: f64) -> f64 {
	r := math.floor(x)
	return x - r >= 0.5 ? r + 1 : r
}

// Number.prototype.round(n) in Krunker: Math.round(x * 10^n) / 10^n.
krunker_js_round_to :: proc(x: f64, places: int) -> f64 {
	scale := math.pow(10, f64(places))
	return krunker_js_round(x * scale) / scale
}

// JavaScript's % on numbers: the remainder keeps the dividend's sign.
krunker_js_mod :: proc(x, y: f64) -> f64 {
	return math.mod(x, y)
}

// Krunker's Math.PI2.
KRUNKER_PI2 :: 2 * math.PI

// The q control fields 4..14, in order: move direction, shoot, aim, jump,
// reload, crouch, scroll swap, weapon swap, 1 - speed limit, reset, interact.
KRUNKER_INPUT_CONTROLS :: 11

// What the browser's input compressor remembers between q packets: the last
// value it sent for each control (v85958; cleared to "unknown" on game start
// and INPUT_FAILED) and the last angle array it sent (v85964).
Krunker_Input_Wire :: struct {
	controls:      [KRUNKER_INPUT_CONTROLS]i64,
	controls_sent: [KRUNKER_INPUT_CONTROLS]bool,
	angles:        [KRUNKER_MAX_INPUT_BATCH * 2]i64,
	angle_count:   int,
}

// The browser's q packet, built exactly as its input compressor builds it:
//
//	["q", reset, firstSeq, durations, width, angles?, controls?, timing?]
//
//   - durations: every command's duration in ms as one string of digits when
//     all have the same number of digits (width = that number), else an array
//     of numbers with width 0.
//   - angles: [pitch, yaw] of the first command, then per-command deltas, all
//     x1000. Cut to the first pair when every delta is 0; sent as 0 when equal
//     to the previous packet's array (compared over this array's length).
//   - controls: {"i-f": value} for each control f (4..14) of command i whose
//     value differs from the last one sent, or is not known yet.
//   - timing: {"i": serverTime, "ip": progress} for commands that fired.
//
// Angles go only when there is timing, a changed control, or new angles;
// controls (0 when none changed) only with timing or a changed control;
// timing only when a command fired.
//
// wire is the compressor's memory before this packet (nil: a fresh one);
// next receives it after. Encoding has no side effects: commit next only
// once the packet was really sent.
krunker_input_encode_batch :: proc(inputs: []shared.Input, counter: u8, move_lock: bool, reset: bool = false, wire: ^Krunker_Input_Wire = nil, next: ^Krunker_Input_Wire = nil) -> ([]byte, bool) {
	if len(inputs) == 0 || len(inputs) > KRUNKER_MAX_INPUT_BATCH { return nil, false }
	state: Krunker_Input_Wire
	if wire != nil { state = wire^ }

	durations: [KRUNKER_MAX_INPUT_BATCH]i64
	angles: [KRUNKER_MAX_INPUT_BATCH * 2]i64
	controls: [KRUNKER_MAX_INPUT_BATCH * KRUNKER_INPUT_CONTROLS]Krunker_Msgpack_Map_Entry
	control_keys: [KRUNKER_MAX_INPUT_BATCH * KRUNKER_INPUT_CONTROLS][12]byte
	control_count: int
	shot_index: [KRUNKER_MAX_INPUT_BATCH]int
	shot_time, shot_progress: [KRUNKER_MAX_INPUT_BATCH]f64
	shot_count: int
	previous_pitch, previous_yaw: i64
	for input, i in inputs {
		if input.seq != inputs[0].seq + i32(i) { return nil, false }
		if input.krunker_shot_timed {
			// The browser sends progress as .round(2): the double nearest its
			// two-decimal value. Stamped values already are; this keeps any
			// other source exact too.
			shot_index[shot_count], shot_time[shot_count], shot_progress[shot_count] = i, input.krunker_shot_time, krunker_js_round_to(f64(input.krunker_shot_progress), 2)
			shot_count += 1
		}
		durations[i] = i64(clamp(krunker_js_round(f64(input.delta) * 1000), 1, 100))
		pitch := i64(krunker_js_round(1000 * krunker_js_round_to(f64(input.x_dir), 3)))
		yaw := i64(krunker_js_round(1000 * krunker_js_round_to(f64(input.y_dir), 3)))
		if i == 0 {
			angles[0], angles[1] = pitch, yaw
		} else {
			angles[2*i], angles[2*i+1] = pitch - previous_pitch, yaw - previous_yaw
		}
		previous_pitch, previous_yaw = pitch, yaw
		move := move_lock ? -1 : krunker_input_move_direction(input.move_dir)
		values := [KRUNKER_INPUT_CONTROLS]i64{i64(move), i64(input.shoot), i64(input.scope), i64(input.jump && !move_lock), i64(input.reload), i64(input.crouch), 0, i64(input.swap), 0, 0, 0}
		for value, field in values {
			if state.controls_sent[field] && state.controls[field] == value { continue }
			state.controls[field], state.controls_sent[field] = value, true
			key := fmt.bprintf(control_keys[control_count][:], "%d-%d", i, field+4)
			controls[control_count] = {key, value}
			control_count += 1
		}
	}

	// Durations: one digit string when every duration has the same width.
	digits: [KRUNKER_MAX_INPUT_BATCH * 3]byte
	digit_count, width := 0, 0
	for d, i in durations[:len(inputs)] {
		text := fmt.bprintf(digits[digit_count:], "%d", d)
		if i == 0 { width = len(text) } else if len(text) != width { width = 0; break }
		digit_count += len(text)
	}
	duration_values: [KRUNKER_MAX_INPUT_BATCH]Krunker_Msgpack_Value
	duration_arg: Krunker_Msgpack_Value
	if width > 0 {
		duration_arg = string(digits[:digit_count])
	} else {
		for d, i in durations[:len(inputs)] { duration_values[i] = d }
		duration_arg = duration_values[:len(inputs)]
	}

	// Angles: drop all-zero deltas; 0 when unchanged since the last packet.
	angle_count := len(inputs) * 2
	if angle_count > 2 {
		moved := false
		for v in angles[2:angle_count] { if v != 0 { moved = true; break } }
		if !moved { angle_count = 2 }
	}
	same := true
	for v, i in angles[:angle_count] {
		if i >= state.angle_count || state.angles[i] != v { same = false; break }
	}
	copy(state.angles[:], angles[:angle_count])
	state.angle_count = angle_count
	angle_values: [KRUNKER_MAX_INPUT_BATCH * 2]Krunker_Msgpack_Value
	for v, i in angles[:angle_count] { angle_values[i] = v }

	// Timing: a JavaScript object enumerates integer keys ("0", "1") first,
	// in ascending order, then the others ("0p") in insertion order.
	timing: [KRUNKER_MAX_INPUT_BATCH * 2]Krunker_Msgpack_Map_Entry
	timing_keys: [KRUNKER_MAX_INPUT_BATCH * 2][12]byte
	timing_count: int
	for s in 0 ..< shot_count {
		timing[timing_count] = {fmt.bprintf(timing_keys[timing_count][:], "%d", shot_index[s]), shot_time[s]}
		timing_count += 1
	}
	for s in 0 ..< shot_count {
		if shot_progress[s] == 0 { continue } // the browser omits a zero progress
		timing[timing_count] = {fmt.bprintf(timing_keys[timing_count][:], "%dp", shot_index[s]), shot_progress[s]}
		timing_count += 1
	}

	args: [7]Krunker_Msgpack_Value
	args[0], args[1], args[2], args[3] = i64(reset), i64(inputs[0].seq), duration_arg, i64(width)
	count := 4
	timed, changed := shot_count > 0, control_count > 0
	if timed || changed || (angle_count > 0 && !same) {
		args[count] = same ? Krunker_Msgpack_Value(i64(0)) : Krunker_Msgpack_Value(angle_values[:angle_count])
		count += 1
	}
	if timed || changed {
		args[count] = changed ? Krunker_Msgpack_Value(controls[:control_count]) : Krunker_Msgpack_Value(i64(0))
		count += 1
	}
	if timed {
		args[count] = timing[:timing_count]
		count += 1
	}
	packet, ok := krunker_msgpack_encode_packet("q", args[:count], counter)
	if ok && next != nil { next^ = state }
	return packet, ok
}

// Single-command compatibility helper for bootstrap/protocol checks.
krunker_input_encode :: proc(input: ^shared.Input, elapsed_ms: i32, counter: u8, move_lock: bool) -> ([]byte, bool) {
	command := input^
	command.delta = f32(clamp(elapsed_ms, 1, 100)) / 1000
	return krunker_input_encode_batch(([]shared.Input{command}), counter, move_lock)
}
