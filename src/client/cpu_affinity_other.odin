#+build !windows

package main

// CPU pinning is implemented for Windows only (cpu_affinity_windows.odin).

cpu_pinning_apply :: proc() -> string {
	return "CPU pinning is not implemented on this platform"
}

cpu_pin_current_thread_off_game_core :: proc() {
}

cpu_pin_current_thread :: proc(role: Cpu_Role) {
}

cpu_raise_current_thread_priority :: proc() {
}

// CLOCK_MONOTONIC counts nanoseconds.
cpu_clock_frequency :: proc() -> i64 {
	return 1_000_000_000
}
