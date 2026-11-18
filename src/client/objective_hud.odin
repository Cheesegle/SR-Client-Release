package main

import "core:fmt"
import "core:math"
import "core:strings"
import menuui "../menu"
import shared "../shared"

// Krunker's hardpoint marker and its preview, drawn on the 2D overlay as the
// browser draws them on its canvas (checked against Krunker's game code,
// 2026-11-18):
//
// - The active hardpoint: a yellow (#FBC02D) diamond on a 40% black diamond,
//   the marker_0 chevrons, "Capture" above and the objective clock below,
//   7 units over the zone's centre. Hidden while the camera is inside it.
// - In the last 15 s of a rotation (with at least 5 s of the round left
//   after it), the next hardpoint gets a white diamond, the marker_0_next
//   chevrons and "Next", without a clock.
// - Size 70 * max(0.3, 1 - distance/600), drawn at size/144 scale, at
//   Krunker's "Opacity for Objective Info" (objOpac, default 1), or its
//   ADS opacity (adsObjOpac, default 0.5) while aiming down sights near the
//   screen centre. Settings > Video > Interface has both.
// - A Krunker mod replaces the icons as Krunker's resource packs do:
//   textures/objective_1.png or objective_7.png the marker, objective_6.png
//   or objective_8.png the "Next" marker.
// - Standing on the active point with more than one player on it (FFA
//   Hardpoint's uobj count): Krunker's CONTESTED box at 50% / 80%.
//
// Performance: a handful of boxes and letters per frame, objective modes only.

OBJECTIVE_MARKER_YELLOW :: shared.Vec4{0xFB/255.0, 0xC0/255.0, 0x2D/255.0, 1}
OBJECTIVE_TEXT_STROKE :: shared.Vec4{0x2e/255.0, 0x2e/255.0, 0x2e/255.0, 1}
OBJECTIVE_PREVIEW_MS :: 15000 // objtvTime <= 0x3a98
OBJECTIVE_PREVIEW_ROUND_MS :: 5000 // gameTimer - objtvTime >= 0x1388

// The loaded icons and the asset path each came from (a mod can change it).
@(private = "file") objective_marker_texture: Gpu_Texture
@(private = "file") objective_marker_next_texture: Gpu_Texture
@(private = "file") objective_marker_source: string
@(private = "file") objective_marker_next_source: string

// Krunker's resource-pack hook (updateObjectiveMarker / updateNextObjectiveMarker).
OBJECTIVE_MARKER_MOD_FILES := [2][2]string{{"textures/objective_1.png", "textures/objective_7.png"}, {"textures/objective_6.png", "textures/objective_8.png"}}

// The icon's asset path: a loaded mod's objective_* replacement, else
// Krunker's marker_0 / marker_0_next.
objective_marker_source_path :: proc(next: bool) -> string {
	if shared.g_mods.ready && len(shared.g_mods.index) > 0 {
		for name in OBJECTIVE_MARKER_MOD_FILES[next ? 1 : 0] {
			if name in shared.g_mods.index { return name }
		}
	}
	return next ? "textures/marker_0_next.png" : "textures/marker_0.png"
}

@(private = "file")
objective_marker_icon :: proc(next: bool) -> Gpu_Texture {
	texture := next ? &objective_marker_next_texture : &objective_marker_texture
	source := next ? &objective_marker_next_source : &objective_marker_source
	path := objective_marker_source_path(next)
	if path != source^ {
		texture_release(texture^); texture^ = 0
		delete(source^); source^ = strings.clone(path)
	}
	return kh_load(texture, path, smooth = true)
}

// Krunker's globalAlpha for the marker: adsObjectiveOpacity while aiming
// (aimVal != 1) at a marker in the middle of the screen, else objectiveOpacity.
objective_marker_alpha :: proc(settings: menuui.HUD_Settings, aiming, near_centre: bool) -> f32 {
	return aiming && near_centre ? menuui.ads_objective_opacity(settings) : menuui.objective_opacity(settings)
}

// Krunker's canvas textBaseline. FrVrKrunkerBold's ascent and descent are
// 1.5 and 0.25 em (KH_ASCENT, KH_LINE); Chrome puts "top" an ascent above
// the baseline and "middle" half of ascent minus descent.
Canvas_Baseline :: enum { ALPHABETIC, MIDDLE, TOP }

// One strokeText + fillText pair of "<px>px GameFont" (px in screen pixels),
// centred on x unless left is set. The stroke is the canvas line of
// `stroke_width` pixels, drawn as copies around the glyphs.
canvas_text :: proc(ui: ^UI, color: shared.Vec4, text: string, x, y, px: f32, baseline := Canvas_Baseline.ALPHABETIC, stroke := shared.Vec4{}, stroke_width: f32 = 0, stroke_dx: f32 = 0, left := false) {
	if len(text) == 0 || px <= 0 { return }
	size := nameplate_font_size(px)
	width := ui_measure_text(ui, text, size)
	start := left ? x : x - width*0.5
	base := y
	switch baseline {
	case .ALPHABETIC:
	case .MIDDLE: base += px*(KH_ASCENT - (KH_LINE - KH_ASCENT))*0.5
	case .TOP: base += px*KH_ASCENT
	}
	if stroke_width > 0 && stroke.a > 0 {
		radius := stroke_width*0.5
		steps := radius > 3 ? 16 : 8
		for i in 0..<steps {
			angle := f32(i)*2*math.PI/f32(steps)
			ui_fill_text(ui, stroke, text, start + stroke_dx + math.cos(angle)*radius, base + math.sin(angle)*radius, size)
		}
	}
	ui_fill_text(ui, color, text, start, base, size)
}

// Krunker's v10495: seconds of the minute, then tenths ("07:3").
objective_clock_text :: proc(seconds: f32) -> string {
	ms := max(0, int(seconds*1000))
	return fmt.tprintf("%02d:%d", (ms/1000)%60, (ms%1000)/100)
}

// The objective whose uid is active+1, else uid 0 (getNextObjective).
objective_next_uid :: proc(game: ^shared.Game, active: i32) -> i32 {
	if game.map_inst == nil { return 0 }
	for index in game.objective_indices {
		if game.map_inst.objects[index].objective_id == active + 1 { return active + 1 }
	}
	return 0
}

objective_preview_due :: proc(rotation_remaining, time_remaining: f32) -> bool {
	objective_ms := rotation_remaining*1000
	return objective_ms <= OBJECTIVE_PREVIEW_MS && time_remaining*1000 - objective_ms >= OBJECTIVE_PREVIEW_ROUND_MS
}

// The browser's v10582 against the zone's centre and half extents.
objective_contains :: proc(object: ^shared.Object, point: shared.Vec3) -> bool {
	half := object.scale*0.5
	centre := object.position + shared.Vec3{0, half.y, 0}
	return abs(point.x - centre.x) <= half.x && abs(point.y - centre.y) <= half.y && abs(point.z - centre.z) <= half.z
}

objective_hud_render :: proc(client: ^Client) {
	game := &client.game
	if game.mode == nil || !game.mode.objective || game.map_inst == nil || len(game.objective_indices) == 0 { return }
	// The browser draws it only without the death screen.
	if client.me == nil || !client.me.active || g_death.active || client.viewport_width <= 0 || client.viewport_height <= 0 { return }
	ui := client.ui
	match := &game.match
	active := match.objective.active_zone
	if active < 0 { return }
	camera := client.camera.position
	view_projection := client.camera.projection_matrix * client.camera.world_inverse_matrix
	preview := objective_preview_due(match.objective.rotation_remaining, match.time_remaining)
	next := objective_next_uid(game, active)
	for index in game.objective_indices {
		object := game.map_inst.objects[index]
		inside := objective_contains(object, camera)
		if object.objective_id == active {
			if !inside { objective_marker_draw(client, view_projection, object, false) }
			// CONTESTED: you are on the point and so is someone else.
			if client.krunker.connected && client.krunker_world.objective_occupants > 1 && shared.player_collides(client.me, object, 0) {
				objective_contested_render(ui)
			}
		} else if preview && object.objective_id == next && !inside {
			objective_marker_draw(client, view_projection, object, true)
		}
	}
}

@(private = "file")
objective_marker_draw :: proc(client: ^Client, view_projection: shared.Mat4, object: ^shared.Object, next: bool) {
	ui := client.ui
	anchor := object.position + shared.Vec3{0, object.scale.y*0.5 + 7, 0}
	d := anchor - client.camera.position
	size := 70*max(0.3, 1 - math.sqrt(d.x*d.x + d.y*d.y + d.z*d.z)/600)
	if size < 1 { return }
	screen, visible := player_healthbar_project(view_projection, anchor, ui.width, ui.height)
	if !visible { return }
	// Canvas units are ui.scale pixels; the marker is drawn at size/144.
	k := ui.scale*size/144
	aiming := client.me.aim_val != 1
	near_centre := screen.x >= 0.45*ui.width && screen.x <= 0.55*ui.width && screen.y >= 0.4*ui.height && screen.y <= 0.6*ui.height
	alpha := objective_marker_alpha(client.hud_settings, aiming, near_centre)
	if alpha <= 0 { return }

	label := next ? "Next" : "Capture"
	white := shared.Vec4{1, 1, 1, alpha}
	stroke := shared.Vec4{OBJECTIVE_TEXT_STROKE.r, OBJECTIVE_TEXT_STROKE.g, OBJECTIVE_TEXT_STROKE.b, alpha}
	canvas_text(ui, white, label, screen.x, screen.y - 104*k, 35*k, .MIDDLE, stroke, 4*k)
	if !next {
		canvas_text(ui, white, objective_clock_text(client.game.match.objective.rotation_remaining), screen.x, screen.y + 104*k, 35*k, .TOP, stroke, 4*k)
	}

	// Two squares turned 45 degrees about (0.5, 0.5): 104 black at 40%, then
	// 80 in yellow (white for the preview).
	cx, cy := screen.x + 0.5*k, screen.y + 0.5*k
	diamond :: proc(ui: ^UI, color: shared.Vec4, cx, cy, half: f32) {
		r := half*math.SQRT_TWO
		points := [4]shared.Vec2{{cx, cy - r}, {cx + r, cy}, {cx, cy + r}, {cx - r, cy}}
		ui_fill_polygon(ui, color, points[:])
	}
	diamond(ui, {0, 0, 0, 0.4*alpha}, cx, cy, 52*k)
	fill := next ? shared.Vec4{1, 1, 1, alpha} : shared.Vec4{OBJECTIVE_MARKER_YELLOW.r, OBJECTIVE_MARKER_YELLOW.g, OBJECTIVE_MARKER_YELLOW.b, alpha}
	diamond(ui, fill, cx, cy, 40*k)
	texture := objective_marker_icon(next)
	if texture != 0 { ui_draw_image(ui, texture, screen.x - 32*k, screen.y - 32*k, 64*k, 64*k, {1, 1, 1, alpha}) }
}

// captureProg: left 50%, top 80%; a #333 box at 80% and 20px white text.
@(private = "file")
objective_contested_render :: proc(ui: ^UI) {
	s := ui.scale
	x, y := ui.width*0.5, ui.height*0.8
	label :: "CONTESTED"
	width := ui_measure_text(ui, label, nameplate_font_size(20*s))
	ui_fill_rect(ui, {0x33/255.0, 0x33/255.0, 0x33/255.0, 0.8}, x - (width + 50*s)*0.5, y - 57.5*s, width + 50*s, 50*s)
	canvas_text(ui, {1, 1, 1, 1}, label, x, y - 20*s, 20*s)
}

objective_hud_fini :: proc() {
	texture_release(objective_marker_texture); objective_marker_texture = 0
	texture_release(objective_marker_next_texture); objective_marker_next_texture = 0
	delete(objective_marker_source); objective_marker_source = ""
	delete(objective_marker_next_source); objective_marker_next_source = ""
}
