package main

import "core:fmt"
import "core:math"
import "core:encoding/json"
import gl "vendor:OpenGL"
import glfw "vendor:glfw"
import menuui "../menu"
import shared "../shared"

// Krunker's in-game HUD, drawn from its stylesheet (main.css) one to one.
// Every length here is a CSS pixel of Krunker's page; while the HUD draws,
// ui.scale is Krunker's UI Scale factor (menuui.krunker_ui_factor), the same
// transform Krunker puts on #uiBase, so UI Scale 0.7 here looks like 0.7 in
// Krunker.

KH_BLACK :: shared.Vec4{20.0/255, 20.0/255, 20.0/255, 0.75}    // --div-black
KH_GREY :: shared.Vec4{108.0/255, 108.0/255, 108.0/255, 0.40}  // --div-grey
KH_RED :: shared.Vec4{0xeb/255.0, 0x56/255.0, 0x56/255.0, 1}   // enemies (.leaderName, .tScoreC)
KH_BLUE :: shared.Vec4{0x56/255.0, 0x99/255.0, 0xeb/255.0, 1}  // .tScoreF.you
KH_WHITE :: shared.Vec4{1, 1, 1, 1}
KH_MUTED :: shared.Vec4{1, 1, 1, 0.7}
KH_HEALTH :: shared.Vec4{0, 155.0/255, 0, 1}

// FrVrKrunkerBold metrics in em. SR's glyph size is the font's ascent+descent
// (1.375 em). Chrome's line box ("line-height: normal") is the Windows
// ascent+descent, 1.5 + 0.25 em, with the baseline 1.5 em below its top.
KH_EM :: 1.375
KH_ASCENT :: 1.5
KH_LINE :: 1.75

krunker_hud_scale :: proc(client: ^Client) -> f32 {
	return menuui.krunker_ui_factor(client.hud_settings, client.ui.width, client.ui.height)
}

kh_measure :: proc(ui: ^UI, text: string, px: f32) -> f32 {
	return ui_measure_text(ui, text, px*KH_EM*ui.scale)
}

// One CSS text line of font-size `px` whose line box starts at `top`.
kh_text :: proc(ui: ^UI, color: shared.Vec4, text: string, x, top, px: f32) {
	if len(text) == 0 { return }
	ui_fill_text(ui, color, text, x, top + px*KH_ASCENT*ui.scale, px*KH_EM*ui.scale)
}

kh_fade :: proc(color: shared.Vec4, alpha: f32) -> shared.Vec4 {
	return {color[0], color[1], color[2], color[3]*alpha}
}

// Krunker's two-tone box: --div-black with a --div-grey inner 3px in.
kh_box :: proc(ui: ^UI, x, y, w, h: f32, radius: f32 = 4, alpha: f32 = 1) {
	s := ui.scale
	ui_round_rect(ui, kh_fade(KH_BLACK, alpha), x, y, w, h, radius*s)
	ui_fill_rect(ui, kh_fade(KH_GREY, alpha), x+3*s, y+3*s, w-6*s, h-6*s)
}

kh_load :: proc(texture: ^Gpu_Texture, path: string, smooth := false) -> Gpu_Texture {
	if texture^ == 0 {
		full := shared.concat(shared.assets_path(), path)
		texture^ = load_texture(full)
		delete(full)
		if smooth { overlay_icon_filter(texture^) }
	}
	return texture^
}

kh_texture_aspect :: proc(texture: Gpu_Texture) -> f32 {
	if texture == 0 { return 1 }
	// HUD icons come from load_texture, whose cache knows the size.
	entry, ok := g_texture_by_id[texture]
	if !ok || entry.height <= 0 { return 1 }
	return f32(entry.width)/f32(entry.height)
}

kh_map_name :: proc(client: ^Client) -> string {
	if client.game.map_inst != nil {
		if root, ok := client.game.map_inst.raw_data.(json.Object); ok {
			if name, valid := root["name"].(json.String); valid && len(name) > 0 { return string(name) }
		}
	}
	return g_map_name
}

krunker_hud_render :: proc(client: ^Client) {
	bottom := kh_top_left_render(client)
	kh_team_scores_render(client, bottom)
	kh_rounds_render(client)
	leaderboard_render(client)
	kh_player_render(client)
	kh_weapons_render(client)
}

// ------------------------------------------------------------ top left

// #timerHolder.topLeftOld at top/left 15: a 45px icon and the 32px time in a
// grey inner with 10px padding.
kh_timer_rect :: proc(client: ^Client) -> (x, y, w, h: f32) {
	ui := client.ui
	s := ui.scale
	label := krunker_client_timer_label(client)
	inner := 10 + 45 + kh_measure(ui, " ", 32)/s + 3 + kh_measure(ui, label, 32)/s + 10
	return 15*s, 15*s, (inner + 6)*s, (6 + 10 + 32*KH_LINE + 10)*s
}

// Timer and #matchInfo; returns where #teamScores starts.
kh_top_left_render :: proc(client: ^Client) -> f32 {
	ui := client.ui
	s := ui.scale
	top := 15*s
	if !client.hud_settings.hide_timer {
		x, y, w, h := kh_timer_rect(client)
		kh_box(ui, x, y, w, h)
		line := y + 13*s
		if icon := kh_load(&timer_icon, "img/timer.png"); icon != 0 {
			// Baseline-aligned 45px image: its top is 48 - 45 below the line top.
			ui_draw_image(ui, icon, x + 13*s, line + 3*s, 45*s, 45*s)
		}
		kh_text(ui, KH_WHITE, krunker_client_timer_label(client), x + 13*s + 45*s + kh_measure(ui, " ", 32) + 3*s, line, 32)
		top = y + h + 10*s
	}
	// #matchInfo.topLeftOld: "<mode>" and "on <map>", 15px.
	title, _ := round_mode_title(client)
	kh_text(ui, KH_WHITE, title, 15*s, top, 15)
	if name := kh_map_name(client); len(name) > 0 {
		kh_text(ui, shared.Vec4{1, 1, 1, 0.6}, fmt.tprintf("on %s", name), 15*s, top + 15*KH_LINE*s, 15)
	}
	return top + 2*15*KH_LINE*s + 10*s
}

// #teamScores: one row per team in team order (Alpha, Bravo), a square and
// the score; your team white, the enemy red (as in Krunker's comp HUD).
kh_team_scores_render :: proc(client: ^Client, top: f32) {
	mode := client.game.mode
	if mode == nil || !mode.config.teams || client.hud_settings.hide_round_score { return }
	ui := client.ui
	s := ui.scale
	match := &client.game.match
	local := client_local_team(client)
	value_w: f32 = 0
	for team in 1..=2 { value_w = max(value_w, kh_measure(ui, fmt.tprintf("%d", match.team_scores[team]), 20)) }
	row := 20*KH_LINE*s
	w := 10*s + 16*s + 8*s + value_w + 10*s
	h := 5*s + 2*row + 5*s
	ui_round_rect(ui, shared.Vec4{0, 0, 0, 0.3}, 15*s, top, w, h, 6*s)
	for team in 1..=2 {
		y := top + 5*s + f32(team-1)*row
		color := i32(team) == local ? KH_WHITE : KH_RED
		ui_fill_rect(ui, color, 25*s, y + (row - 16*s)*0.5, 16*s, 16*s)
		kh_text(ui, color, fmt.tprintf("%d", match.team_scores[team]), 25*s + 24*s, y, 20)
	}
}

// ------------------------------------------------------------- top middle

// #topMidHold (scale 0.8): .roundScrV round wins either side of
// #roundsDisplay, then #gameMessage with the objective clock.
kh_rounds_render :: proc(client: ^Client) {
	mode := client.game.mode
	if mode == nil || !mode.objective { return }
	ui := client.ui
	s := ui.scale
	z := 0.8*s // #topMidHold's transform
	match := &client.game.match
	y := 9*s
	if !client.hud_settings.hide_game_score {
		total := max(u32(1), match.rounds_to_win)*2-1
		if client.krunker.connected { total = max(u32(1), client.krunker_world.rounds_total) }
		round := fmt.tprintf("%d/%d", clamp(match.round_current, 1, total), total)
		saved := ui.scale
		ui.scale = z
		center_w := max(kh_measure(ui, round, 29), kh_measure(ui, "Round", 19)) + 40*z
		side_w: [2]f32
		values: [2]string
		for team, i in ([2]i32{1, 2}) {
			values[i] = fmt.tprintf("%d", match.round_wins[team])
			side_w[i] = kh_measure(ui, values[i], 42) + 60*z
		}
		gap := 4*z
		x := (ui.width - (side_w[0] + center_w + side_w[1] + 2*gap))*0.5
		for i in 0..<2 {
			left := i == 0 ? x : x + side_w[0] + center_w + 2*gap
			ui_fill_rect(ui, shared.Vec4{0, 0, 0, 0.4}, left, y, side_w[i], 96*z)
			ui_fill_rect(ui, i == 0 ? KH_RED : KH_BLUE, left, y + 96*z, side_w[i], 6*z) // Alpha red, Bravo blue
			// line-height 96: half-leading (96 - 1.75 em) / 2 above the line box.
			kh_text(ui, shared.Vec4{1, 1, 1, 0.6}, values[i], left + 30*z, y + (96 - 42*KH_LINE)*0.5*z, 42)
		}
		cx := x + side_w[0] + gap
		center_h := (29 + 19)*KH_LINE*z + 10*z
		ui_round_rect(ui, shared.Vec4{0, 0, 0, 0.4}, cx, y + 10*z, center_w, center_h, 6*z)
		kh_text(ui, KH_WHITE, round, cx + (center_w - kh_measure(ui, round, 29))*0.5, y + 15*z, 29)
		kh_text(ui, shared.Vec4{1, 1, 1, 0.8}, "Round", cx + (center_w - kh_measure(ui, "Round", 19))*0.5, y + 15*z + 29*KH_LINE*z, 19)
		ui.scale = saved
		y += 112*z
	}
	if client.hud_settings.hide_timer { return }
	seconds := max(0, int(math.ceil(match.objective.rotation_remaining)))
	message := fmt.tprintf("next objective %02d:%02d", seconds/60, seconds%60)
	if match.phase == .WARMUP { message = fmt.tprintf("Match starts in %.0fs", math.ceil(match.phase_remaining)) }
	if countdown := krunker_client_countdown_label(client, glfw.GetTime()); len(countdown) > 0 { message = countdown }
	saved := ui.scale
	ui.scale = z
	kh_text(ui, KH_WHITE, message, (ui.width - kh_measure(ui, message, 22))*0.5, y, 22)
	ui.scale = saved
}

// ------------------------------------------------------------ bottom left

// #bottomLeftPlayer at bottom/left 15: the 90px class image, the team type
// and name over the segmented health bar, and the health with its icon.
kh_player_render :: proc(client: ^Client) {
	me := client.me
	if me == nil || me.class_index < 0 || me.class_index >= i32(len(client.game.classes)) { return }
	ui := client.ui
	s := ui.scale
	class := &client.game.classes[me.class_index]
	health := fmt.tprintf("%.f", max(0, me.health))
	hp_icon := kh_load(&health_icon, "img/hp_0.png")
	right_inner := 9 + max(26, kh_measure(ui, health, 20)/s) + 7
	w := (96 + 250 + 3 + right_inner + 3)*s
	h := 96*s
	x := 15*s
	y := ui.height - 15*s - h
	ui_round_rect(ui, KH_BLACK, x, y, w, h, 4*s)

	// #bottomLeftPlayerLeft
	ui_fill_rect(ui, KH_GREY, x + 3*s, y + 3*s, 90*s, 90*s)
	if class_icons == nil { class_icons = make(map[i32]Gpu_Texture) }
	icon := class_icons[class.icon_index]
	if icon == 0 {
		path := shared.concat(shared.assets_path(), fmt.tprintf("textures/classes/icon_%d.png", class.icon_index))
		icon = load_texture(path)
		delete(path)
		class_icons[class.icon_index] = icon
	}
	if icon != 0 { ui_draw_image(ui, icon, x + 3*s, y + 3*s, 90*s, 90*s) }

	// #bottomLeftPlayerMid: team type 66px | team name 181px, health bar under.
	mid := x + 96*s
	row_top := y + 3*s
	row_h := 39*s
	team_mode := client.game.mode == nil || client.game.mode.config.teams
	ui_fill_rect(ui, KH_GREY, mid, row_top, 66*s, row_h)
	kind := team_mode ? "Team" : "FFA"
	kh_text(ui, KH_WHITE, kind, mid + (66*s - kh_measure(ui, kind, 12))*0.5, row_top + (row_h - 12*KH_LINE*s)*0.5, 12)
	ui_fill_rect(ui, KH_GREY, mid + 69*s, row_top, 181*s, row_h)
	if team_mode {
		if team := client_local_team(client); team == 1 || team == 2 {
			name := client_team_names(client)[team-1]
			kh_text(ui, KH_WHITE, scoreboard_fit_text(ui, name, 16*KH_EM*s, 161*s), mid + 79*s, row_top + (row_h - 16*KH_LINE*s)*0.5, 16)
		}
	}
	bar_top := row_top + row_h + 3*s
	bar_h := 48*s
	ui_fill_rect(ui, KH_GREY, mid, bar_top, 250*s, bar_h)
	segments := max(1, int(class.health_segments))
	seg_w := (250*s - 18*s - f32(segments-1)*3*s)/f32(segments)
	max_health := f32(max(1, me.max_health))
	// Krunker's hudHealthHigh / hudHealthLow, blended by health. Unset, both are
	// SR's KH_HEALTH green, exactly as before.
	health_color := KH_HEALTH
	if colors := menuui.health_colors(client.hud_settings); client.hud_settings.hud_health_high != 0 || client.hud_settings.hud_health_low != 0 {
		high, low := shared.hex_to_vec(i32(colors.hud_high)), shared.hex_to_vec(i32(colors.hud_low))
		t := clamp(me.health/max_health, 0, 1)
		health_color = low + (high - low)*t
		health_color.a = 1
	}
	for i in 0..<segments {
		sx := mid + 9*s + f32(i)*(seg_w + 3*s)
		ui_fill_rect(ui, shared.Vec4{0, 0, 0, 0.4}, sx, bar_top + 9*s, seg_w, 30*s)
		part := max_health/f32(segments)
		fill := clamp((me.health - f32(i)*part)/part, 0, 1)
		if fill > 0 { ui_round_rect(ui, health_color, sx, bar_top + 9*s, seg_w*fill, 30*s, min(3*s, seg_w*fill*0.5)) }
	}

	// #bottomLeftPlayerRight: icon over the number, spaced evenly.
	rx := mid + 250*s + 3*s
	rw := right_inner*s
	ui_fill_rect(ui, KH_GREY, rx, y + 3*s, rw, 90*s)
	free := (90 - 6 - 26 - 20*KH_LINE)*s/3
	center := rx + 9*s + (rw - 16*s)*0.5
	if hp_icon != 0 { ui_draw_image(ui, hp_icon, center - 13*s, y + 6*s + free, 26*s, 26*s) }
	kh_text(ui, KH_WHITE, health, center - kh_measure(ui, health, 20)*0.5, y + 6*s + 2*free + 26*s, 20)
}

// ----------------------------------------------------------- bottom right

g_ammo_icon_aspect: f32

// #weapHolder (right 15, bottom 90): the loadout, the held weapon at full
// opacity and the others at half; #ammoHolder at bottom/right 15.
kh_weapons_render :: proc(client: ^Client) {
	me := client.me
	if me == nil { return }
	ui := client.ui
	s := ui.scale
	right := ui.width - 15*s

	// .weapItem: black, radius 4; .weapItemInner: grey, margin 3, padding 2 10,
	// a 110x55 icon on a 17px line (55 + 0.25 em of descent).
	item_h := (6 + 4 + 55 + 17*0.25)*s
	item_w := (6 + 20 + 110)*s
	keys: [menuui.Binding_Action]string
	for action in ([?]menuui.Binding_Action{.SECONDARY, .MELEE}) {
		code := client.bindings[action][0]
		if code == 0 { code = client.bindings[action][1] }
		if code != 0 { keys[action] = menuui.binding_label(code) }
	}
	count := 0
	for weapon_id in me.loadout { if weapon_id >= 0 && int(weapon_id) < len(client.game.weapons) && client.game.weapons[weapon_id] != nil { count += 1 } }
	y := ui.height - 90*s - f32(count)*item_h - f32(max(0, count-1))*5*s
	for weapon_id, slot in me.loadout {
		if weapon_id < 0 || int(weapon_id) >= len(client.game.weapons) { continue }
		weapon := client.game.weapons[weapon_id]
		if weapon == nil { continue }
		alpha: f32 = i32(slot) == me.loadout_index ? 1 : 0.5
		x := right - item_w
		kh_box(ui, x, y, item_w, item_h, 4, alpha)
		if icon, _ := overlay_weapon_icon(client, weapon_id); icon != 0 {
			ui_draw_image(ui, icon, x + 13*s, y + 5*s, 110*s, 55*s, kh_fade(KH_WHITE, alpha))
		} else {
			kh_text(ui, kh_fade(KH_MUTED, alpha), weapon.name, right - 13*s - kh_measure(ui, weapon.name, 17), y + 5*s + (55 - 17*KH_LINE)*s*0.5, 17)
		}
		// .weapSkin: the weapon's name bottom-left, 10px on --div-black.
		if len(weapon.name) > 0 {
			nw := min(kh_measure(ui, weapon.name, 10) + 10*s, 122*s)
			nh := (4 + 10*KH_LINE)*s
			ui_fill_rect(ui, kh_fade(KH_BLACK, alpha), x + 2*s, y + item_h - 2*s - nh, nw, nh)
			kh_text(ui, kh_fade(KH_WHITE, alpha), scoreboard_fit_text(ui, weapon.name, 10*KH_EM*s, 112*s), x + 7*s, y + item_h - 2*s - nh + 2*s, 10)
		}
		// .weapKey: top-left, 14px, black .5, padding 2 8, rounded bottom right.
		key := weapon.melee ? keys[.MELEE] : weapon.secondary ? keys[.SECONDARY] : ""
		if len(key) > 0 {
			kw := kh_measure(ui, key, 14) + 16*s
			kh := (4 + 14*KH_LINE)*s
			ui_fill_rect(ui, kh_fade(shared.Vec4{0, 0, 0, 0.5}, alpha), x + 2*s, y + 2*s, kw, kh)
			kh_text(ui, kh_fade(KH_WHITE, alpha), key, x + 10*s, y + 4*s, 14)
		}
		y += item_h + 5*s
	}

	// #ammoHolder: radius 6, 29px; ammo, " | max" at .7, the 43px ammo icon.
	if me.weapon == nil || me.loadout_index < 0 || int(me.loadout_index) >= len(me.ammo) { return }
	weapon := me.weapon
	ammo := fmt.tprintf("%d", me.ammo[me.loadout_index])
	if weapon.melee || weapon.ammo == 0 { ammo = "-" }
	unlimited := weapon.ammo == 0 || (client.game.mode != nil && client.game.mode.config.ammo_limit != 0)
	maximum := unlimited ? " | -" : fmt.tprintf(" | %d", weapon.ammo)
	icon := kh_load(&ammo_icon, "textures/ammo_0.png", smooth = true)
	if icon != 0 && g_ammo_icon_aspect == 0 { g_ammo_icon_aspect = kh_texture_aspect(icon) }
	icon_w := icon != 0 ? 43*g_ammo_icon_aspect*s : 0
	ammo_w := kh_measure(ui, ammo, 29)
	max_w := kh_measure(ui, maximum, 29)
	w := 8*s + 10*s + ammo_w + max_w + 5*s + icon_w + 10*s + 8*s
	h := (16 + 29*KH_LINE)*s
	x := right - w
	top := ui.height - 15*s - h
	kh_box(ui, x, top, w, h, 6)
	reload_timer := client.krunker.connected ? krunker_client_render_sample(client).reload_timer : me.reload_timer
	if weapon.reload_time > 0 && client.game.config.reload_speed > 0 && reload_timer > 0 {
		progress := clamp(1 - reload_timer/(weapon.reload_time*client.game.config.reload_speed), 0, 1)
		ui_fill_rect(ui, shared.Vec4{1, 1, 1, 0.15}, x + 3*s, top + 3*s, (w - 6*s)*progress, h - 6*s)
	}
	line := top + 8*s
	kh_text(ui, KH_WHITE, ammo, x + 18*s, line, 29)
	kh_text(ui, KH_MUTED, maximum, x + 18*s + ammo_w, line, 29)
	if icon != 0 {
		// vertical-align: bottom, so its bottom sits on the line box's bottom.
		ui_draw_image(ui, icon, x + w - 18*s - icon_w, line + (29*KH_LINE - 43)*s, icon_w, 43*s)
	}
}
