package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:testing"
import gl "vendor:OpenGL"
import glfw "vendor:glfw"
import menuui "../menu"
import shared "../shared"
import kproto "../krunker"

when ODIN_TEST {
	@(test)
	scoreboard_binding_defaults_to_tab_and_is_rebindable :: proc(t: ^testing.T) {
		testing.expect(t, menuui.default_bindings()[.LEADERBOARD] == ([2]i32{glfw.KEY_TAB, 0}), "Krunker's sBoardKey defaults to Tab")
		testing.expect(t, menuui.binding_valid(glfw.KEY_TAB) && menuui.binding_label(glfw.KEY_TAB) == "Tab")
		path := "bin/client-settings-scoreboard-test.json"
		defer os.remove(path)
		settings := client_settings_defaults()
		settings.bindings[.LEADERBOARD] = {'L', -4}
		testing.expect(t, client_settings_save(settings, path))
		testing.expect(t, client_settings_load(path).bindings[.LEADERBOARD] == ([2]i32{'L', -4}), "a rebound leaderboard key must persist")
		testing.expect(t, os.write_entire_file(path, `{"version":1,"bindings":{"FORWARD":[73,0]}}`) == nil)
		migrated := client_settings_load(path)
		testing.expect(t, migrated.bindings[.FORWARD] == ([2]i32{'I', 0}) && migrated.bindings[.LEADERBOARD] == ([2]i32{glfw.KEY_TAB, 0}),
			"older preferences without a leaderboard key must default it to Tab")
	}

	@(test)
	scoreboard_shows_only_while_held_in_gameplay :: proc(t: ^testing.T) {
		client := Client{bindings = menuui.default_bindings()}
		tab := proc(window: glfw.WindowHandle, code: i32) -> bool { return code == glfw.KEY_TAB }
		none := proc(window: glfw.WindowHandle, code: i32) -> bool { return false }
		alternate := proc(window: glfw.WindowHandle, code: i32) -> bool { return code == -4 }
		client.mouse_state.locked = true
		testing.expect(t, client_scoreboard_update(&client, tab), "holding Tab in gameplay must show the board")
		testing.expect(t, !client_scoreboard_update(&client, none), "releasing the key must hide it (Krunker's default Hold trigger)")
		client.mouse_state.locked = false
		testing.expect(t, !client_scoreboard_update(&client, tab), "Tab stays menu navigation while a menu owns the cursor")
		client.mouse_state.locked = true
		client.bindings[.LEADERBOARD] = {'L', -4}
		testing.expect(t, !client_scoreboard_update(&client, tab) && client_scoreboard_update(&client, alternate), "a rebound alternate slot replaces Tab")
		client.bindings[.LEADERBOARD] = {}
		testing.expect(t, !client_scoreboard_update(&client, tab), "an unbound leaderboard never opens")
	}

	@(test)
	scoreboard_formats_and_orders_like_krunker :: proc(t: ^testing.T) {
		testing.expect(t, scoreboard_format_stat(0) == "0" && scoreboard_format_stat(999) == "999")
		testing.expect(t, scoreboard_format_stat(1500) == "1.50k" && scoreboard_format_stat(2_500_000) == "2.50m" && scoreboard_format_stat(3_000_000_000) == "3.00b")
		testing.expect(t, scoreboard_column_label("score") == "Score" && scoreboard_column_label("weaponTier") == "WeaponTier")
		rows := []Scoreboard_Row{{name = "c", order = 3, sort_key = 100}, {name = "a", order = 1, sort_key = 250}, {name = "d", order = 0, sort_key = 100}, {name = "b", order = 2, sort_key = 0}}
		scoreboard_sort_rows(rows)
		testing.expect(t, rows[0].name == "a" && rows[1].name == "d" && rows[2].name == "c" && rows[3].name == "b", "score descending, ties keep player order")
		many := make([]Scoreboard_Row, 20, context.temp_allocator)
		for &row, i in many { row.order, row.sort_key = i32(i), f64(i) }
		board: Scoreboard
		scoreboard_finish(&board, many)
		testing.expect(t, len(board.rows) == SCOREBOARD_MAX_ROWS && board.rows[0].sort_key == 19 && !board.teams, "the board keeps the 16 best entries")
	}

	@(test)
	scoreboard_uses_live_leader_order_and_mode_columns :: proc(t: ^testing.T) {
		world: kproto.Krunker_World_State
		defer kproto.krunker_world_reset(&world)
		world.local_sid, world.mode_index = 7, 2 // Hardpoint: score, objective, kills
		for sid, i in ([3]i32{7, 8, 9}) {
			player := kproto.krunker_world_upsert_player(&world, sid)
			player.name, player.team = fmt.aprintf("P%d", sid), i32(i%2)+1
		}
		before := scoreboard_from_world(&world)
		testing.expect(t, len(before.rows) == 3 && before.column_count == 3 && before.columns[0] == "Score", "without a decoded board, tracked totals are listed")
		// Server order wins even over a higher score sent later in the batch.
		testing.expect(t, kproto.krunker_world_apply_packet(&world, []kproto.Krunker_Msgpack_Value{"7", []kproto.Krunker_Msgpack_Value{i64(9), i64(400), i64(120), i64(6), i64(7), i64(1500), i64(80), i64(2)}}))
		board := scoreboard_from_world(&world)
		testing.expect(t, board.column_count == 3 && board.columns[0] == "Score" && board.columns[1] == "Objective" && board.columns[2] == "Kills")
		testing.expect(t, len(board.rows) == 2 && board.rows[0].name == "P9" && board.rows[1].name == "P7", "only ranked players, in server order")
		testing.expect(t, board.rows[1].is_you && board.rows[1].cells[0] == "1.50k" && board.rows[1].cells[1] == "80" && board.rows[0].cells[2] == "6")
		testing.expect(t, board.teams && board.local_team == 1, "team modes group rows by team")
		testing.expect(t, scoreboard_name_color(board.rows[1], board.local_team) == shared.Vec4{1, 1, 1, 1} && scoreboard_name_color(board.rows[0], board.local_team) == shared.Vec4{1, 1, 1, 1} &&
			scoreboard_name_color({team = 2}, board.local_team) == shared.hex_to_vec(0xeb5656), "you, teammates and opponents match the comp board: you and teammates white, opponents red")
		world.mode_index = 3 // CTF: caps, score
		kproto.krunker_world_apply_packet(&world, []kproto.Krunker_Msgpack_Value{"7", []kproto.Krunker_Msgpack_Value{i64(8), i64(2), i64(300)}})
		ctf := scoreboard_from_world(&world)
		testing.expect(t, ctf.column_count == 2 && ctf.columns[0] == "Caps" && len(ctf.rows) == 1 && ctf.rows[0].name == "P8" && ctf.rows[0].cells[1] == "300",
			"each batch replaces the board and uses that mode's leaderStats")
		for &player in world.players { delete(player.name); player.name = "" }
	}

	@(test)
	scoreboard_native_rows_use_authoritative_totals :: proc(t: ^testing.T) {
		game: shared.Game
		defer delete(game.players)
		players := [3]shared.Player{{uid = 1, team = 1, score = 100, kills = 1, deaths = 2}, {uid = 2, team = 2, score = 300, kills = 3, is_you = true}, {uid = 3, team = 1, score = 100, deaths = 1}}
		for &player in players { append(&game.players, &player) }
		board := scoreboard_from_game(&game)
		testing.expect(t, len(board.rows) == 3 && board.rows[0].name == "You" && board.rows[1].name == "Player 1" && board.rows[2].name == "Player 3")
		testing.expect(t, board.rows[0].cells[1] == "3" && board.rows[2].cells[2] == "1" && board.teams && board.local_team == 2)
		state := shared.Packet_Player_State{player_id = 4, score = 1250, kills = 11, deaths = 4}
		buf: [shared.PACKET_HEADER_SIZE + shared.PACKET_PLAYER_STATE_PAYLOAD_SIZE]byte
		size := shared.packet_serialize_state(buf[:], &state)
		decoded, ok := shared.packet_deserialize_state(buf[:size])
		testing.expect(t, ok && decoded.score == 1250 && decoded.kills == 11 && decoded.deaths == 4, "native snapshots must carry scoreboard totals")
	}

	@(test)
	scoreboard_renders_over_gameplay_hud :: proc(t: ^testing.T) {
		logger := context.logger
		context = runtime.default_context()
		context.logger = logger
		if !testing.expect(t, bool(glfw.Init())) { return }
		defer glfw.Terminate()
		test_gpu := test_gpu_open(1280, 720, "Scoreboard")
		if !testing.expect(t, test_gpu.ok, "no GPU device for the test") do return
		defer test_gpu_close(&test_gpu, t)
		g_test_gpu = &test_gpu
		window := test_gpu.window
		gpu_set_clear_color({0.16, 0.18, 0.20})
		g_active_texture = 0
		mode := shared.Game_Mode{objective = true}
		client := Client{ui = ui_init(), game = {mode = &mode}, crosshair_settings = menuui.DEFAULT_CROSSHAIR_SETTINGS}
		defer { overlay_fini(); ui_fini(client.ui); resource_cache_fini() }
		defer delete(client.game.players)
		players := [4]shared.Player{{uid = 1, team = 1, score = 450, kills = 4, deaths = 1, is_you = true}, {uid = 2, team = 2, score = 1200, kills = 12, deaths = 3}, {uid = 3, team = 1, score = 90, kills = 1, deaths = 6}, {uid = 4, team = 2}}
		for &player in players { append(&client.game.players, &player) }
		client.game.match = {phase = .LIVE, round_current = 1, time_remaining = 180, team_scores = {0, 540, 1200}}
		client.viewport_width, client.viewport_height = 1280, 720
		gpu_set_target(test_gpu_current_target(), 1280, 720)
		before := make([]u8, 1280*720*3)
		after := make([]u8, len(before))
		defer delete(before)
		defer delete(after)
		match_hud_snapshot(&client, before)
		client.scoreboard_open = true
		match_hud_snapshot(&client, after)
		center := client.ui.width/client.ui.scale*0.5
		middle := client.ui.height/client.ui.scale*0.5
		testing.expect(t, match_hud_region_delta(&client, before, after, center-400, 180, center+400, middle+60) > 2000, "an open board must draw at the center of the screen")
		testing.expect(t, match_hud_region_delta(&client, before, after, 0, 0, 240, 100) == 0, "the board must not cover the match timer")
		when #config(HUD_PREVIEW, false) {
			file := make([dynamic]u8)
			defer delete(file)
			append(&file, ..transmute([]u8)fmt.tprintf("P6\n%d %d\n255\n", 1280, 720))
			for row := 719; row >= 0; row -= 1 { append(&file, ..after[row*1280*3:(row+1)*1280*3]) }
			testing.expect(t, os.write_entire_file("bin/scoreboard-1280x720.ppm", file[:]) == nil)
		}
		testing.expect(t, test_gpu_no_error())
	}
}
