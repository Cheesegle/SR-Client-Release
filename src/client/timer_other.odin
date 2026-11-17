#+build !windows

package main

import "core:time"

// POSIX and Apple timers already deliver sub-millisecond waits, so no timer
// resolution change is needed on non-Windows platforms.
client_set_timer_precision :: proc() {
}

client_restore_timer_precision :: proc() {
}

client_timer_yield :: proc() {
	time.sleep(0)
}
