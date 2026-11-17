package main

import "core:fmt"
import glfw "vendor:glfw"
import shared "../shared"

ammo_icon: Gpu_Texture
timer_icon: Gpu_Texture
health_icon: Gpu_Texture
class_icons: map[i32]Gpu_Texture
weapon_icons: map[i32]Gpu_Texture
scope_icon: Gpu_Texture

// Use the same interpolated aim as the first-person rig and camera.
overlay_scope_active :: proc(client: ^Client) -> bool {
	player := client.me
	if player == nil || !player.active || player.weapon == nil || !player.weapon.scope || player_uses_third_person_camera(player) { return false }
	aim := player.aim_val
	if client.krunker.connected { aim = krunker_client_render_sample(client).aim }
	return player_scope_visible(player, aim)
}

overlay_scope_render :: proc(ui: ^UI) {
	if scope_icon == 0 {
		path := shared.concat(shared.assets_path(), "textures/scopes/scope_0.png")
		scope_icon = load_texture(path)
		delete(path)
	}
	// A square scope stays circular on every aspect ratio; fill the outside.
	size := min(ui.width, ui.height)
	x, y := (ui.width - size) * 0.5, (ui.height - size) * 0.5
	black := shared.Vec4{0, 0, 0, 1}
	ui_fill_rect(ui, black, 0, 0, x, ui.height)
	ui_fill_rect(ui, black, x + size, 0, x, ui.height)
	ui_fill_rect(ui, black, x, 0, size, y)
	ui_fill_rect(ui, black, x, y + size, size, y)
	if scope_icon != 0 {
		ui_draw_image(ui, scope_icon, x, y, size, size)
	} else {
		ui_fill_rect(ui, black, ui.width * 0.5 - 1, ui.height * 0.5 - 16, 2, 32)
		ui_fill_rect(ui, black, ui.width * 0.5 - 16, ui.height * 0.5 - 1, 32, 2)
	}
}

// Center the visible numerals within a HUD row using the active font's metrics.
overlay_numeric_baseline :: proc(top, height, text_size: f32) -> f32 {
	text_height := text_size * 0.5
	if glyph := load_glyph('0'); glyph != nil {
		text_height = glyph.h_bearing.y * text_size / 100.0
	}
	return top + (height + text_height) * 0.5
}

overlay_icon_filter :: proc(icon: Gpu_Texture) {
	if icon == 0 { return }
	gpu_texture_set_filter(icon, .Linear)
}

// HUD silhouettes (textures/weapons or textures/melee), shared by the loadout
// list and the killfeed. Returns 0 when the icon is missing.
overlay_weapon_icon :: proc(client: ^Client, weapon_id: i32) -> (Gpu_Texture, ^shared.Weapon) {
	if weapon_id < 0 || int(weapon_id) >= len(client.game.weapons) { return 0, nil }
	weapon := client.game.weapons[weapon_id]
	if weapon == nil { return 0, nil }
	if weapon_icons == nil { weapon_icons = make(map[i32]Gpu_Texture) }
	icon, cached := weapon_icons[weapon_id]
	if !cached {
		folder := "melee" if weapon.melee else "weapons"
		path := shared.concat(shared.assets_path(), fmt.tprintf("textures/%s/%s.png", folder, weapon.icon))
		icon = load_texture(path)
		delete(path)
		weapon_icons[weapon_id] = icon
		overlay_icon_filter(icon)
	}
	return icon, weapon
}

// The window's UI scale before Krunker's UI Scale (restored after the HUD).
g_hud_base_scale: f32 = 1

overlay_render :: proc(client: ^Client, delta: f32) {
	// Settings > Display > UI Scale (Krunker's scaleUI) and Krunker font.
	g_hud_base_scale = client.ui.scale
	client.ui.scale = krunker_hud_scale(client)
	if !client.hud_settings.classic_font { ui_use_font(.GAME) }
	defer { client.ui.scale = g_hud_base_scale; ui_use_font(.UI) }
	scoped := overlay_scope_active(client)
	if scoped { overlay_scope_render(client.ui) }
	// Under the HUD, as Krunker draws its blood overlay and hit indicators.
	client_damage_render(client, delta)
	if client.hud_settings.hide_hud {
		// Settings > Display > Show HUD off: only what aiming needs.
		crosshair := client_crosshair_values(client)
		if !client.scoreboard_open { crosshair_render(client.ui, crosshair, client.ui.width*0.5, client.ui.height*0.5, client.ui.scale, client_crosshair_opacity(client, crosshair)) }
		hitmarker := client_hitmarker_values(client)
		hit_marker_tick(&client.hit_marker, hitmarker, delta)
		hit_marker_render(client.ui, client.hit_marker, hitmarker, client.ui.width*0.5, client.ui.height*0.5, client.ui.scale)
		if chat_typing() { kill_chat_render(client) }
		death_cam_render(client)
		return
	}

	// Krunker's HUD (timer and match info, team scores, rounds, leaderboard
	// and counters, player panel, weapons, ammo, chat, FPS).
	hud_draw(client)

	// Normally fades out for ADS, leaving the scope's own reticle. Always show
	// and custom opacity can explicitly keep Precision visible over the scope.
	// The browser also hides its crosshair while the leaderboard is open.
	crosshair := client_crosshair_values(client)
	if !client.scoreboard_open { crosshair_render(client.ui, crosshair, client.ui.width*0.5, client.ui.height*0.5, client.ui.scale, client_crosshair_opacity(client, crosshair)) }

	// Server-confirmed hits; Krunker draws the marker even with the board open.
	hitmarker := client_hitmarker_values(client)
	hit_marker_tick(&client.hit_marker, hitmarker, delta)
	hit_marker_render(client.ui, client.hit_marker, hitmarker, client.ui.width*0.5, client.ui.height*0.5, client.ui.scale)
	if client.krunker.connected {
		progress := client.krunker_world.interact_progress
		if client.krunker_world.interact_manual_visible { progress = client.krunker_world.interact_manual_progress }
		if progress > 0 {
			w, h := 180*client.ui.scale, 8*client.ui.scale
			x, y := (client.ui.width-w)*0.5, client.ui.height*0.6
			ui_fill_rect(client.ui, shared.Vec4{0, 0, 0, 0.4}, x, y, w, h)
			ui_fill_rect(client.ui, shared.Vec4{1, 1, 1, 1}, x, y, w*progress, h)
		}
	}

	round_hud_render(client)
	death_cam_render(client)
}

// ------------------------------------------------------------ HUD

// The HUD goes through the interface draw list (ui_box), which batches its
// boxes and letters into a few draws, so it is drawn every frame on both
// renderers instead of being cached in an offscreen texture.
hud_draw :: proc(client: ^Client) {
	krunker_hud_render(client)
	kill_chat_render(client) // Krunker's chat box: chat and kill lines
	fps_render(client)       // beside the timer, at the same UI Scale
	if client.scoreboard_open {
		// Tab board, kept clear of the round/objective HUD at the top center.
		board := client_scoreboard(client)
		scoreboard_render(client.ui, &board, 120*client.ui.scale)
	}
}

overlay_fini :: proc() {
	kill_feed_fini()
	for _, icon in weapon_icons {
		texture_release(icon)
	}
	delete(weapon_icons)
	weapon_icons = nil

	for _, icon in class_icons {
		texture_release(icon)
	}
	delete(class_icons)
	class_icons = nil

	texture_release(health_icon)
	texture_release(ammo_icon)
	texture_release(timer_icon)
	texture_release(scope_icon)
	scope_icon = 0
	health_icon = 0
	ammo_icon = 0
	timer_icon = 0
	g_ammo_icon_aspect = 0
	texture_release(skull_icon_kills)
	texture_release(skull_icon_deaths)
	skull_icon_kills, skull_icon_deaths = 0, 0
}
