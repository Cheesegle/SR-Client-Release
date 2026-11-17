#+build !windows

package main

// CPU pinning is implemented for Windows only (cpu_affinity_windows.odin).

cpu_pinning_apply :: proc() -> string {
	return "CPU pinning is not implemented on this platform"
}

cpu_pin_current_thread_off_game_core :: proc() {
}
