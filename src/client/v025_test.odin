package main

import "core:testing"
import menuui "../menu"
import kproto "../krunker"
import shared "../shared"

@(test)
ui_scale_max_keeps_menus_on_screen :: proc(t: ^testing.T) {
	hud: menuui.HUD_Settings
	hud.ui_scale = 1
	testing.expect(t, menuui.menu_ui_zoom(hud) == 1, "UI Scale 1 must not zoom menus past the window")
	hud.ui_scale = 0.3
	testing.expect(t, menuui.menu_ui_zoom(hud) < 1, "smaller UI Scales still shrink the menus")
}

@(test)
whizz_needs_a_bullet_passing_close :: proc(t: ^testing.T) {
	testing.expect(t, bullet_passes_within({0, 0, -100}, {0, 0, 100}, {10, 0, 0}, KRUNKER_WHIZZ_RANGE))
	testing.expect(t, !bullet_passes_within({0, 0, -100}, {0, 0, 100}, {40, 0, 0}, KRUNKER_WHIZZ_RANGE))
	testing.expect(t, !bullet_passes_within({0, 0, -100}, {0, 0, -60}, {0, 0, 0}, KRUNKER_WHIZZ_RANGE), "a bullet that stops short does not whizz")
}

@(test)
clans_come_from_the_roster :: proc(t: ^testing.T) {
	state: kproto.Krunker_World_State
	defer kproto.krunker_world_reset(&state)
	record := make([]kproto.Krunker_Msgpack_Value, 53)
	defer delete(record)
	for &v in record { v = i64(0) }
	record[0], record[1], record[5], record[8], record[11] = "sock", i64(4), "Walshik", i64(100), "DEV"
	packet := []kproto.Krunker_Msgpack_Value{i64(0), record}
	testing.expect(t, kproto.krunker_world_apply_add_players(&state, packet))
	testing.expect(t, len(state.players) == 1 && state.players[0].clan == "DEV" && state.players[0].name == "Walshik")
	testing.expect(t, krunker_clan_color("dev", {1, 1, 1, 1}) != shared.Vec4{1, 1, 1, 1}, "Krunker's special clans are gold")
}
