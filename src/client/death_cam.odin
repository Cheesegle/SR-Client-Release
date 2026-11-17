package main

import "core:fmt"
import "core:math"
import glfw "vendor:glfw"
import shared "../shared"

// Krunker-style death: when you die the game keeps running behind you (no
// menu, mouse stays captured, killfeed and HUD stay visible). The camera stays
// where you died, slowly turns to your killer and zooms in. When the server's
// respawn cooldown ends you respawn automatically, or on a left click when
// Settings > Game > Auto respawn is off. Escape still opens the menu.

DEATH_CAM_TURN_RATE :: 3.0  // how fast the camera turns to the killer (1/s)
DEATH_CAM_ZOOM_DELAY :: 0.35 // seconds before the zoom starts
DEATH_CAM_ZOOM_TIME :: 1.6   // seconds to reach full zoom
DEATH_CAM_ZOOM :: 1.8        // final zoom factor (field of view / 1.8)

Death_Cam :: struct {
	active:      bool,
	started:     f64,
	killer_uid:  i32,
	has_killer:  bool,
	killer_name: string,
	last_click:  bool,
	free_look:   bool, // the player moved the mouse: stop turning to the killer
}

g_death: Death_Cam

// Called for every kill line; remembers who killed the local player.
death_cam_note_kill :: proc(victim_is_you: bool, has_killer: bool, killer_uid: i32, killer_name: string) {
	if !victim_is_you { return }
	g_death.has_killer = has_killer
	g_death.killer_uid = killer_uid
	delete(g_death.killer_name)
	g_death.killer_name = fmt.aprintf("%s", killer_name)
}

death_cam_begin :: proc(client: ^Client) {
	if g_death.active { return }
	g_death.active = true
	g_death.free_look = false
	g_death.started = glfw.GetTime()
	g_death.last_click = glfw.GetMouseButton(client.window, glfw.MOUSE_BUTTON_LEFT) == glfw.PRESS
}

death_cam_end :: proc() {
	g_death.active, g_death.has_killer = false, false
	delete(g_death.killer_name)
	g_death.killer_name = ""
}

// True when the death screen should respawn now: always with auto respawn
// (the server cooldown is still enforced by client_enter_game), otherwise on
// a fresh left click.
death_cam_wants_respawn :: proc(client: ^Client) -> bool {
	if !g_death.active { return true }
	click := glfw.GetMouseButton(client.window, glfw.MOUSE_BUTTON_LEFT) == glfw.PRESS
	defer g_death.last_click = click
	if !client.hud_settings.manual_respawn { return true }
	return click && !g_death.last_click
}

// Mouse look while dead, as in Krunker. `rotation` is client_mouse_rotation's.
death_cam_look :: proc(client: ^Client, rotation: shared.Vec2) {
	if !g_death.active || (rotation.x == 0 && rotation.y == 0) { return }
	g_death.free_look = true
	client.camera.rotation.x = clamp(client.camera.rotation.x - rotation.y, -math.PI/2, math.PI/2)
	client.camera.rotation.y -= rotation.x
}

// The round break (intermission, match start) is not a death: no kill cam.
death_cam_round_break :: proc(client: ^Client) -> bool {
	if !client.krunker.connected { return false }
	countdown := client.krunker_world.countdown
	return countdown == .INTERMISSION || countdown == .STARTING || countdown == .WARMUP
}

death_cam_update :: proc(client: ^Client, delta: f32) {
	if !g_death.active { return }
	if client.me != nil && client.me.active { death_cam_end(); return }
	elapsed := f32(glfw.GetTime() - g_death.started)
	if death_cam_round_break(client) { client.camera.zoom = 1; return }
	if g_death.has_killer && !g_death.free_look {
		killer := client_find_player(client, g_death.killer_uid)
		if killer != nil && killer.active && killer != client.me {
			height := killer.height > 0 ? killer.height : shared.GAME_CONSTANTS.player_height
			target := killer.position + shared.Vec3{0, height*0.8, 0}
			d := target - client.camera.position
			flat := math.sqrt(d.x*d.x + d.z*d.z)
			if flat > 0.01 || abs(d.y) > 0.01 {
				yaw := math.atan2(-d.x, -d.z)
				pitch := math.atan2(d.y, flat)
				t := 1 - math.exp(-DEATH_CAM_TURN_RATE*delta)
				turn := yaw - client.camera.rotation.y
				for turn > math.PI { turn -= 2*math.PI }
				for turn < -math.PI { turn += 2*math.PI }
				client.camera.rotation.y += turn*t
				client.camera.rotation.x += (pitch - client.camera.rotation.x)*t
				client.camera.rotation.z = 0
			}
		}
	}
	progress := clamp((elapsed - DEATH_CAM_ZOOM_DELAY)/DEATH_CAM_ZOOM_TIME, 0, 1)
	eased := progress*progress*(3 - 2*progress)
	client.camera.zoom = 1 + (DEATH_CAM_ZOOM - 1)*eased
}

// "Killed by <name>" and the respawn line, drawn over the game while dead.
death_cam_render :: proc(client: ^Client) {
	if !g_death.active || (client.me != nil && client.me.active) || death_cam_round_break(client) { return }
	ui := client.ui
	s := ui.scale
	white := shared.Vec4{1, 1, 1, 1}
	muted := shared.Vec4{1, 1, 1, 0.8}
	title := g_death.has_killer && len(g_death.killer_name) > 0 ? fmt.tprintf("Killed by %s", g_death.killer_name) : "You died"
	size := 40*s
	y := ui.height*0.68
	ui_fill_text(ui, white, title, (ui.width - ui_measure_text(ui, title, size))*0.5, y, size)
	remaining := krunker_client_respawn_remaining(client, glfw.GetTime())
	line: string
	switch {
	case remaining > 0: line = fmt.tprintf("Respawn in %d", int(remaining + 0.999))
	case client.spawn_pending: line = "Respawning..."
	case client.hud_settings.manual_respawn: line = "Click to respawn"
	case: line = "Respawning..."
	}
	small := 24*s
	ui_fill_text(ui, muted, line, (ui.width - ui_measure_text(ui, line, small))*0.5, y + 42*s, small)
}
