package main

import "core:sync"
import "core:time"

// Mouse delay for the latency probe (SR_LATENCY_PROBE): while it records, the
// input path notes when the first mouse report of each batch reached SR (the
// raw input thread's WM_INPUT, QPC clock), the frame that reads that batch
// takes the time, and the probe reports the time from it to that frame's last
// GPU timestamp ("mouse->GPU done"). Off outside the probe: one atomic load
// per mouse report.
g_input_probe: struct {
	on:              bool, // atomic
	first_unread_ns: i64,  // atomic: arrival of the oldest report not yet read by a frame; 0 = none
}

input_probe_event :: #force_inline proc "contextless" () {
	if !sync.atomic_load_explicit(&g_input_probe.on, .Relaxed) { return }
	sync.atomic_compare_exchange_strong(&g_input_probe.first_unread_ns, 0, i64(time.tick_now()._nsec))
}

// The frame read the mouse: the oldest unread report's arrival, or 0.
input_probe_take :: proc "contextless" () -> i64 {
	if !sync.atomic_load_explicit(&g_input_probe.on, .Relaxed) { return 0 }
	return sync.atomic_exchange(&g_input_probe.first_unread_ns, 0)
}

input_probe_set :: proc "contextless" (on: bool) {
	sync.atomic_store(&g_input_probe.first_unread_ns, 0)
	sync.atomic_store(&g_input_probe.on, on)
}
