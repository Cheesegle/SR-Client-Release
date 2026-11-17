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

// One high-resolution waitable timer for the game thread's frame waits
// (Windows 10 1803+; an ordinary one, ~1 ms with timeBeginPeriod, before).
@(private = "file")
g_frame_timer: win.HANDLE

// Sleeps until `seconds` have passed or a window message arrives, whichever
// is first. The caller processes messages after (client_poll_events).
client_wait_for_message :: proc(seconds: f64) {
	if seconds <= 0 { return }
	if g_frame_timer == nil {
		g_frame_timer = win.CreateWaitableTimerExW(nil, nil, win.CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, win.TIMER_ALL_ACCESS)
		if g_frame_timer == nil { g_frame_timer = win.CreateWaitableTimerExW(nil, nil, 0, win.TIMER_ALL_ACCESS) }
	}
	if g_frame_timer == nil {
		win.MsgWaitForMultipleObjects(0, nil, false, win.DWORD(max(seconds * 1000, 1)), win.QS_ALLINPUT)
		return
	}
	due := win.LARGE_INTEGER(-i64(seconds * 1e7)) // relative, in 100 ns
	if !win.SetWaitableTimerEx(g_frame_timer, &due, 0, nil, nil, nil, 0) { return }
	timer := g_frame_timer
	win.MsgWaitForMultipleObjects(1, &timer, false, win.INFINITE, win.QS_ALLINPUT)
}
