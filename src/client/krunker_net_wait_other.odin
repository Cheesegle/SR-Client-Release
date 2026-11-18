#+build !windows
package main

import "core:sync"
import "core:time"
import curl "vendor:curl"

// Outside Windows the network thread waits for a queued packet (wake) or
// 1 ms, then reads the socket again (see krunker_net_wait_windows.odin).
Net_Waiter :: struct {
	wake: sync.Sema,
}

net_waiter_init :: proc(w: ^Net_Waiter, handle: ^curl.CURL) { w^ = {} }
net_waiter_fini :: proc(w: ^Net_Waiter) { w^ = {} }
net_waiter_has_socket :: proc(w: ^Net_Waiter) -> bool { return false }
net_waiter_wake :: proc(w: ^Net_Waiter) { sync.sema_post(&w.wake) }
net_waiter_wait :: proc(w: ^Net_Waiter) { sync.sema_wait_with_timeout(&w.wake, time.Millisecond) }
