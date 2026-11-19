#+build !windows

package main

import glfw "vendor:glfw"
import shared "../shared"

client_mouse_init :: proc(window: glfw.WindowHandle) -> bool { return false }
client_mouse_fini :: proc() {}
client_mouse_delta :: proc(fallback: shared.Vec2) -> shared.Vec2 { return fallback }
client_poll_events :: proc() { glfw.PollEvents() }
client_wait_events :: proc(timeout: f64) { glfw.WaitEventsTimeout(timeout) }
raw_mouse_frame_totals :: proc() -> (totals: [2]i64, live: bool) { return }
raw_mouse_totals_now :: proc "contextless" () -> [2]i64 { return {} }
