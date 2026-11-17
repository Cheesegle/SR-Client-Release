package main

import win "core:sys/windows"

// Raise the Windows timer resolution to ~1 ms for the client's lifetime, as the
// server does. At the default ~15.6 ms quantum, idle-frame waits overshoot by a
// random amount and menu frame rates land far below the chosen limit.
client_set_timer_precision :: proc() {
	win.timeBeginPeriod(1)
}

client_restore_timer_precision :: proc() {
	win.timeEndPeriod(1)
}

// Gives up the rest of the time slice to another ready thread, if any.
client_timer_yield :: proc() {
	win.SwitchToThread()
}
