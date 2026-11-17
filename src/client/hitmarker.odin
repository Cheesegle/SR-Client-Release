package main

import "core:math"
import menuui "../menu"
import shared "../shared"

// Krunker's hitmarker (Krunker's client): four bars rotated 45 degrees around
// the crosshair. Each frame the spacing grows by Anim size and the opacity
// drops by Fade speed per millisecond; the marker ends at zero opacity.
Hit_Marker :: struct {
	active: bool,
	opacity, spacing, length: f32,
	// Image hitmarker (Krunker's animateDiv(hitmarker, 350, 100, 105)): shown
	// for 350 ms at full opacity, fading over the last 100 ms, 105x105.
	image_life: f32,
	color: u32,
	revision: u64, // The last live hit confirmation shown.
}

hit_marker_show :: proc(marker: ^Hit_Marker, settings: menuui.Hitmarker_Settings, kill, headshot: bool) {
	if !settings.show { return }
	marker.active = true
	marker.opacity = settings.values[.OPACITY]
	marker.spacing = settings.values[.SPACING]
	marker.length = settings.values[.LENGTH] * (kill ? 1.2 : 1)
	marker.color = settings.colors[kill ? .KILL : headshot ? .HEADSHOT : .NORMAL]
	marker.image_life = HIT_MARKER_IMAGE_LIFE
}

HIT_MARKER_IMAGE_LIFE :: 0.35
HIT_MARKER_IMAGE_FADE :: 0.1
HIT_MARKER_IMAGE_SIZE :: 105

hit_marker_tick :: proc(marker: ^Hit_Marker, settings: menuui.Hitmarker_Settings, delta: f32) {
	if !marker.active { return }
	ms := max(delta, 0) * 1000
	marker.spacing += settings.values[.ANIM_SIZE] * ms
	marker.opacity = max(marker.opacity - settings.values[.FADE] * ms, 0)
	marker.image_life = max(marker.image_life - max(delta, 0), 0)
	if marker.opacity <= 0 && (len(settings.image_url) == 0 || marker.image_life <= 0) { marker.active = false }
}

// The four bars as screen-space quads around (cx, cy). Units are Krunker
// canvas pixels multiplied by scale, as the crosshair uses.
hit_marker_quads :: proc(marker: Hit_Marker, thickness, cx, cy, scale: f32) -> (quads: [4][4]shared.Vec2) {
	t, l, sp := thickness*0.5, marker.length*0.5, marker.spacing
	// Canvas rects before the 45 degree rotation: two vertical bars above and
	// below the center, two horizontal bars left and right of it.
	rects := [4][4]f32{{-t, -sp-l, t, -sp+l}, {-t, sp-l, t, sp+l}, {-sp-l, -t, -sp+l, t}, {sp-l, -t, sp+l, t}}
	c, s := f32(math.SQRT_TWO*0.5), f32(math.SQRT_TWO*0.5)
	for rect, i in rects {
		corners := [4]shared.Vec2{{rect[0], rect[1]}, {rect[2], rect[1]}, {rect[2], rect[3]}, {rect[0], rect[3]}}
		for p, j in corners { quads[i][j] = {cx + (p.x*c - p.y*s)*scale, cy + (p.x*s + p.y*c)*scale} }
	}
	return
}

hit_marker_render :: proc(ui: ^UI, marker: Hit_Marker, settings: menuui.Hitmarker_Settings, cx, cy, scale: f32) {
	if !marker.active || scale <= 0 { return }
	if len(settings.image_url) > 0 {
		if texture := crosshair_image_texture(settings.image_url, &g_hitmarker_image); texture != 0 {
			// As Krunker: a 105x105 image (Krunker HUD pixels) centered on the
			// crosshair, full opacity, fading out over its last 100 ms.
			if marker.image_life <= 0 { return }
			alpha := min(marker.image_life / HIT_MARKER_IMAGE_FADE, 1)
			half := HIT_MARKER_IMAGE_SIZE * 0.5 * scale
			ui_draw_image(ui, texture, cx - half, cy - half, half*2, half*2, {1, 1, 1, alpha})
			return
		}
	}
	if marker.opacity <= 0 { return }
	color := shared.hex_to_vec(i32(marker.color))
	color.a = min(marker.opacity, 1)
	quads := hit_marker_quads(marker, settings.values[.THICKNESS], cx, cy, scale)
	for quad in quads {
		points := quad
		ui_fill_polygon(ui, color, points[:])
	}
}

// The menu preview replays a body hit, a headshot and a kill, one per second.
hit_marker_preview :: proc(ui: ^UI, settings: menuui.Hitmarker_Settings, cx, cy, scale: f32, now: f64) {
	cycle := int(math.floor(now))
	marker: Hit_Marker
	preview := settings
	preview.show = true
	hit_marker_show(&marker, preview, cycle%3 == 2, cycle%3 == 1)
	hit_marker_tick(&marker, preview, f32(now - math.floor(now)))
	hit_marker_render(ui, marker, preview, cx, cy, scale)
}

client_hitmarker_values :: proc(client: ^Client) -> menuui.Hitmarker_Settings {
	settings := client.hitmarker_settings
	if client.menu.settings_active && client.menu.page == .SETTINGS { settings = client.menu.settings_draft.hitmarker }
	return menuui.hitmarker_settings_validate(settings)
}

// Offline and native local hits arrive as HIT presentation events from
// player_apply_damage; uid is the attacker.
client_hit_marker_present :: proc(client: ^Client, event: shared.Presentation_Event) {
	if event.kind != .HIT || client.me == nil || event.uid != client.me.uid { return }
	hit_marker_show(&client.hit_marker, client_hitmarker_values(client), event.lethal, event.headshot)
}

// Live hits are the server's DO_DAMAGE confirmations; native multiplayer hits
// are server bullet impacts on players fired by the local player.
client_hit_marker_tick_live :: proc(client: ^Client) {
	if !client.krunker.connected { return }
	world := &client.krunker_world
	if world.hit_revision == client.hit_marker.revision { return }
	client.hit_marker.revision = world.hit_revision
	if world.hit_revision > 0 { hit_marker_show(&client.hit_marker, client_hitmarker_values(client), world.hit_lethal, world.hit_headshot) }
}

client_hit_marker_native_impact :: proc(client: ^Client, impact: shared.Bullet_Impact) {
	if impact.kind != .Player || client.me == nil || impact.shooter_uid != client.me.uid { return }
	hit_marker_show(&client.hit_marker, client_hitmarker_values(client), false, false)
}
