package main

import "core:fmt"
import glfw "vendor:glfw"
import menuui "../menu"
import shared "../shared"
import kproto "../krunker"

// The browser shows the animated result title first and reveals endInfo and
// the end table after setTimeout(..., 5000).
END_SCREEN_PANEL_DELAY :: 5.0
END_SCREEN_TITLE_INTRO :: 0.4

End_Result :: enum { VICTORY, DEFEAT, DRAW, MATCH_OVER }
END_RESULT_LABELS := [End_Result]string{.VICTORY = "VICTORY", .DEFEAT = "DEFEAT", .DRAW = "DRAW", .MATCH_OVER = "MATCH OVER"}

End_Screen :: struct {
	result: End_Result,
	// Winning team for the team totals trophy; 0 without a team winner.
	winner_team: i32,
	teams, abandoned: bool,
	timer: string,
	board: Scoreboard,
}

// Browser: -1 == didWin ? "dra" : didWin ? "vic" : noWinner ? "end" : "def".
end_screen_result :: proc(did_win: i32, no_winner: bool) -> End_Result {
	if did_win == -1 { return .DRAW }
	if did_win != 0 { return .VICTORY }
	return no_winner ? .MATCH_OVER : .DEFEAT
}

// Krunker's reward formatter: "+N KR", or NONE without a reward.
end_screen_reward :: proc(cell: string) -> string {
	return len(cell) == 0 || cell == "0" ? "NONE" : fmt.tprintf("+%s KR", cell)
}

// Live END rows keep the server's endSort order and the mode's endStats
// columns (minus sid). Without a decoded table, fall back to the leaderboard.
end_screen_board_from_world :: proc(world: ^kproto.Krunker_World_State) -> Scoreboard {
	stats, known := kproto.krunker_mode_end_stats(world.mode_index)
	if !known || len(world.end_entries) == 0 { return scoreboard_from_world(world) }
	board: Scoreboard
	scoreboard_set_columns(&board, stats[2:])
	rows := make([]Scoreboard_Row, len(world.end_entries), context.temp_allocator)
	for entry, i in world.end_entries {
		row := &rows[i]
		row.name, row.order, row.is_you = entry.name, i32(i), entry.sid == world.local_sid
		for player in world.players {
			if player.sid != entry.sid { continue }
			row.team = player.team
			if len(player.name) > 0 { row.name = player.name } // the browser prefers the live alias
		}
		for c in 0..<board.column_count {
			row.cells[c] = stats[c+2] == "reward" ? end_screen_reward(entry.cells[c]) : entry.cells[c]
		}
	}
	for player in world.players { if player.sid == world.local_sid { board.local_team = player.team } }
	scoreboard_finish(&board, rows)
	return board
}

// Native and local sessions resolve the same way as game_resolve_round: round
// wins first, then the final team totals. FFA is won by the top player.
end_screen_native_result :: proc(match: ^shared.Match_State, board: ^Scoreboard) -> (End_Result, i32) {
	if !board.teams {
		if len(board.rows) == 0 { return .DRAW, 0 }
		return board.rows[0].is_you ? .VICTORY : .DEFEAT, 0
	}
	winner: i32
	if match.round_wins[1] != match.round_wins[2] { winner = match.round_wins[1] > match.round_wins[2] ? 1 : 2 }
	else if match.team_scores[1] != match.team_scores[2] { winner = match.team_scores[1] > match.team_scores[2] ? 1 : 2 }
	if winner == 0 { return .DRAW, 0 }
	return end_screen_result(board.local_team == winner ? 1 : 0, false), winner
}

client_end_screen :: proc(client: ^Client) -> End_Screen {
	screen: End_Screen
	if client.krunker.connected || client.end_hold {
		world := &client.krunker_world
		screen.board = end_screen_board_from_world(world)
		if world.end_received {
			// noWinner modes are outside the decoded mode registry.
			screen.result = end_screen_result(world.end_result, false)
			screen.winner_team = world.winner_team == 1 || world.winner_team == 2 ? world.winner_team : 0
		} else {
			// gsc POST_MATCH can end the match before END arrives; resolve
			// from the tracked round wins and totals rather than showing DRAW.
			screen.result, screen.winner_team = end_screen_native_result(&world.match, &screen.board)
		}
		screen.abandoned = world.end_index == 3 || world.timer_kind == 3
		switch {
		case screen.abandoned: screen.timer = "MATCH ABANDONED"
		case world.timer_kind == 2: screen.timer = "MATCH OVER"
		case len(world.end_timer_text) > 0: screen.timer = fmt.tprintf("Next Round in %s", world.end_timer_text)
		}
	} else {
		screen.board = scoreboard_from_game(&client.game)
		screen.result, screen.winner_team = end_screen_native_result(&client.game.match, &screen.board)
	}
	screen.teams = screen.board.teams
	screen.board.team_names = client_team_names(client)
	// END's final tms totals live in the world state on live lobbies.
	screen.board.team_scores = client.krunker.connected ? client.krunker_world.match.team_scores : client.game.match.team_scores
	// The end table is one standings list; team colors stay on the names.
	screen.board.teams = false
	screen.board.rank_label = "#"
	return screen
}

client_match_ended :: proc(client: ^Client) -> bool {
	if client.end_hold { return true }
	if client.krunker.connected { return client.krunker_world.has_match && client.krunker_world.match.phase == .ENDED }
	return (client.net.connected || client.local_practice) && client.game.ready && client.game.match.phase == .ENDED
}

// Shown from the moment a match ends until the next match starts. Dismissing
// (Escape or the Menu binding) reveals the lobby menu for the rest of the break.
client_end_screen_update :: proc(client: ^Client, now: f64, dismiss: bool) -> bool {
	if !client_match_ended(client) {
		client.end_screen_active, client.end_screen_dismissed = false, false
		return false
	}
	if !client.end_screen_active {
		client.end_screen_active, client.end_screen_dismissed, client.end_screen_started = true, false, now
		// The browser releases pointer lock for its end UI.
		if client.window != nil { glfw.SetInputMode(client.window, glfw.CURSOR, glfw.CURSOR_NORMAL) }
		client.mouse_state.locked, client.scoreboard_open = false, false
	} else if dismiss {
		client.end_screen_dismissed = true
	}
	return !client.end_screen_dismissed
}

end_screen_result_color :: proc(result: End_Result) -> shared.Vec4 {
	switch result {
	case .VICTORY: return shared.hex_to_vec(0x9eeb56)
	case .DEFEAT: return shared.hex_to_vec(0xeb5656)
	case .DRAW, .MATCH_OVER:
	}
	return {1, 1, 1, 1}
}

// Stand-in for the browser's emoji_events trophy icon.
end_screen_trophy :: proc(ui: ^UI, x, y, size: f32) {
	gold := shared.hex_to_vec(0xffd447)
	ui_round_rect(ui, gold, x+size*0.2, y, size*0.6, size*0.5, size*0.18)
	ui_fill_rect(ui, gold, x+size*0.44, y+size*0.5, size*0.12, size*0.25)
	ui_fill_rect(ui, gold, x+size*0.25, y+size*0.75, size*0.5, size*0.12)
	ui_stroke_round_rect(ui, gold, x, y+size*0.06, size*0.3, size*0.3, size*0.12, size*0.06)
	ui_stroke_round_rect(ui, gold, x+size*0.7, y+size*0.06, size*0.3, size*0.3, size*0.12, size*0.06)
}

end_screen_render :: proc(client: ^Client, now: f64) {
	ui := client.ui
	s := ui.scale
	white := shared.Vec4{1, 1, 1, 1}
	muted := shared.Vec4{1, 1, 1, 0.6}
	screen := client_end_screen(client)
	elapsed := f32(max(0, now-client.end_screen_started))
	label := END_RESULT_LABELS[screen.result]
	color := end_screen_result_color(screen.result)
	ui_fill_rect(ui, {0, 0, 0, 0.33}, 0, 0, ui.width, ui.height)
	if elapsed < END_SCREEN_PANEL_DELAY {
		// Title zooms from 2.5x to its resting size while fading in.
		t := clamp(elapsed/END_SCREEN_TITLE_INTRO, 0, 1)
		size := 120*s*(2.5-1.5*t)
		color.w = t
		ui_fill_text(ui, color, label, (ui.width-ui_measure_text(ui, label, size))*0.5, ui.height*0.42+size*0.35, size)
		return
	}
	y := 32*s
	if !screen.abandoned {
		ui_fill_text(ui, color, label, (ui.width-ui_measure_text(ui, label, 80*s))*0.5, overlay_numeric_baseline(y, 80*s, 80*s), 80*s)
		y += 96*s
	}
	// endInfo: team totals around the end countdown.
	info_height := 56*s
	timer_width := len(screen.timer) > 0 ? ui_measure_text(ui, screen.timer, 30*s) : 0
	center := ui.width*0.5
	if len(screen.timer) > 0 { ui_fill_text(ui, white, screen.timer, center-timer_width*0.5, overlay_numeric_baseline(y, info_height, 30*s), 30*s) }
	if screen.teams {
		size := 36*s
		trophy := 40*s
		for team in 1..=2 {
			name := screen.board.team_names[team-1]
			score := fmt.tprintf("%d", screen.board.team_scores[team])
			name_width, score_width := ui_measure_text(ui, name, size), ui_measure_text(ui, score, size+8*s)
			won := screen.winner_team == i32(team)
			block := name_width + score_width + 20*s + (won ? trophy+12*s : 0) + 32*s
			left := team == 1 ? center-timer_width*0.5-15*s-24*s-block : center+timer_width*0.5+15*s+24*s
			ui_round_rect(ui, {0, 0, 0, 0.6}, left, y, block, info_height, 6*s)
			ui_fill_rect(ui, MATCH_TEAM_COLORS[team-1], left, y+info_height-3*s, block, 3*s)
			baseline := overlay_numeric_baseline(y, info_height, size)
			x := left + 16*s
			if team == 1 {
				if won { end_screen_trophy(ui, x, y+(info_height-trophy)*0.5, trophy); x += trophy+12*s }
				ui_fill_text(ui, white, name, x, baseline, size)
				ui_fill_text(ui, white, score, x+name_width+20*s, overlay_numeric_baseline(y, info_height, size+8*s), size+8*s)
			} else {
				ui_fill_text(ui, white, score, x, overlay_numeric_baseline(y, info_height, size+8*s), size+8*s)
				ui_fill_text(ui, white, name, x+score_width+20*s, baseline, size)
				if won { end_screen_trophy(ui, x+score_width+20*s+name_width+12*s, y+(info_height-trophy)*0.5, trophy) }
			}
		}
	}
	scoreboard_render(ui, &screen.board, y+info_height+24*s, false)
	code := client.bindings[.MENU][0]
	if code == 0 { code = 256 }
	hint := fmt.tprintf("%s  Menu", menuui.binding_label(code))
	ui_fill_text(ui, muted, hint, (ui.width-ui_measure_text(ui, hint, 24*s))*0.5, ui.height-28*s, 24*s)
	// Developer builds: testers send this file after their games.
	when TESTER_EXPORT { tester_export_button(client, ui, ui.width-220*s-32*s, 32*s, 220*s, 52*s) }
}
