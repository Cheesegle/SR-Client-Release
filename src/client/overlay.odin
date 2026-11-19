package main

import "core:fmt"
import "core:math"
import glfw "vendor:glfw"
import shared "../shared"
import menuui "../menu"

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

// Krunker's scope overlay: the aimRecticle image (scopeWidth x scopeHeight
// x100 px, centred, globalAlpha scopeOpac) and, when scopeBorders.display,
// four bars of scopeBorderOpac filling the screen outside it, each
// overlapping the image by 2 px:
//   rect(0,0,c,d/2-h/2+2) rect(0,d/2+h/2-2,c,...) rect(0,0,c/2-w/2+2,d) rect(c/2+w/2-2,0,...)
overlay_scope_render :: proc(ui: ^UI, hud: menuui.HUD_Settings) {
	opacity := menuui.scope_value(hud, 0)
	border_opacity := hud.scope_borders ? menuui.scope_value(hud, 1) : 0
	if opacity <= 0 && border_opacity <= 0 { return }
	w, h := menuui.scope_value(hud, 2) * 100, menuui.scope_value(hud, 3) * 100
	c, d := ui.width, ui.height
	if border_opacity > 0 {
		black := shared.Vec4{0, 0, 0, border_opacity}
		top := d/2 - h/2 + 2
		bottom := d/2 + h/2 - 2
		left := c/2 - w/2 + 2
		right := c/2 + w/2 - 2
		ui_fill_rect(ui, black, 0, 0, c, max(top, 0))
		ui_fill_rect(ui, black, 0, bottom, c, max(d - bottom, 0))
		// The side bars only between the top and bottom ones, so overlapping
		// translucent rects do not darken the corners twice.
		ui_fill_rect(ui, black, 0, top, max(left, 0), bottom - top)
		ui_fill_rect(ui, black, right, top, max(c - right, 0), bottom - top)
	}
	if opacity > 0 {
		if scope_icon == 0 {
			path := shared.concat(shared.assets_path(), "textures/scopes/scope_0.png")
			scope_icon = load_texture(path)
			delete(path)
		}
		if scope_icon != 0 { ui_draw_image(ui, scope_icon, c/2 - w/2, d/2 - h/2, w, h, {1, 1, 1, opacity}) }
	}
}

// Krunker's interactMProg: the charge bar for a throw (melee) or a charge
// weapon, 400x30 x0.5 at 56% / 50% of the screen. Past a full charge
// (overcharge) it turns red, shakes and grows; overcharged shows a red X.
overlay_charge_bar_render :: proc(ui: ^UI, progress: f32, over_charged: bool) {
	if !(progress > 0) && !over_charged { return }
	width, height: f32 = 400*0.5, 30*0.5
	shake: f32 = 0
	if progress > 1 {
		speed := (progress - 1)/(1 - shared.KRUNKER_OVERCHARGE)*300
		shake = 8*math.sin((progress - 1)*speed)
		height *= 1 + 2*(progress - 1)
	}
	cx, top := ui.width*0.56 + shake, ui.height*0.5
	ui_round_rect(ui, {0, 0, 0, 0.4}, cx - width/2, top, width, height, 4)
	red := shared.hex_to_vec(0xeb2f2f)
	if !over_charged {
		fill := progress > 1 ? red : shared.Vec4{1, 1, 1, 1}
		ui_round_rect(ui, fill, cx - width/2, top, width*min(1, progress), height, 2)
		return
	}
	// Two strokes per diagonal: black (14 px, 30 reach), then red (10 px, 28 reach).
	mid := top + height/2
	for pass in 0 ..< 2 {
		color := pass == 1 ? red : shared.Vec4{0, 0, 0, 1}
		thickness: f32 = pass == 1 ? 10 : 14
		reach: f32 = pass == 1 ? 28 : 30
		overlay_thick_line(ui, color, {cx - reach, mid - reach}, {cx + reach, mid + reach}, thickness)
		overlay_thick_line(ui, color, {cx + reach, mid - reach}, {cx - reach, mid + reach}, thickness)
	}
}

@(private = "file")
overlay_thick_line :: proc(ui: ^UI, color: shared.Vec4, a, b: shared.Vec2, thickness: f32) {
	d := b - a
	length := math.sqrt(d.x*d.x + d.y*d.y)
	if length <= 0 { return }
	n := shared.Vec2{-d.y, d.x}/length*(thickness/2)
	points := [4]shared.Vec2{a + n, b + n, b - n, a - n}
	ui_fill_polygon(ui, color, points[:])
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
	if scoped { overlay_scope_render(client.ui, client.hud_settings) }
	if client.me != nil && client.me.active { overlay_charge_bar_render(client.ui, client.me.charge_progress, client.me.over_charged) }
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

	// Hardpoint marker and preview: Krunker's canvas, under its HUD.
	objective_hud_render(client)

	// Krunker's HUD (timer and match info, team scores, rounds, leaderboard
	// and counters, player panel, weapons, ammo, chat, FPS).
	hud_draw(client)
	phase_mark(.HUD_CROSSHAIR)

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
//
// Building it (text layout, a few hundred boxes) is about a tenth of a frame's
// CPU work at thousands of FPS, so the built boxes are kept and queued again
// for up to HUD_CACHE_SECONDS. Anything the HUD shows that matters in a fight
// (health, ammo, weapon, FPS, size and scale) rebuilds it at once when it
// changes; everything else (timer, scores, chat, fades) is at most 1 ms old,
// far under one refresh of any monitor. Not used while typing in chat or with
// the scoreboard open.
HUD_CACHE_SECONDS :: 0.001

HUD_Cache_Key :: struct {
	width, height, scale: f32,
	font:                 Font_Slot,
	me:                   ^shared.Player,
	health:               f32,
	class_index:          i32,
	loadout_index:        i32,
	ammo:                 u32,
	weapon:               ^shared.Weapon,
	fps:                  u32,
	show_fps, in_game:    bool,
}

g_hud_cache: struct {
	recording: UI_Recording,
	key:       HUD_Cache_Key,
	built_at:  f64,
}

hud_cache_key :: proc(client: ^Client) -> HUD_Cache_Key {
	key := HUD_Cache_Key{
		width = client.ui.width, height = client.ui.height, scale = client.ui.scale, font = g_font_slot,
		fps = client.fps_value, show_fps = client.show_fps, in_game = client.in_game,
	}
	if me := client.me; me != nil {
		key.me, key.health, key.class_index, key.loadout_index, key.weapon = me, me.health, me.class_index, me.loadout_index, me.weapon
		if me.loadout_index >= 0 && int(me.loadout_index) < len(me.ammo) { key.ammo = me.ammo[me.loadout_index] }
	}
	return key
}

hud_draw :: proc(client: ^Client) {
	cache := &g_hud_cache
	cacheable := !client.scoreboard_open && !chat_typing()
	now := glfw.GetTime()
	key: HUD_Cache_Key
	if cacheable {
		key = hud_cache_key(client)
		if ui_record_usable(&cache.recording) && key == cache.key && now - cache.built_at < HUD_CACHE_SECONDS && now >= cache.built_at {
			ui_record_replay(&cache.recording)
			return
		}
		ui_record_begin(&cache.recording)
	}
	phase_mark(.HUD_KRUNKER)
	krunker_hud_render(client)
	phase_mark(.HUD_CHAT_FPS)
	kill_chat_render(client) // Krunker's chat box: chat and kill lines
	fps_render(client)       // beside the timer, at the same UI Scale
	phase_mark(.RENDER_OVERLAY)
	if cacheable {
		ui_record_end(&cache.recording)
		cache.key, cache.built_at = key, now
	} else {
		cache.recording.valid = false
	}
	if client.scoreboard_open {
		// Tab board, kept clear of the round/objective HUD at the top center.
		board := client_scoreboard(client)
		scoreboard_render(client.ui, &board, 120*client.ui.scale)
	}
}

overlay_fini :: proc() {
	ui_record_free(&g_hud_cache.recording)
	g_ui_record_generation += 1 // icons below are released
	kill_feed_fini()
	objective_hud_fini()
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
