package main

import "core:testing"
import shared "../shared"

when ODIN_TEST {
	@(test)
	input_clock_builds_at_the_rate_and_waits_for_stamps :: proc(t: ^testing.T) {
		c: Krunker_Input_Clock
		defer delete(c.entries)
		krunker_input_clock_reset(&c, 13, false)
		krunker_input_clock_publish(&c, {enabled = true, rate = 360, send_seconds = 1.0 / 30, delta_mlt = 1, look = {0.1, 0.2}})
		testing.expect_value(t, krunker_input_clock_tick(&c, 10.0), 0) // starts the clock
		testing.expect_value(t, krunker_input_clock_tick(&c, 10.0 + 12.0 / 360 + 1e-6), 12)
		// 12 commands of 1/360 s: durations 3,3,2 ms... adding to exactly 33 ms.
		total: f32
		for e in c.entries { total += e.input.delta }
		testing.expect(t, abs(total - 0.033) < 1e-5, "fractional ms carried")
		testing.expect_value(t, c.entries[0].input.seq, i32(13))
		// q is due at 10 + 1/30 but the commands are not stamped: it waits.
		batch: [dynamic]shared.Input
		defer delete(batch)
		_, ok := krunker_input_clock_take_q(&c, 10.0 + 1.0 / 30 + 0.001, &batch)
		testing.expect(t, !ok, "waits for the game thread's stamps")
		pulled: [dynamic]Krunker_Input_Clock_Entry
		defer delete(pulled)
		next, _ := krunker_input_clock_pull(&c, &pulled)
		testing.expect_value(t, next, i32(25))
		krunker_input_clock_stamp(&c, pulled[:])
		_, ok = krunker_input_clock_take_q(&c, 10.0 + 1.0 / 30 + 0.002, &batch)
		testing.expect(t, ok && len(batch) == 12, "stamped commands go out")
		// A stalled game thread: unstamped commands go out after the wait.
		krunker_input_clock_tick(&c, 10.0 + 24.0 / 360 + 1e-6)
		_, ok = krunker_input_clock_take_q(&c, 10.0 + 2.0 / 30 + 0.001, &batch)
		testing.expect(t, !ok)
		_, ok = krunker_input_clock_take_q(&c, 10.0 + 2.0 / 30 + KRUNKER_INPUT_CLOCK_STAMP_WAIT + 0.01, &batch)
		testing.expect(t, ok && len(batch) > 0, "sent unstamped after the stamp wait")
	}

	@(test)
	input_clock_keeps_one_command_presses :: proc(t: ^testing.T) {
		c: Krunker_Input_Clock
		defer delete(c.entries)
		press := shared.Input{jump = true, swap = 2}
		krunker_input_clock_publish(&c, {enabled = true, rate = 360, send_seconds = 1.0 / 30, delta_mlt = 1, first = press, first_pending = true})
		krunker_input_clock_publish(&c, {enabled = true, rate = 360, send_seconds = 1.0 / 30, delta_mlt = 1, first_pending = true})
		krunker_input_clock_tick(&c, 1)
		krunker_input_clock_tick(&c, 1 + 2.0 / 360 + 1e-6)
		testing.expect(t, len(c.entries) == 2 && c.entries[0].input.jump && c.entries[0].input.swap == 2, "a press between commands is kept")
		testing.expect(t, !c.entries[1].input.jump && c.entries[1].input.swap == 0, "and used once")
	}
}
