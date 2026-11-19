package main

import "core:fmt"
import "core:math"
import glfw "vendor:glfw"
import shared "../shared"

// Krunker's death: the game keeps running behind you (no menu, mouse stays
// captured, killfeed and HUD stay visible). With the lobby's Kill Cams on
// (kCams, default on), Krunker calls camLookAt on the killer once, at the
// moment of death (killer x, y + height/1.5, z): every frame its camera then
// turns towards that point (angle difference x ms x 0.0022) and flies towards
// a spot 24 units short of it (distance x ms x 0.0012). Your mouse still turns
// the camera, against a pull that grows with the angle, so you can glance
// around but are drawn back to the killer. The killer stays visible with its
// health bar. When the server's respawn cooldown ends you respawn
// automatically, or on a left click when Settings > Game > Auto respawn is off.

KRUNKER_KILL_CAM_TURN :: 0.0022 // Krunker ND, per ms
KRUNKER_KILL_CAM_MOVE :: 0.0012 // Krunker Kne, per ms
KRUNKER_KILL_CAM_STANDOFF :: 24

Death_Cam :: struct {
	active:      bool,
	started:     f64,
	killer_uid:  i32,
	has_killer:  bool,
	killer_name: string,
	last_click:  bool,
	has_target:  bool, // camLookAt ran: target yaw/pitch/position below
	target_yaw, target_pitch: f32,
	target_position: shared.Vec3,
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
	g_death.has_target = false
	g_death.started = glfw.GetTime()
	g_death.last_click = glfw.GetMouseButton(client.window, glfw.MOUSE_BUTTON_LEFT) == glfw.PRESS
}

death_cam_end :: proc() {
	g_death.active, g_death.has_killer, g_death.has_target = false, false, false
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
	client.camera.zoom = 1
	if death_cam_round_break(client) { return }
	kill_cams := !client.krunker.connected || client.krunker_world.game_config.kill_cams
	if !g_death.has_target && g_death.has_killer && kill_cams {
		killer := client_find_player(client, g_death.killer_uid)
		if killer != nil && killer.active && killer != client.me {
			death_cam_look_at(killer.position + shared.Vec3{0, killer.height/1.5, 0}, client.camera.position)
		}
	}
	if !g_death.has_target { return }
	ms := clamp(delta, 0, 0.1)*1000
	// rotation += angle difference * ms * ND (fp: the signed shortest angle)
	turn := math.atan2(math.sin(g_death.target_yaw - client.camera.rotation.y), math.cos(client.camera.rotation.y - g_death.target_yaw))
	client.camera.rotation.y += turn*min(1, ms*KRUNKER_KILL_CAM_TURN)
	pitch := math.atan2(math.sin(g_death.target_pitch - client.camera.rotation.x), math.cos(client.camera.rotation.x - g_death.target_pitch))
	client.camera.rotation.x += pitch*min(1, ms*KRUNKER_KILL_CAM_TURN)
	client.camera.rotation.z = 0
	// position += distance * ms * Kne towards the target
	d := g_death.target_position - client.camera.position
	client.camera.position += d*min(1, ms*KRUNKER_KILL_CAM_MOVE)
}

// Krunker camLookAt(x, y, z): the yaw and pitch from the camera to the point,
// and a target position 24 units short of it on the camera's side.
death_cam_look_at :: proc(point, camera: shared.Vec3) {
	d := point - camera
	flat := math.sqrt(d.x*d.x + d.z*d.z)
	length := math.sqrt(flat*flat + d.y*d.y)
	if length < 0.001 { return }
	g_death.target_yaw = math.atan2(-d.x, -d.z)
	g_death.target_pitch = math.atan2(d.y, flat)
	g_death.target_position = point - d/length*KRUNKER_KILL_CAM_STANDOFF
	g_death.has_target = true
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
