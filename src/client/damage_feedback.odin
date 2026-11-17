package main

import "core:math"
import gl "vendor:OpenGL"
import menuui "../menu"
import shared "../shared"

// Damage feedback for the local player, after Krunker's damage overlay
// (blood.png at opacity 1 - health/0.8, Krunker's client) and its hit
// indicators (a red arrowhead
// a quarter screen from the center, pointing at the attacker, fading over
// 2 s). The flash on each hit is SR Client's own.
DAMAGE_INDICATOR_COUNT :: 8
DAMAGE_FLASH_PEAK :: 0.6
DAMAGE_VIGNETTE_SIZE :: 256

Damage_Indicator :: struct { life, duration: f32, source: [2]f32 } // source is world x/z.
Damage_Feedback :: struct {
	flash: f32, // Seconds left in the current flash.
	indicators: [DAMAGE_INDICATOR_COUNT]Damage_Indicator,
	revision: u64, // The last live CHANGE_HEALTH drop shown.
}

damage_feedback_hit :: proc(feedback: ^Damage_Feedback, settings: menuui.Damage_Settings, source: Maybe([2]f32)) {
	if settings.toggles[.OVERLAY] { feedback.flash = settings.values[.FLASH_DURATION] }
	position, has_source := source.?
	if !has_source || !settings.toggles[.INDICATORS] { return }
	// Krunker reuses the first expired slot; with every slot busy, replace the oldest.
	slot := 0
	for indicator, i in feedback.indicators { if indicator.life < feedback.indicators[slot].life { slot = i } }
	duration := settings.values[.INDICATOR_DURATION]
	feedback.indicators[slot] = {duration, duration, position}
}

damage_feedback_tick :: proc(feedback: ^Damage_Feedback, delta: f32) {
	step := max(delta, 0)
	feedback.flash = max(feedback.flash - step, 0)
	for &indicator in feedback.indicators { indicator.life = max(indicator.life - step, 0) }
}

// Overlay opacity: Krunker's health term (none above 80% health) or the
// fading hit flash, whichever is stronger, scaled by intensity.
damage_overlay_alpha :: proc(settings: menuui.Damage_Settings, health, max_health: f32, alive: bool, flash: f32) -> f32 {
	if !settings.toggles[.OVERLAY] { return 0 }
	health_alpha: f32
	if alive && max_health > 0 { health_alpha = clamp(1 - health/max_health/0.8, 0, 1) }
	flash_alpha: f32
	if duration := settings.values[.FLASH_DURATION]; duration > 0 { flash_alpha = DAMAGE_FLASH_PEAK * clamp(flash/duration, 0, 1) }
	return settings.values[.OVERLAY_INTENSITY] * max(health_alpha, flash_alpha)
}

// A white vignette whose alpha and brightness follow Krunker's blood.png:
// alpha 215/255 at the edge falling to 30/255 by a third of the way in, and
// edges at 44% of the center brightness. The overlay color tints it.
damage_vignette_pixels :: proc(allocator := context.allocator) -> []u8 {
	ALPHA := [?][2]f32{{0,215}, {8,199}, {16,181}, {24,159}, {32,134}, {48,90}, {64,57}, {80,39}, {96,32}, {112,30}, {128,30}}
	SHADE := [?][2]f32{{0,0.4375}, {8,0.464}, {16,0.526}, {24,0.604}, {32,0.682}, {48,0.844}, {64,0.964}, {80,1}, {128,1}}
	lookup :: proc(table: [][2]f32, t: f32) -> f32 {
		for i in 1..<len(table) {
			if t <= table[i][0] { return math.lerp(table[i-1][1], table[i][1], (t-table[i-1][0])/(table[i][0]-table[i-1][0])) }
		}
		return table[len(table)-1][1]
	}
	alpha_table, shade_table := ALPHA, SHADE
	pixels := make([]u8, DAMAGE_VIGNETTE_SIZE*DAMAGE_VIGNETTE_SIZE*4, allocator)
	half := f32(DAMAGE_VIGNETTE_SIZE)*0.5
	for y in 0..<DAMAGE_VIGNETTE_SIZE {
		for x in 0..<DAMAGE_VIGNETTE_SIZE {
			// Distance from the nearest edge on each axis, in blood.png pixels.
			dx := min(f32(x)+0.5, f32(DAMAGE_VIGNETTE_SIZE-x)-0.5) * 128/half
			dy := min(f32(y)+0.5, f32(DAMAGE_VIGNETTE_SIZE-y)-0.5) * 128/half
			// The two edges combine like overlapping layers, so corners are strongest.
			ex, ey := (lookup(alpha_table[:], dx)-30)/225, (lookup(alpha_table[:], dy)-30)/225
			alpha := 30 + 225*(1-(1-ex)*(1-ey))
			shade := lookup(shade_table[:], dx) * lookup(shade_table[:], dy)
			i := (y*DAMAGE_VIGNETTE_SIZE+x)*4
			value := u8(clamp(shade*255, 0, 255))
			pixels[i], pixels[i+1], pixels[i+2], pixels[i+3] = value, value, value, u8(clamp(alpha, 0, 255))
		}
	}
	return pixels
}

damage_vignette_texture :: proc() -> u32 {
	pixels := damage_vignette_pixels(context.temp_allocator)
	texture: u32
	gl.GenTextures(1, &texture)
	gl.BindTexture(gl.TEXTURE_2D, texture)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, DAMAGE_VIGNETTE_SIZE, DAMAGE_VIGNETTE_SIZE, 0, gl.RGBA, gl.UNSIGNED_BYTE, raw_data(pixels))
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	g_active_texture = 0 // The bind above bypassed the material binding cache.
	return texture
}

damage_overlay_render :: proc(ui: ^UI, color: u32, alpha: f32, x, y, width, height: f32) {
	if alpha <= 0 || ui.vignette == 0 { return }
	tint := shared.hex_to_vec(i32(color))
	tint.a = min(alpha, 1)
	ui_draw_image(ui, ui.vignette, x, y, width, height, tint)
}

// Krunker's indicator outline in canvas units, tip first. y grows toward the
// screen center; the tip sits `radius` from it.
damage_indicator_outline :: proc() -> (points: [20]shared.Vec2, count: int) {
	add :: proc(points: ^[20]shared.Vec2, count: ^int, p: shared.Vec2) { points[count^] = p; count^ += 1 }
	add(&points, &count, {0, 22}) // Fan center, inside the shape.
	add(&points, &count, {0, 0})
	add(&points, &count, {10, 20})
	add(&points, &count, {90, 55})
	// bezierCurveTo(0, 25, 0, 25, -90, 55) from (90, 55).
	for i in 1..<14 {
		t := f32(i)/14
		u := 1-t
		add(&points, &count, {90*u*u*u - 90*t*t*t, 55*(u*u*u + t*t*t) + 25*3*t*u})
	}
	add(&points, &count, {-90, 55})
	add(&points, &count, {-10, 20})
	add(&points, &count, {0, 0})
	return
}

// direction is the unit screen direction (y down) toward the attacker.
damage_indicator_render :: proc(ui: ^UI, color: u32, alpha: f32, cx, cy, radius, scale: f32, direction: shared.Vec2) {
	if alpha <= 0 { return }
	tint := shared.hex_to_vec(i32(color))
	tint.a = min(alpha, 1)
	outline, count := damage_indicator_outline()
	perp := shared.Vec2{-direction.y, direction.x}
	points: [20]shared.Vec2
	for p, i in outline[:count] {
		along := radius - p.y*scale
		points[i] = {cx + direction.x*along + perp.x*p.x*scale, cy + direction.y*along + perp.y*p.x*scale}
	}
	ui_fill_polygon(ui, tint, points[:count])
}

// Screen direction (y down) from the player toward a world x/z, for a camera
// with this yaw: straight ahead points up.
damage_indicator_direction :: proc(player: shared.Vec3, yaw: f32, source: [2]f32) -> (shared.Vec2, bool) {
	dx, dz := source[0]-player.x, source[1]-player.z
	forward := shared.Vec2{-math.sin(yaw), -math.cos(yaw)}
	right := shared.Vec2{math.cos(yaw), -math.sin(yaw)}
	screen := shared.Vec2{dx*right.x + dz*right.y, -(dx*forward.x + dz*forward.y)}
	length := math.sqrt(screen.x*screen.x + screen.y*screen.y)
	if length < 0.0001 { return {}, false }
	return screen/length, true
}

client_damage_values :: proc(client: ^Client) -> menuui.Damage_Settings {
	settings := client.damage_settings
	if client.menu.settings_active && client.menu.page == .SETTINGS { settings = client.menu.settings_draft.damage }
	return menuui.damage_settings_validate(settings)
}

// Offline and native damage arrives as DAMAGE presentation events; local
// hits from player_apply_damage carry the attacker's position.
client_damage_present :: proc(client: ^Client, event: shared.Presentation_Event) {
	if event.kind != .DAMAGE || client.me == nil || event.uid != client.me.uid { return }
	source: Maybe([2]f32)
	if event.has_source { source = [2]f32{event.source.x, event.source.z} }
	damage_feedback_hit(&client.damage_feedback, client_damage_values(client), source)
}

// Live damage: CHANGE_HEALTH drops that name the attacker's position.
client_damage_tick_live :: proc(client: ^Client) {
	if !client.krunker.connected { return }
	world := &client.krunker_world
	if world.damage_revision == client.damage_feedback.revision { return }
	client.damage_feedback.revision = world.damage_revision
	if world.damage_revision > 0 { damage_feedback_hit(&client.damage_feedback, client_damage_values(client), world.damage_source) }
}

client_damage_render :: proc(client: ^Client, delta: f32) {
	feedback := &client.damage_feedback
	damage_feedback_tick(feedback, delta)
	settings := client_damage_values(client)
	player := client.me
	if player == nil { return }
	ui := client.ui
	alpha := damage_overlay_alpha(settings, player.health, f32(player.max_health), player.active, feedback.flash)
	damage_overlay_render(ui, settings.colors[.OVERLAY], alpha, 0, 0, ui.width, ui.height)
	if !settings.toggles[.INDICATORS] || !player.active { return }
	// Krunker: tip at a quarter of the screen height minus 83 canvas units.
	radius := max(ui.height*0.25 - 83*ui.scale, 60*ui.scale)
	for indicator in feedback.indicators {
		if indicator.life <= 0 || indicator.duration <= 0 { continue }
		direction, ok := damage_indicator_direction(player.position, client.camera.rotation.y, indicator.source)
		if !ok { continue }
		damage_indicator_render(ui, settings.colors[.INDICATOR], indicator.life/indicator.duration, ui.width*0.5, ui.height*0.5, radius, ui.scale, direction)
	}
}

// The HUD settings preview: the overlay at 40% health with a flash every
// 1.5 s, and an indicator toward the upper right that fades on the same beat.
damage_preview_render :: proc(ui: ^UI, settings: menuui.Damage_Settings, x, y, width, height: f32, now: f64) {
	phase := f32(now - math.floor(now/1.5)*1.5)
	flash := max(settings.values[.FLASH_DURATION] - phase, 0)
	damage_overlay_render(ui, settings.colors[.OVERLAY], damage_overlay_alpha(settings, 40, 100, true, flash), x, y, width, height)
	if !settings.toggles[.INDICATORS] { return }
	life := max(settings.values[.INDICATOR_DURATION] - phase, 0) / settings.values[.INDICATOR_DURATION]
	damage_indicator_render(ui, settings.colors[.INDICATOR], life, x+width*0.5, y+height*0.5, height*0.42, height/400, {math.SQRT_TWO*0.5, -math.SQRT_TWO*0.5})
}
