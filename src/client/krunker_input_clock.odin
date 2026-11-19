package main

import "core:math"
import "core:sync"
import shared "../shared"
import kproto "../krunker"
import menuui "../menu"

// Inputs on a fixed clock (Settings > Experimental, Dev build): live input
// commands are built on the network thread every 1/input-rate seconds, so a
// slow or stalled frame never moves a command's boundary or its shot time.
// The design follows aashten's KrunkNative-Odin network thread (f649802),
// adapted to SR:
//
// - Game thread: publishes what it read this frame (keys, buttons, view
//   direction) as the source, pulls the commands the network thread built,
//   predicts them on the local player exactly as sent, and writes each one's
//   shot stamp (inputSTime / progress, which needs the prediction) back
//   before that command goes out.
// - Network thread: builds the commands from the latest source, and sends q
//   at the server's send rate with the commands built before it became due,
//   once each is stamped or has waited KRUNKER_INPUT_CLOCK_STAMP_WAIT (a
//   stalled game thread). It is the only q sender in this mode.
//
// Every field is guarded by the mutex; each side only copies small structs.
// Times are glfw.GetTime() seconds (safe from any thread).

KRUNKER_INPUT_CLOCK_STAMP_WAIT :: 0.05
KRUNKER_INPUT_CLOCK_MAX_CATCH_UP :: 0.1

Krunker_Input_Clock_Source :: struct {
	enabled: bool,
	// first goes into the next command only (a Scroll press, a weapon swap);
	// rest into every command after it.
	first, rest: shared.Input,
	first_pending: bool,
	look: shared.Vec2,
	delta_mlt: f32,
	move_lock: bool,
	rate: f64,         // commands per second
	send_seconds: f64, // q interval (the server's tick)
}

Krunker_Input_Clock_Entry :: struct {
	input: shared.Input,
	at: f64, // the command's clock boundary
	stamped, sent, pulled: bool,
}

Krunker_Input_Clock :: struct {
	mutex: sync.Mutex,
	source: Krunker_Input_Clock_Source,
	sequence: i32,
	remainder_ms: f64,
	swap: u8,
	reset: bool,
	started: bool,
	next_at, send_at: f64,
	q_due: bool,
	q_target: i32,
	entries: [dynamic]Krunker_Input_Clock_Entry,
	dropped: i32,
	// Diagnostics (Dev tester export).
	built, sent_unstamped, late_stamps, q_sent: int,
}

g_input_clock: Krunker_Input_Clock

// Is the mode active for this frame: the setting (Dev build only) and a
// running network thread.
krunker_input_clock_active :: proc(client: ^Client) -> bool {
	when !SR_DEV { return false }
	return menuui.hud_input_clock(client.hud_settings) && g_net_thread.running
}

// One command from base, with the duration, rounded angles and swap exactly
// as the per-frame path builds them (krunker_client_predict_input).
krunker_input_clock_build :: proc(c: ^Krunker_Input_Clock, base: shared.Input) -> shared.Input {
	src := &c.source
	command := base
	command.seq = c.sequence
	duration_ms := clamp(1000 / src.rate * f64(src.delta_mlt), 1, 33) + c.remainder_ms
	rounded_ms := math.round(duration_ms)
	c.remainder_ms = duration_ms - rounded_ms
	command.delta = f32(rounded_ms) / 1000
	command.x_dir = f32(kproto.krunker_js_round_to(f64(src.look.x), 3))
	command.y_dir = f32(kproto.krunker_js_round_to(kproto.krunker_js_mod(f64(src.look.y), kproto.KRUNKER_PI2), 3))
	if base.swap != 0 { c.swap = base.swap }
	command.swap = c.swap
	c.swap = 0
	if src.move_lock { command.move_dir = -1; command.jump = false }
	command.krunker_shot_timed = false
	command.krunker_shot_time, command.krunker_shot_progress = 0, 0
	command.predicted_ramp_fix, command.predicted_has_ramp_fix = 0, false
	c.sequence += 1
	return command
}

// Game thread: replace the source. A first command not built yet keeps its
// one-command presses, so nothing pressed between two commands is lost.
krunker_input_clock_publish :: proc(c: ^Krunker_Input_Clock, source: Krunker_Input_Clock_Source) {
	sync.mutex_lock(&c.mutex)
	defer sync.mutex_unlock(&c.mutex)
	next := source
	if c.source.first_pending && next.first_pending {
		old := c.source.first
		next.first.jump = next.first.jump || old.jump
		next.first.crouch = next.first.crouch || old.crouch
		next.first.reload = next.first.reload || old.reload
		next.first.shoot = next.first.shoot || old.shoot
		next.first.scope = next.first.scope || old.scope
		if next.first.swap == 0 { next.first.swap = old.swap }
	} else if c.source.first_pending {
		next.first, next.first_pending = c.source.first, true
	}
	c.source = next
}

// Game thread: drop everything not sent and restart the clock (at sequence
// when >= 0, else keeping the id).
krunker_input_clock_reset :: proc(c: ^Krunker_Input_Clock, sequence: i32, reset_flag: bool) {
	sync.mutex_lock(&c.mutex)
	defer sync.mutex_unlock(&c.mutex)
	clear(&c.entries)
	c.remainder_ms, c.swap = 0, 0
	c.source.first_pending = false
	c.started, c.q_due = false, false
	c.dropped = 0
	if sequence >= 0 { c.sequence = sequence }
	if reset_flag { c.reset = true }
}

krunker_input_clock_request_reset :: proc(c: ^Krunker_Input_Clock) {
	sync.mutex_lock(&c.mutex)
	defer sync.mutex_unlock(&c.mutex)
	c.reset = true
}

@(private = "file")
krunker_input_clock_trim :: proc(c: ^Krunker_Input_Clock) {
	done := 0
	for done < len(c.entries) && c.entries[done].pulled && c.entries[done].sent { done += 1 }
	if done > 0 { remove_range(&c.entries, 0, done) }
	// A game thread stalled for seconds: drop the oldest commands already sent.
	excess := len(c.entries) - KRUNKER_MAX_PREDICTED_INPUTS
	drop := 0
	for drop < excess && c.entries[drop].sent { drop += 1 }
	if drop > 0 {
		c.dropped += i32(drop)
		remove_range(&c.entries, 0, drop)
	}
}

// Network thread: build every command whose boundary has passed.
krunker_input_clock_tick :: proc(c: ^Krunker_Input_Clock, now: f64) -> (built: int) {
	sync.mutex_lock(&c.mutex)
	defer sync.mutex_unlock(&c.mutex)
	if !c.source.enabled || c.source.rate <= 0 { c.started = false; return }
	step := 1 / c.source.rate
	if !c.started {
		c.started = true
		c.next_at = now + step
		c.send_at = now + c.source.send_seconds
		c.q_due = false
		return
	}
	if now - c.next_at > KRUNKER_INPUT_CLOCK_MAX_CATCH_UP { c.next_at = now - KRUNKER_INPUT_CLOCK_MAX_CATCH_UP }
	for now + 1e-7 >= c.next_at {
		base := c.source.first_pending ? c.source.first : c.source.rest
		c.source.first_pending = false
		command := krunker_input_clock_build(c, base)
		append(&c.entries, Krunker_Input_Clock_Entry{input = command, at = c.next_at})
		c.next_at += step
		built += 1
	}
	c.built += built
	krunker_input_clock_trim(c)
	return
}

// Network thread: the next q when one is due and ready, in id order.
krunker_input_clock_take_q :: proc(c: ^Krunker_Input_Clock, now: f64, out: ^[dynamic]shared.Input) -> (reset, ok: bool) {
	sync.mutex_lock(&c.mutex)
	defer sync.mutex_unlock(&c.mutex)
	if !c.q_due {
		if !c.started || now + 1e-7 < c.send_at { return }
		c.q_due, c.q_target = true, c.sequence
	}
	first := 0
	for first < len(c.entries) && c.entries[first].sent { first += 1 }
	count := 0
	for i := first; i < len(c.entries) && count < kproto.KRUNKER_MAX_INPUT_BATCH; i += 1 {
		entry := &c.entries[i]
		if entry.input.seq >= c.q_target { break }
		if !entry.stamped && now - entry.at < KRUNKER_INPUT_CLOCK_STAMP_WAIT { return }
		count += 1
	}
	if count == 0 {
		c.q_target = c.sequence
		return
	}
	clear(out)
	for i in first ..< first + count {
		entry := &c.entries[i]
		entry.sent = true
		if !entry.stamped { c.sent_unstamped += 1 }
		append(out, entry.input)
	}
	reset, c.reset = c.reset, false
	c.q_due = false
	c.q_sent += 1
	c.send_at = max(c.send_at + c.source.send_seconds, now - c.source.send_seconds)
	krunker_input_clock_trim(c)
	return reset, true
}

// Network thread: seconds until it next has work, at most limit.
krunker_input_clock_next_wait :: proc(c: ^Krunker_Input_Clock, now, limit: f64) -> f64 {
	sync.mutex_lock(&c.mutex)
	defer sync.mutex_unlock(&c.mutex)
	wait := limit
	if !c.started { return c.source.enabled ? 0 : wait }
	wait = min(wait, c.next_at - now)
	if c.q_due {
		for entry in c.entries {
			if entry.sent || entry.stamped { continue }
			wait = min(wait, entry.at + KRUNKER_INPUT_CLOCK_STAMP_WAIT - now)
			break
		}
	} else {
		wait = min(wait, c.send_at - now)
	}
	return max(wait, 0)
}

// Game thread: every built command not pulled yet, in id order.
krunker_input_clock_pull :: proc(c: ^Krunker_Input_Clock, out: ^[dynamic]Krunker_Input_Clock_Entry) -> (next_sequence: i32, dropped: i32) {
	sync.mutex_lock(&c.mutex)
	defer sync.mutex_unlock(&c.mutex)
	for &entry in c.entries {
		if entry.pulled { continue }
		entry.pulled = true
		append(out, entry)
	}
	next_sequence, dropped = c.sequence, c.dropped
	c.dropped = 0
	krunker_input_clock_trim(c)
	return
}

// Game thread: the shot stamps prediction gave each command. Commands that
// already went out keep what they were sent with.
krunker_input_clock_stamp :: proc(c: ^Krunker_Input_Clock, commands: []Krunker_Input_Clock_Entry) {
	if len(commands) == 0 { return }
	sync.mutex_lock(&c.mutex)
	defer sync.mutex_unlock(&c.mutex)
	if len(c.entries) == 0 { return }
	base := c.entries[0].input.seq
	for predicted in commands {
		command := predicted.input
		index := int(command.seq - base)
		if index < 0 || index >= len(c.entries) || c.entries[index].input.seq != command.seq { continue }
		entry := &c.entries[index]
		if entry.sent {
			if command.krunker_shot_timed { c.late_stamps += 1 }
			continue
		}
		entry.input.krunker_shot_timed = command.krunker_shot_timed
		entry.input.krunker_shot_time = command.krunker_shot_time
		entry.input.krunker_shot_progress = command.krunker_shot_progress
		entry.stamped = true
	}
	krunker_input_clock_trim(c)
}

krunker_input_clock_stats :: proc(c: ^Krunker_Input_Clock) -> (built, q_sent, sent_unstamped, late_stamps: int) {
	sync.mutex_lock(&c.mutex)
	defer sync.mutex_unlock(&c.mutex)
	return c.built, c.q_sent, c.sent_unstamped, c.late_stamps
}

// The id the game thread expects the clock to continue from; another value
// in krunker.input_sequence means the game thread moved it (bootstrap, l).
g_input_clock_expected_seq: i32 = -1

// Game thread, fixed-clock mode: publish this frame's input, then predict the
// commands the network thread built since the last frame, exactly as sent.
krunker_client_predict_clock :: proc(client: ^Client, frame: ^shared.Input, after_scroll: ^shared.Input, look: shared.Vec2) -> (commands: int) {
	state := &client.krunker
	c := &g_input_clock
	if state.input_sequence != g_input_clock_expected_seq {
		krunker_input_clock_reset(c, state.input_sequence, false)
		g_input_clock_expected_seq = state.input_sequence
	}
	if state.input_reset {
		krunker_input_clock_request_reset(c)
		state.input_reset = false
	}
	if !state.render_sample_ready {
		state.render_previous = {client.me.position, client.me.aim_val}
		state.render_current = state.render_previous
		state.command_direction = client.me.direction
		state.render_sample_ready = true
	}
	source := Krunker_Input_Clock_Source{
		enabled = true,
		first = frame^,
		rest = after_scroll != nil ? after_scroll^ : frame^,
		first_pending = true,
		look = look,
		delta_mlt = client.game.config.delta_mlt,
		move_lock = client.krunker_world.move_lock,
		rate = f64(g_krunker_input_rate),
		send_seconds = krunker_send_seconds(state),
	}
	source.rest.swap = 0 // a swap goes into one command only
	krunker_input_clock_publish(c, source)

	pulled := make([dynamic]Krunker_Input_Clock_Entry, context.temp_allocator)
	next_sequence, dropped := krunker_input_clock_pull(c, &pulled)
	if dropped > 0 { kproto.network_log("input", "input clock: game thread stalled; dropped sent commands it never predicted") }
	last_at: f64 = -1
	for &entry in pulled {
		command := entry.input
		state.render_previous = {client.me.position, client.me.aim_val}
		client.me.direction = state.command_direction
		shot_seq := client.me.shot_seq
		shared.player_proc_input(client.me, &command, true, client.krunker_world.move_lock, true, true)
		if client.me.shot_seq != shot_seq {
			// The shot fires at the command's clock boundary, not the frame's time.
			kproto.krunker_input_stamp_shot(&client.krunker_world, &command, entry.at)
			when HITREG_AUDIT { if commands == 0 { hitreg_audit_shot(client, entry.at) } }
		}
		command.predicted_ramp_fix, command.predicted_has_ramp_fix = client.me.ramp_fix, client.me.has_ramp_fix
		append(&client.predicted_inputs, command)
		client_cap_predicted_inputs(client, KRUNKER_MAX_PREDICTED_INPUTS)
		state.command_direction = client.me.direction
		state.render_current = {client.me.position, client.me.aim_val}
		entry.input = command
		last_at = entry.at
		commands += 1
	}
	krunker_input_clock_stamp(c, pulled[:])
	state.input_sequence = next_sequence
	g_input_clock_expected_seq = next_sequence
	// Render interpolation: time since the newest predicted command.
	if last_at >= 0 { state.input_elapsed = 0 }
	state.input_elapsed = clamp(state.input_elapsed + f64(clamp(frame.delta, 0, 0.1)), 0, krunker_input_seconds())
	client.me.direction = look
	return
}
