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
	end_screen_test_packet :: proc(world: ^kproto.Krunker_World_State, mode: i32, did_win: kproto.Krunker_Msgpack_Value, winner: i64, end_index: i64, ed: []kproto.Krunker_Msgpack_Value) -> bool {
		world.mode_index, world.has_match = mode, true
		data := []kproto.Krunker_Msgpack_Map_Entry{
			{key = "tms", value = []kproto.Krunker_Msgpack_Value{[]kproto.Krunker_Msgpack_Value{i64(1), i64(310)}, []kproto.Krunker_Msgpack_Value{i64(2), i64(500)}}},
			{key = "ed", value = ed},
		}
		return kproto.krunker_world_apply_packet(world, []kproto.Krunker_Msgpack_Value{"end", i64(0), did_win, data, i64(winner), i64(end_index)})
	}

	@(test)
	end_screen_result_matches_browser_title :: proc(t: ^testing.T) {
		testing.expect(t, end_screen_result(-1, false) == .DRAW && end_screen_result(1, false) == .VICTORY && end_screen_result(0, false) == .DEFEAT)
		testing.expect(t, end_screen_result(0, true) == .MATCH_OVER && end_screen_result(-1, true) == .DRAW, "noWinner only replaces defeat")
		testing.expect(t, end_screen_reward("25") == "+25 KR" && end_screen_reward("0") == "NONE" && end_screen_reward("") == "NONE")
	}

	@(test)
	end_screen_uses_live_end_table :: proc(t: ^testing.T) {
		client: Client
		client.krunker.connected = true
		world := &client.krunker_world
		defer kproto.krunker_world_reset(world)
		world.local_sid = 7
		for sid, i in ([2]i32{7, 8}) { kproto.krunker_world_upsert_player(world, sid).team = i32(i)+1 }
		// TDM endStats: sid, name, score, kills, deaths, assists, reward. Rows
		// arrive in endSort order; names are [name, displayName] pairs.
		ed := []kproto.Krunker_Msgpack_Value{
			i64(8), []kproto.Krunker_Msgpack_Value{"acc8", "Eight"}, i64(500), i64(9), i64(2), i64(1), i64(30),
			i64(7), "Seven", i64(310), i64(4), i64(6), i64(3), kproto.Krunker_Msgpack_Nil{},
		}
		testing.expect(t, end_screen_test_packet(world, 1, false, 2, 0, ed))
		testing.expect(t, len(world.end_entries) == 2 && world.end_entries[0].name == "Eight" && world.end_entries[1].cells[4] == "0")
		testing.expect(t, gameplay_packet(world, "t", "0:24", i64(1)) && world.end_timer_text == "0:24")
		screen := client_end_screen(&client)
		board := &screen.board
		testing.expect(t, screen.result == .DEFEAT && screen.winner_team == 2 && screen.teams && !board.teams && board.rank_label == "#")
		testing.expect(t, screen.timer == "Next Round in 0:24" && !screen.abandoned && board.team_scores[2] == 500)
		testing.expect(t, board.column_count == 5 && board.columns[0] == "Score" && board.columns[3] == "Assists" && board.columns[4] == "Reward")
		testing.expect(t, len(board.rows) == 2 && board.rows[0].name == "Eight" && board.rows[1].is_you && board.rows[1].team == 1, "server endSort order is kept")
		testing.expect(t, board.rows[0].cells[0] == "500" && board.rows[0].cells[4] == "+30 KR" && board.rows[1].cells[4] == "NONE")
		// Malformed tables (wrong stride) fall back to the leaderboard.
		testing.expect(t, end_screen_test_packet(world, 2, true, 1, 3, ed))
		screen = client_end_screen(&client)
		testing.expect(t, len(world.end_entries) == 0 && screen.result == .VICTORY && screen.abandoned && screen.timer == "MATCH ABANDONED" && screen.board.column_count == 3,
			"an undecodable end table uses the leaderboard columns")
		// The next match clears the end state.
		kproto.krunker_world_init_match(world, []kproto.Krunker_Msgpack_Value{"init"})
		testing.expect(t, len(world.end_entries) == 0 && world.end_timer_text == "" && !client_match_ended(&client))
	}

	// The browser server sends END as (gameState, didWin, endData, winner,
	// endIndex, reward, bpData, extra). Team winners come from getWinTeam,
	// which returns the for..in key of teamScores: a string ("1"/"2"). A tied
	// or winnerless match sends didWin -1 and winner -1; FFA always sends -1
	// as the team winner and a boolean didWin.
	@(test)
	end_screen_live_end_packets_resolve_result :: proc(t: ^testing.T) {
		Case :: struct {
			name: string,
			mode: i32,
			local_team: i32,
			did_win, winner, end_index: kproto.Krunker_Msgpack_Value,
			result: End_Result,
			winner_team: i32,
		}
		cases := []Case{
			{"team win", 1, 2, true, "2", kproto.Krunker_Msgpack_Nil{}, .VICTORY, 2},
			{"team loss", 1, 2, false, "1", kproto.Krunker_Msgpack_Nil{}, .DEFEAT, 1},
			{"team draw", 1, 1, i64(-1), i64(-1), kproto.Krunker_Msgpack_Nil{}, .DRAW, 0},
			{"team win, numeric winner", 2, 1, true, i64(1), i64(0), .VICTORY, 1},
			{"team abandoned without a winner", 1, 1, false, kproto.Krunker_Msgpack_Nil{}, i64(3), .DEFEAT, 0},
			{"ffa win", 0, 0, true, i64(-1), kproto.Krunker_Msgpack_Nil{}, .VICTORY, 0},
			{"ffa loss", 0, 0, false, i64(-1), kproto.Krunker_Msgpack_Nil{}, .DEFEAT, 0},
		}
		for c in cases {
			client: Client
			client.krunker.connected = true
			world := &client.krunker_world
			kproto.krunker_world_init_match(world, []kproto.Krunker_Msgpack_Value{"init"})
			world.local_sid, world.mode_index, world.rounds_total = 7, c.mode, 1
			kproto.krunker_world_upsert_player(world, 7).team = c.local_team
			kproto.krunker_world_upsert_player(world, 8).team = c.local_team == 0 ? 0 : 3-c.local_team
			// gsc 4 (POST_MATCH) precedes END in the logged lobbies.
			testing.expect(t, gameplay_packet(world, "gsc", i64(4)), c.name)
			data := []kproto.Krunker_Msgpack_Map_Entry{
				{key = "tms", value = []kproto.Krunker_Msgpack_Value{[]kproto.Krunker_Msgpack_Value{i64(1), i64(1), kproto.Krunker_Msgpack_Nil{}}, []kproto.Krunker_Msgpack_Value{i64(2), i64(2), kproto.Krunker_Msgpack_Nil{}}}},
				{key = "ed", value = []kproto.Krunker_Msgpack_Value{}},
			}
			packet := []kproto.Krunker_Msgpack_Value{"end", i64(0), c.did_win, data, c.winner, c.end_index, i64(0), kproto.Krunker_Msgpack_Nil{}, []kproto.Krunker_Msgpack_Map_Entry{}}
			testing.expectf(t, kproto.krunker_world_apply_packet(world, packet), "%s: END must apply", c.name)
			screen := client_end_screen(&client)
			testing.expectf(t, screen.result == c.result && screen.winner_team == c.winner_team, "%s: got %v winner %d, want %v winner %d", c.name, screen.result, screen.winner_team, c.result, c.winner_team)
			kproto.krunker_world_reset(world)
		}
		// The final round of a multi-round match is counted from the string winner.
		world: kproto.Krunker_World_State
		defer kproto.krunker_world_reset(&world)
		kproto.krunker_world_init_match(&world, []kproto.Krunker_Msgpack_Value{"init"})
		world.rounds_total, world.match.round_wins = 3, {0, 1, 1}
		testing.expect(t, gameplay_packet(&world, "end", i64(0), true, []kproto.Krunker_Msgpack_Map_Entry{}, "2", kproto.Krunker_Msgpack_Nil{}))
		testing.expect(t, world.match.round_wins == [3]u32{0, 1, 2} && world.winner_team == 2)
		testing.expect(t, !gameplay_packet(&world, "end", i64(0), true, []kproto.Krunker_Msgpack_Map_Entry{}, "x", kproto.Krunker_Msgpack_Nil{}), "a malformed winner is still rejected")
	}

	// gsc POST_MATCH ends the match before END arrives (and END may be lost
	// or undecodable); the title must not default to DRAW then.
	@(test)
	end_screen_without_end_packet_uses_tracked_totals :: proc(t: ^testing.T) {
		client: Client
		client.krunker.connected = true
		world := &client.krunker_world
		defer kproto.krunker_world_reset(world)
		kproto.krunker_world_init_match(world, []kproto.Krunker_Msgpack_Value{"init"})
		world.local_sid, world.mode_index = 7, 1
		kproto.krunker_world_upsert_player(world, 7).team = 1
		kproto.krunker_world_upsert_player(world, 8).team = 2
		world.match.team_scores = {0, 40, 25}
		testing.expect(t, gameplay_packet(world, "gsc", i64(4)) && client_match_ended(&client))
		screen := client_end_screen(&client)
		testing.expectf(t, screen.result == .VICTORY && screen.winner_team == 1, "got %v winner %d", screen.result, screen.winner_team)
	}

	// A native/local match that ends through the simulation's own round logic.
	@(test)
	end_screen_native_match_end_has_winner :: proc(t: ^testing.T) {
		client := Client{local_practice = true}
		defer delete(client.game.players)
		players := [2]shared.Player{{uid = 1, team = 2, score = 300, is_you = true}, {uid = 2, team = 1, score = 100}}
		for &player in players { append(&client.game.players, &player) }
		client.game.ready = true
		client.game.match = {phase = .LIVE, rounds_to_win = 2, round_wins = {0, 0, 1}, team_scores = {0, 100, 300}}
		shared.game_resolve_round(&client.game, 0)
		testing.expect(t, client.game.match.phase == .ENDED && client_match_ended(&client))
		screen := client_end_screen(&client)
		testing.expectf(t, screen.result == .VICTORY && screen.winner_team == 2, "got %v winner %d", screen.result, screen.winner_team)
		players[0].team, players[1].team = 1, 2
		screen = client_end_screen(&client)
		testing.expectf(t, screen.result == .DEFEAT && screen.winner_team == 2, "got %v winner %d", screen.result, screen.winner_team)
	}

	@(test)
	end_screen_resolves_native_winner :: proc(t: ^testing.T) {
		match := shared.Match_State{team_scores = {0, 300, 120}}
		board := Scoreboard{teams = true, local_team = 2}
		result, winner := end_screen_native_result(&match, &board)
		testing.expect(t, result == .DEFEAT && winner == 1, "team totals decide a single-round match")
		match.round_wins = {0, 1, 2}
		result, winner = end_screen_native_result(&match, &board)
		testing.expect(t, result == .VICTORY && winner == 2, "round wins take precedence over the last round's points")
		match = {team_scores = {0, 50, 50}}
		result, winner = end_screen_native_result(&match, &board)
		testing.expect(t, result == .DRAW && winner == 0)
		rows := []Scoreboard_Row{{is_you = true}, {}}
		ffa := Scoreboard{rows = rows}
		result, _ = end_screen_native_result(&match, &ffa)
		testing.expect(t, result == .VICTORY, "the top FFA player wins")
	}

	@(test)
	end_screen_visibility_follows_match_phase :: proc(t: ^testing.T) {
		client := Client{local_practice = true}
		client.game.ready = true
		client.mouse_state.locked, client.scoreboard_open = true, true
		testing.expect(t, !client_end_screen_update(&client, 1, false), "no end screen during play")
		client.game.match.phase = .ENDED
		testing.expect(t, client_end_screen_update(&client, 2, true) && client.end_screen_started == 2, "the press that was already held cannot dismiss the new screen")
		testing.expect(t, !client.mouse_state.locked && !client.scoreboard_open, "the end screen releases the cursor and closes the held board")
		testing.expect(t, client_end_screen_update(&client, 3, false))
		testing.expect(t, !client_end_screen_update(&client, 4, true) && !client_end_screen_update(&client, 5, false), "dismissing reveals the menu for the rest of the break")
		client.game.match.phase = .LIVE
		testing.expect(t, !client_end_screen_update(&client, 6, false) && !client.end_screen_active)
		client.game.match.phase = .ENDED
		testing.expect(t, client_end_screen_update(&client, 7, false), "the next match end shows again")
		client.local_practice = false
		testing.expect(t, !client_end_screen_update(&client, 8, false), "an idle background map never shows results")
	}

	@(test)
	end_screen_renders_title_then_standings :: proc(t: ^testing.T) {
		logger := context.logger
		context = runtime.default_context()
		context.logger = logger
		if !testing.expect(t, bool(glfw.Init())) { return }
		defer glfw.Terminate()
		glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)
		glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 5)
		window := glfw.CreateWindow(1280, 720, "End screen", nil, nil)
		if !testing.expect(t, window != nil) { return }
		defer glfw.DestroyWindow(window)
		glfw.MakeContextCurrent(window)
		gl.load_up_to(4, 5, glfw.gl_set_proc_address)
		gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
		gl.ClearColor(0.16, 0.18, 0.20, 1)
		framebuffer, color_texture: u32
		gl.GenFramebuffers(1, &framebuffer)
		gl.GenTextures(1, &color_texture)
		defer gl.DeleteFramebuffers(1, &framebuffer)
		defer gl.DeleteTextures(1, &color_texture)
		gl.BindFramebuffer(gl.FRAMEBUFFER, framebuffer)
		gl.BindTexture(gl.TEXTURE_2D, color_texture)
		gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGB8, 1280, 720, 0, gl.RGB, gl.UNSIGNED_BYTE, nil)
		gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, color_texture, 0)
		gl.BindTexture(gl.TEXTURE_2D, 0)
		g_active_texture = 0
		client := Client{ui = ui_init(), bindings = menuui.default_bindings(), local_practice = true}
		defer { overlay_fini(); ui_fini(client.ui); resource_cache_fini() }
		defer delete(client.game.players)
		players := [3]shared.Player{{uid = 1, team = 1, score = 450, kills = 4, deaths = 1, is_you = true}, {uid = 2, team = 2, score = 1200, kills = 12, deaths = 3}, {uid = 3, team = 1, score = 90, kills = 1, deaths = 6}}
		for &player in players { append(&client.game.players, &player) }
		client.game.ready = true
		client.game.match = {phase = .ENDED, team_scores = {0, 540, 1200}}
		client.viewport_width, client.viewport_height = 1280, 720
		gl.Viewport(0, 0, 1280, 720)
		testing.expect(t, client_end_screen_update(&client, 10, false))
		snapshot :: proc(client: ^Client, now: f64, pixels: []u8) {
			gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
			ui_update(client.ui, f32(client.viewport_width), f32(client.viewport_height))
			end_screen_render(client, now)
			gl.ReadPixels(0, 0, client.viewport_width, client.viewport_height, gl.RGB, gl.UNSIGNED_BYTE, raw_data(pixels))
		}
		blank := make([]u8, 1280*720*3)
		title := make([]u8, len(blank))
		standings := make([]u8, len(blank))
		defer { delete(blank); delete(title); delete(standings) }
		gl.Clear(gl.COLOR_BUFFER_BIT)
		gl.ReadPixels(0, 0, 1280, 720, gl.RGB, gl.UNSIGNED_BYTE, raw_data(blank))
		snapshot(&client, 11, title)
		snapshot(&client, 10+END_SCREEN_PANEL_DELAY+0.1, standings)
		w, h := client.ui.width/client.ui.scale, client.ui.height/client.ui.scale
		testing.expect(t, match_hud_region_delta(&client, title, standings, w*0.5-300, h*0.15, w*0.5+300, h*0.27) > 1000, "the standings appear below the team totals after the browser's five second delay")
		testing.expect(t, match_hud_region_delta(&client, blank, title, w*0.5-300, h*0.3, w*0.5+300, h*0.45) > 1000, "the result title starts at the center")
		when #config(HUD_PREVIEW, false) {
			for pixels, i in ([2][]u8{title, standings}) {
				file := make([dynamic]u8)
				defer delete(file)
				append(&file, ..transmute([]u8)fmt.tprintf("P6\n%d %d\n255\n", 1280, 720))
				for row := 719; row >= 0; row -= 1 { append(&file, ..pixels[row*1280*3:(row+1)*1280*3]) }
				testing.expect(t, os.write_entire_file(fmt.tprintf("bin/end-screen-%d.ppm", i), file[:]) == nil)
			}
		}
		testing.expect(t, gl.GetError() == gl.NO_ERROR)
	}
}
