package main

import "core:testing"
import menuui "../menu"
import shared "../shared"

// The hardpoint marker and round popups follow Krunker's canvas code.

@(test)
objective_clock_matches_krunker_format :: proc(t: ^testing.T) {
	// v10495: seconds of the minute, two digits, then tenths.
	testing.expect_value(t, objective_clock_text(59.45), "59:4")
	testing.expect_value(t, objective_clock_text(7.3), "07:3")
	testing.expect_value(t, objective_clock_text(65), "05:0") // minutes are dropped, as in Krunker
	testing.expect_value(t, objective_clock_text(-1), "00:0")
}

@(test)
objective_preview_window :: proc(t: ^testing.T) {
	// objtvTime <= 15000 && gameTimer - objtvTime >= 5000
	testing.expect(t, !objective_preview_due(15.1, 120), "no preview before the last 15 seconds")
	testing.expect(t, objective_preview_due(15, 120), "preview from 15 seconds")
	testing.expect(t, objective_preview_due(3, 8), "preview with 5 seconds of round after the rotation")
	testing.expect(t, !objective_preview_due(3, 7.9), "no preview when the round ends before the next point")
}

@(test)
objective_next_follows_uid_order :: proc(t: ^testing.T) {
	objects: [3]shared.Object
	objects[0].objective_id, objects[1].objective_id, objects[2].objective_id = 0, 1, 2
	map_inst: shared.Map
	map_inst.objects = make([dynamic]^shared.Object, 0, 3, context.temp_allocator)
	append(&map_inst.objects, &objects[0], &objects[1], &objects[2])
	game: shared.Game
	game.map_inst = &map_inst
	indices := [3]i32{0, 1, 2}
	game.objective_indices = make([dynamic]i32, 0, 3, context.temp_allocator)
	append(&game.objective_indices, ..indices[:])
	testing.expect_value(t, objective_next_uid(&game, 0), 1)
	testing.expect_value(t, objective_next_uid(&game, 1), 2)
	testing.expect_value(t, objective_next_uid(&game, 2), 0) // wraps to uid 0
}

@(test)
objective_contains_uses_zone_centre :: proc(t: ^testing.T) {
	object := shared.Object{position = {10, 0, 10}, scale = {20, 10, 20}}
	testing.expect(t, objective_contains(&object, {10, 5, 10}), "the centre is inside")
	testing.expect(t, objective_contains(&object, {0, 0, 20}), "edges are inside")
	testing.expect(t, !objective_contains(&object, {10, 10.5, 10}), "above the zone is outside")
	testing.expect(t, !objective_contains(&object, {-0.5, 5, 10}), "beside the zone is outside")
}

@(test)
objective_marker_opacity_follows_krunker_settings :: proc(t: ^testing.T) {
	hud: menuui.HUD_Settings
	testing.expect_value(t, objective_marker_alpha(hud, false, true), f32(1))
	testing.expect_value(t, objective_marker_alpha(hud, true, false), f32(1)) // ADS, marker away from the centre
	testing.expect_value(t, objective_marker_alpha(hud, true, true), f32(0.5))
	hud.objective_opacity, hud.ads_objective_opacity = menuui.objective_opacity_encode(0.4), menuui.objective_opacity_encode(0)
	testing.expect(t, abs(objective_marker_alpha(hud, false, false) - 0.4) < 0.0001, "objOpac")
	testing.expect_value(t, objective_marker_alpha(hud, true, true), f32(0))
}

@(test)
objective_marker_icon_follows_mods :: proc(t: ^testing.T) {
	saved := shared.g_mods
	defer shared.g_mods = saved
	shared.g_mods = {}
	testing.expect_value(t, objective_marker_source_path(false), "textures/marker_0.png")
	testing.expect_value(t, objective_marker_source_path(true), "textures/marker_0_next.png")
	shared.g_mods.ready = true
	shared.g_mods.index = make(map[string]string, allocator = context.temp_allocator)
	shared.g_mods.index["textures/objective_7.png"] = "mod/objective_7.png"
	shared.g_mods.index["textures/objective_8.png"] = "mod/objective_8.png"
	testing.expect_value(t, objective_marker_source_path(false), "textures/objective_7.png")
	testing.expect_value(t, objective_marker_source_path(true), "textures/objective_8.png")
	shared.g_mods.index["textures/objective_1.png"] = "mod/objective_1.png"
	testing.expect_value(t, objective_marker_source_path(false), "textures/objective_1.png")
}

@(test)
round_popup_animates_like_animate_text :: proc(t: ^testing.T) {
	item: Round_Text
	// infoText: 90px, 0.3px/ms down to 60%, 2100ms, last 100 fading.
	round_text_start(&item, "Switching Sides", 90, 0.3, 2100, 100, 0.6, 10)
	round_text_tick(&item, 100)
	testing.expect(t, abs(item.size - 60) < 0.001, "shrinks 0.3px per ms")
	round_text_tick(&item, 100)
	testing.expect(t, abs(item.size - 54) < 0.001, "stops at 60% of the start size")
	testing.expect_value(t, item.opacity, f32(1))
	round_text_tick(&item, 1850)
	testing.expect(t, item.opacity > 0.49 && item.opacity < 0.51, "fades over the last 100ms")
	round_text_tick(&item, 100)
	testing.expect_value(t, item.life, f32(0))
	testing.expect_value(t, round_lead_message(1), "Alpha is in the Lead!")
	testing.expect_value(t, round_lead_message(2), "Bravo is in the Lead!")
	testing.expect_value(t, round_lead_message(0), "Both Teams are Equal!")
}
