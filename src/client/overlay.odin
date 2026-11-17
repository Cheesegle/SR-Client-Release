package main

import "core:fmt"
import glfw "vendor:glfw"
import gl "vendor:OpenGL"
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
	// and counters, player panel, weapons, ammo, chat, FPS): drawn into a
	// cached texture only when something on it changed, then shown with
	// one draw call per frame.
	hud_cache_render(client)

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

// ------------------------------------------------------------ HUD cache

// The HUD is several hundred small draw calls (every box and every letter),
// so it is drawn into a texture and composited with one draw call per frame.
// It is redrawn only when something it shows changed (hud_signature), and at
// least HUD_CACHE_MIN_RATE times a second as a safety net for anything the
// signature misses (chat lines expiring, for instance).
HUD_CACHE_MIN_RATE :: 10.0
Hud_Cache :: struct { framebuffer, texture: u32, width, height: i32, drawn_at: f64, valid: bool, signature: u64 }
g_hud_cache: Hud_Cache

hud_cache_invalidate :: proc() { g_hud_cache.valid = false }

hud_cache_draw :: proc(client: ^Client) {
	krunker_hud_render(client)
	kill_chat_render(client) // Krunker's chat box: chat and kill lines
	fps_render(client)       // beside the timer, at the same UI Scale
	if client.scoreboard_open {
		// Tab board, kept clear of the round/objective HUD at the top center.
		board := client_scoreboard(client)
		scoreboard_render(client.ui, &board, 120*client.ui.scale)
	}
}

hud_cache_render :: proc(client: ^Client) {
	// The interface is batched (a handful of draws for the whole HUD), so the
	// HUD is drawn directly every frame on both renderers.
	hud_cache_draw(client)
}

// Everything the cached HUD shows, folded into one number (FNV-1a). Cheap:
// a few dozen values a frame, no drawing.
hud_signature :: proc(client: ^Client) -> u64 {
	h: u64 = 14695981039346656037
	mix :: proc(h: ^u64, value: u64) {
		v := value
		for _ in 0..<8 { h^ = (h^ ~ (v & 0xff)) * 1099511628211; v >>= 8 }
	}
	text :: proc(h: ^u64, value: string) {
		for i in 0..<len(value) { h^ = (h^ ~ u64(value[i])) * 1099511628211 }
		mix(h, u64(len(value)))
	}
	f :: proc(value: f32) -> u64 { return u64(transmute(u32)value) }
	mix(&h, u64(transmute(u32)client.ui.width)); mix(&h, u64(transmute(u32)client.ui.height))
	settings := client.hud_settings
	for b in transmute([size_of(settings)]u8)settings { h = (h ~ u64(b)) * 1099511628211 }
	text(&h, krunker_client_timer_label(client))
	mix(&h, u64(client.show_fps)); mix(&h, u64(client.fps_value))
	ping, received, available := client_ping(client)
	mix(&h, u64(u32(ping))); mix(&h, u64(received)); mix(&h, u64(available))
	mix(&h, u64(client.in_game)); mix(&h, u64(client.mouse_state.locked)); mix(&h, u64(g_death.active))
	mix(&h, u64(client.scoreboard_open)); mix(&h, u64(client.krunker.connected)); mix(&h, u64(client.local_practice))
	if me := client.me; me != nil {
		mix(&h, f(me.health)); mix(&h, u64(me.max_health)); mix(&h, u64(u32(me.class_index))); mix(&h, u64(u32(me.team)))
		mix(&h, u64(u32(me.loadout_index))); mix(&h, u64(me.kills)); mix(&h, u64(me.deaths))
		for id in me.loadout { mix(&h, u64(u32(id))) }
		for ammo in me.ammo { mix(&h, u64(u32(ammo))) }
		mix(&h, u64(uintptr(me.weapon)))
		if me.reload_timer > 0 { mix(&h, u64(me.reload_timer*60)) } // the reload fill, 60 steps a second
	} else { mix(&h, 0xdead) }
	match := &client.game.match
	for v in match.team_scores { mix(&h, u64(v)) }
	for v in match.round_wins { mix(&h, u64(v)) }
	mix(&h, u64(match.round_current)); mix(&h, u64(match.phase))
	mix(&h, u64(match.objective.rotation_remaining + 0.999)); mix(&h, u64(match.phase_remaining + 0.999))
	text(&h, krunker_client_countdown_label(client, glfw.GetTime()))
	world := &client.krunker_world
	mix(&h, u64(world.mode_index)); mix(&h, u64(world.map_index)); mix(&h, u64(world.rounds_total))
	for player in world.players {
		mix(&h, u64(u32(player.sid))); mix(&h, u64(player.score)); mix(&h, u64(player.kills)); mix(&h, u64(player.deaths))
		mix(&h, u64(u32(player.team))); text(&h, player.name)
	}
	for player in client.game.players {
		if player == nil { continue }
		mix(&h, u64(player.uid)); mix(&h, u64(player.score)); mix(&h, u64(player.kills)); mix(&h, u64(u32(player.team)))
	}
	mix(&h, g_chat.serial); mix(&h, u64(g_chat.count)); mix(&h, u64(g_chat.channel))
	mix(&h, u64(g_enemy_counter.count)); mix(&h, u64(g_enemy_counter.enemy_team))
	mix(&h, u64(len(g_map_name)))
	return h
}

hud_cache_fini :: proc() {
	if g_hud_cache.framebuffer != 0 { gl.DeleteFramebuffers(1, &g_hud_cache.framebuffer) }
	if g_hud_cache.texture != 0 { gl.DeleteTextures(1, &g_hud_cache.texture) }
	g_hud_cache = {}
}

overlay_fini :: proc() {
	hud_cache_fini()
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
