package main

import "core:fmt"
import "core:math"
import gl "vendor:OpenGL"
import stbtt "vendor:stb/truetype"
import menuui "../menu"
import shared "../shared"

// Screen position and OpenGL clip depth from the world camera. The weapon
// camera has a separate FOV and must never move an overhead bar.
player_healthbar_project :: proc(view_projection: shared.Mat4, point: shared.Vec3, width, height: f32) -> (shared.Vec3, bool) {
	clip := view_projection * shared.Vec4{point.x, point.y, point.z, 1}
	if clip.w <= 0 || abs(clip.x) > clip.w || abs(clip.y) > clip.w || abs(clip.z) > clip.w { return {}, false }
	ndc := shared.Vec3{clip.x, clip.y, clip.z} / clip.w
	return {(ndc.x+1)*width*0.5, (1-ndc.y)*height*0.5, ndc.z}, true
}

// Nameplate visibility. Krunker refreshes `canBSeen` every 200 ms from one
// ray to the target's feet and switches plates on and off instantly. SR Client
// deliberately departs from that (the user found it erratic): a player is
// visible when the eye can see any of several points on their hitbox, each
// player is re-tested 30 times a second, round-robin across the roster, and
// the plate switches on/off instantly like Krunker's, with a short hold so
// thin props don't flicker.
// Players behind objects are still hidden.
HEALTHBAR_VISIBILITY_RATE :: f32(30)   // line-of-sight tests per player per second
HEALTHBAR_MAX_FRAME_DT    :: f32(0.25) // clamp for hitches and the first frame
NAMEPLATE_FADE_IN         :: f32(0.12) // seconds from hidden to fully shown
NAMEPLATE_HOLD            :: f32(0.1)  // stay shown this long after the last visible test
NAMEPLATE_FADE_OUT        :: f32(0.2)  // seconds from fully shown to hidden, after the hold
NAMEPLATE_NEVER_SEEN      :: f32(-1e30)

player_healthbar_is_teammate :: proc(client: ^Client, player: ^shared.Player) -> bool {
	return client.me != nil && client.me.team != 0 && player.team == client.me.team
}

player_healthbar_eye :: proc(me: ^shared.Player) -> shared.Vec3 {
	return me.position + shared.Vec3{0, me.height - shared.GAME_CONSTANTS.camera_height, 0}
}

// Points on the target's hitbox (`scale` either side of the centre, `height`
// tall, lowered by crouching), in test order: head centre, chest, feet, then
// the chest-height left and right edges as seen from the eye.
player_healthbar_sight_points :: proc(eye: shared.Vec3, player: ^shared.Player) -> [5]shared.Vec3 {
	height := player.height > 0 ? player.height : shared.GAME_CONSTANTS.player_height - player.crouch_val*shared.GAME_CONSTANTS.crouch_distance
	half_width := player.scale > 0 ? player.scale : shared.GAME_CONSTANTS.player_scale
	head := player.position + shared.Vec3{0, height - shared.HEAD_SCALE*0.5, 0}
	chest := player.position + shared.Vec3{0, height*0.6, 0}
	to := chest - eye
	side: shared.Vec3
	if length := math.sqrt(to.x*to.x + to.z*to.z); length > 1e-3 {
		side = shared.Vec3{-to.z, 0, to.x} * (half_width*0.9/length)
	}
	return {head, chest, player.position, chest - side, chest + side}
}

// True when any sight point is unblocked. Stops at the first visible point;
// see-through, no-shoot and ramp objects never block (map_object_blocks_sight).
player_healthbar_line_of_sight :: proc(map_inst: ^shared.Map, eye: shared.Vec3, player: ^shared.Player) -> bool {
	for point in player_healthbar_sight_points(eye, player) {
		if shared.map_can_see(map_inst, eye, point) { return true }
	}
	return false
}

// Death, respawn, creation and the local player dying all start from here:
// no stale fade or hold survives into the next life.
player_nameplate_reset :: proc(player: ^shared.Player) {
	player.can_be_seen, player.nameplate_tracked, player.nameplate_in_view = false, false, false
	player.nameplate_alpha, player.nameplate_seen_at = 0, NAMEPLATE_NEVER_SEEN
}

// Per frame: decides which players get a line-of-sight test this frame and
// eases every plate's alpha. Teammates are always shown at full alpha;
// enemies (everyone in FFA, where the local team is 0) are hidden when the
// lobby's hide-enemy-nametags option is on, else follow line of sight. A test runs when a player's round-robin turn
// comes up (HEALTHBAR_VISIBILITY_RATE per player per second, spread evenly
// over frames), when a player starts a new life, and when their plate anchor
// enters the screen. Players whose anchor is off screen are not traced.
player_healthbars_update_visibility :: proc(client: ^Client, now: f32) {
	dt := clamp(now - client.healthbar_visibility_time, 0, HEALTHBAR_MAX_FRAME_DT)
	client.healthbar_visibility_time = now
	me := client.me
	players := client.game.players[:]
	// Krunker keeps drawing plates while you are dead (death cam): only a menu
	// or the end screen hides them. A dead player's eye is the camera.
	if me == nil || !me.active && !g_death.active {
		for player in players { if player != nil && player != me { player_nameplate_reset(player) } }
		return
	}

	// Frustum: the same world-camera projection the renderer uses. Matrices
	// are rebuilt on a copy because the world pass may not have run yet.
	frustum := client.viewport_width > 0 && client.viewport_height > 0
	view_projection: shared.Mat4
	if frustum {
		camera := client.camera
		camera_update_projection_matrix(&camera, f32(client.viewport_width)/f32(client.viewport_height))
		camera_update_world_inverse_matrix(&camera)
		view_projection = camera.projection_matrix * camera.world_inverse_matrix
	}

	count := len(players)
	first, due_count := 0, 0
	if count > 0 {
		client.healthbar_visibility_budget = min(client.healthbar_visibility_budget + dt*HEALTHBAR_VISIBILITY_RATE*f32(count), f32(count))
		due_count = int(client.healthbar_visibility_budget)
		client.healthbar_visibility_budget -= f32(due_count)
		first = client.healthbar_visibility_cursor % count
		client.healthbar_visibility_cursor = (first + due_count) % count
	}
	eye := me.active ? player_healthbar_eye(me) : client.camera.position
	for player, index in players {
		if player == nil || player == me || player.is_you { continue }
		if !player.active || player.health <= 0 {
			player_nameplate_reset(player)
			continue
		}
		due := (index - first + count) % count < due_count
		if !player.nameplate_tracked {
			player_nameplate_reset(player)
			player.nameplate_tracked, due = true, true
		}
		if player_healthbar_is_teammate(client, player) {
			player.can_be_seen, player.nameplate_alpha, player.nameplate_seen_at = true, 1, now
			continue
		}
		if client.game.config.hide_enemy_nametags {
			player.can_be_seen, player.nameplate_alpha = false, 0
			continue
		}
		in_view := true
		if frustum {
			_, in_view = player_healthbar_project(view_projection, player_nameplate_anchor(player), 1, 1)
		}
		if in_view && !player.nameplate_in_view { due = true }
		player.nameplate_in_view = in_view
		if due {
			player.can_be_seen = in_view && player_healthbar_line_of_sight(client.game.map_inst, eye, player)
			if player.can_be_seen { player.nameplate_seen_at = now }
		}
		shown := player.can_be_seen || now - player.nameplate_seen_at < NAMEPLATE_HOLD
		// Like Krunker: the plate switches on and off at once, no fade.
		player.nameplate_alpha = shown ? 1 : 0
	}
}

// Linear alpha eased for display (smoothstep): no hard start or stop.
player_nameplate_display_alpha :: proc(alpha: f32) -> f32 {
	a := clamp(alpha, 0, 1)
	return a*a*(3 - 2*a)
}

// Krunker nameplate geometry (nametagStyle 0, Krunker's client `x.nametagOpacity > 0`).
// Lengths are 2D overlay canvas units. Krunker's canvas is scaled by the UI
// scale (`window.scaleBase`, the same formula as `ui.scale`) and then by the
// per-player distance scale, so on screen one unit is `ui.scale * plate_scale`.
NAMEPLATE_ANCHOR_HEIGHT :: f32(11.6) // objInstances.position.y + 11.6
NAMEPLATE_CROUCH_DROP   :: f32(3)    // - crouchVal * 3
NAMEPLATE_FADE_DISTANCE :: f32(600)  // max(0.3, 1 - distance / 600)
NAMEPLATE_MIN_SCALE     :: f32(0.3)
NAMEPLATE_BAR_WIDTH     :: f32(130)  // Y
NAMEPLATE_BAR_HEIGHT    :: f32(16)   // G with HP bars
NAMEPLATE_NO_BAR_HEIGHT :: f32(6)    // G without HP bars (mode.noHPbars)
NAMEPLATE_NAME_GAP      :: f32(10)   // translate(0, -G - 10)
NAMEPLATE_NAME_SIZE     :: f32(20)   // "20px GameFont"
NAMEPLATE_NAME_MAX_WIDTH :: f32(425) // fillText(..., 425)

// Krunker anchors the plate on the model root, 11.6 above the feet and 3 lower
// at full crouch. SR Client has no cosmetics data, so the +0.8 hat/head lift and
// the big-head (`headMlt`) lift are always zero.
player_nameplate_anchor :: proc(player: ^shared.Player) -> shared.Vec3 {
	return player.position + shared.Vec3{0, NAMEPLATE_ANCHOR_HEIGHT - player.crouch_val*NAMEPLATE_CROUCH_DROP, 0}
}

// Distance is measured from the world camera to the anchor.
player_nameplate_scale :: proc(camera_position, anchor: shared.Vec3) -> f32 {
	d := anchor - camera_position
	return max(NAMEPLATE_MIN_SCALE, 1 - math.sqrt(d.x*d.x + d.y*d.y + d.z*d.z)/NAMEPLATE_FADE_DISTANCE)
}

Nameplate_Layout :: struct {
	bar_left, bar_top, bar_width, bar_height: f32,
	name_x, name_baseline, name_size: f32,
}

// `unit` is screen pixels per canvas unit. With a bar, the bar's bottom edge
// sits on the anchor and the name is left-aligned with the bar, its baseline
// 10 units above the bar. Without a bar Krunker shrinks G to 6 and centres the
// name (Y becomes the name width).
player_nameplate_layout :: proc(screen: shared.Vec2, unit, name_width: f32, show_bar: bool) -> Nameplate_Layout {
	layout: Nameplate_Layout
	g := show_bar ? NAMEPLATE_BAR_HEIGHT : NAMEPLATE_NO_BAR_HEIGHT
	layout.bar_width, layout.bar_height = NAMEPLATE_BAR_WIDTH*unit, NAMEPLATE_BAR_HEIGHT*unit
	layout.bar_left, layout.bar_top = screen.x - layout.bar_width*0.5, screen.y - layout.bar_height
	layout.name_size = NAMEPLATE_NAME_SIZE*unit
	width := name_width*unit
	if width > NAMEPLATE_NAME_MAX_WIDTH*unit {
		layout.name_size *= NAMEPLATE_NAME_MAX_WIDTH*unit/width
		width = NAMEPLATE_NAME_MAX_WIDTH*unit
	}
	plate_width := show_bar ? layout.bar_width : width
	layout.name_x = screen.x - plate_width*0.5
	layout.name_baseline = screen.y - (g + NAMEPLATE_NAME_GAP)*unit
	return layout
}

// CSS font sizes are em sizes; SR Client's glyph cache scales by pixel height.
nameplate_font_size :: proc(em_pixels: f32) -> f32 {
	load_font()
	if !g_font_loaded { return em_pixels }
	return em_pixels * stbtt.ScaleForMappingEmToPixels(&g_font_info, 1) / stbtt.ScaleForPixelHeight(&g_font_info, 1)
}

// Live Krunker roster name, else the same "Player N" fallback as the lobby
// and scoreboard. Native sessions carry no names.
player_nameplate_name :: proc(client: ^Client, player: ^shared.Player) -> string {
	if client.krunker.connected {
		for entry in client.krunker_world.players {
			if entry.sid == player.uid && len(entry.name) > 0 { return entry.name }
		}
	}
	return fmt.tprintf("Player %d", player.uid)
}

player_healthbars_render :: proc(client: ^Client) {
	show_bars, show_names := !client.hud_settings.hide_healthbars, !client.hud_settings.hide_nametags
	colors := menuui.health_colors(client.hud_settings) // Krunker's healthColT / healthColE, read once per frame.
	if !show_bars && !show_names { return }
	if !client.in_game || !client.mouse_state.locked || client.me == nil || !client.me.active && !g_death.active ||
		client.ui == nil || len(client.game.players) < 2 ||
		client.viewport_width <= 0 || client.viewport_height <= 0 { return }

	ui := client.ui
	ui_update(ui, f32(client.viewport_width), f32(client.viewport_height))
	// Krunker draws nameplates on its 2D overlay canvas, projected from 3D:
	// geometry never cuts a plate. Whether a plate exists at all is decided by
	// the line-of-sight gate and its fade (`nameplate_alpha`), so draw it whole, untested
	// against the world depth buffer and on top of the view model.
	view_projection := client.camera.projection_matrix * client.camera.world_inverse_matrix
	for player in client.game.players {
		if player == nil || player == client.me || player.is_you || !player.active || player.health <= 0 || player.max_health <= 0 || player.nameplate_alpha <= 0 { continue }
		anchor := player_nameplate_anchor(player)
		screen, visible := player_healthbar_project(view_projection, anchor, ui.width, ui.height)
		if !visible { continue }
		unit := ui.scale * player_nameplate_scale(client.camera.position, anchor)
		name := show_names ? player_nameplate_name(client, player) : ""
		name_width := show_names ? ui_measure_text(ui, name, nameplate_font_size(NAMEPLATE_NAME_SIZE)) : 0
		layout := player_nameplate_layout({screen.x, screen.y}, unit, name_width, show_bars)
		friendly := client.me.team != 0 && player.team == client.me.team
		alpha := player_nameplate_display_alpha(player.nameplate_alpha)
		if show_bars {
			progress := clamp(player.health/f32(player.max_health), 0, 1)
			color := shared.hex_to_vec(i32(friendly ? colors.team : colors.enemy))
			color.a *= alpha
			// Krunker: a rgba(0,0,0,0.4) backing the size of the bar, no border.
			ui_fill_rect(ui, {0, 0, 0, 0.4*alpha}, layout.bar_left, layout.bar_top, layout.bar_width, layout.bar_height)
			ui_fill_rect(ui, color, layout.bar_left, layout.bar_top, layout.bar_width*progress, layout.bar_height)
		}
		if show_names {
			// White, except enemies in team modes take the enemy colour.
			color := client.me.team != 0 && !friendly ? shared.hex_to_vec(0xff4444) : shared.Vec4{1, 1, 1, 1}
			color.a *= alpha
			ui_fill_text(ui, color, name, layout.name_x, layout.name_baseline, nameplate_font_size(layout.name_size))
		}
	}
}
