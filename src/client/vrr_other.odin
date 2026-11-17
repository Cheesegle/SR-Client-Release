#+build !windows
package main

import glfw "vendor:glfw"

// Elsewhere only the mode's refresh rate is known; VRR cap: Always still caps.
vrr_detect :: proc(monitor: glfw.MonitorHandle) -> (info: Vrr_Info) {
	if monitor == nil { return }
	if mode := glfw.GetVideoMode(monitor); mode != nil { info.refresh_hz = f64(mode.refresh_rate) }
	return
}
