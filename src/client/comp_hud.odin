package main

import "core:fmt"
import "core:strings"
import glfw "vendor:glfw"
import shared "../shared"

// Competitive HUD additions: enemies-on-point counter and mini scoreboard
// (the chat is in chat.odin). Each one is a Settings > Game toggle and costs nothing when off.

// ---------------------------------------------------------------- on point

// glorp's method: Krunker gives an objective team 10 points per player on the
// point per scoring tick, so a rise in the enemy team's objective score / 10
// is the number of enemies on the point. It drops to 0 after 1.6 s without
// a rise. (Mirrors glorp's hpEnemyCounter.js.)
ENEMY_COUNTER_HOLD :: 1.6

Enemy_Counter :: struct {
	last_score: u32,
	count:      u32,
	clear_at:   f64,
	enemy_team: i32,
}

g_enemy_counter: Enemy_Counter

client_local_team :: proc(client: ^Client) -> i32 {
	if client.me != nil && (client.me.team == 1 || client.me.team == 2) { return client.me.team }
	if client.lobby_team == 1 || client.lobby_team == 2 { return client.lobby_team }
	return 0
}

enemy_counter_tick :: proc(client: ^Client) {
	counter := &g_enemy_counter
	mode := client.game.mode
	local := client_local_team(client)
	if mode == nil || !mode.objective || !mode.config.teams || local == 0 { counter^ = {}; return }
	enemy := 3 - local
	score := client.game.match.team_scores[enemy]
	now := glfw.GetTime()
	if counter.enemy_team != enemy { counter^ = {enemy_team = enemy, last_score = score}; return }
	if score > counter.last_score {
		counter.count = (score - counter.last_score) / 10
		counter.clear_at = now + ENEMY_COUNTER_HOLD
	}
	counter.last_score = score // Also follows round resets downwards.
	if now >= counter.clear_at { counter.count = 0 }
}

// ---------------------------------------------------------- leaderboard

// Krunker's leaderboard (#leaderboardHolder, top/right 15, 350 wide): "1."
// at .7, the name (you and teammates white, enemies red) and the score
// at .7, 18px rows. Settings > Game > Leaderboard (on by default).
LEADERBOARD_ROWS :: 10

leaderboard_visible :: proc(client: ^Client) -> bool {
	return !client.hud_settings.hide_leaderboard && !client.scoreboard_open && (client.krunker.connected || client.local_practice)
}

// Bottom edge of the leaderboard, so the killfeed can sit under it.
g_leaderboard_bottom: f32

leaderboard_render :: proc(client: ^Client) {
	g_leaderboard_bottom = 0
	ui := client.ui
	s := ui.scale
	right := ui.width - 15*s
	if !leaderboard_visible(client) { stats_row_render(client, right, 15*s); return }
	board := client_scoreboard(client)
	if len(board.rows) == 0 { stats_row_render(client, right, 15*s); return }
	score_column := board.column_count > 0 ? 0 : -1
	for c in 0..<board.column_count { if strings.to_lower(board.columns[c], context.temp_allocator) == "score" { score_column = c } }
	rows := min(len(board.rows), LEADERBOARD_ROWS)
	row_h := 18*KH_LINE*s
	width := 350*s
	x := right - width
	y := 15*s
	height := (6 + 20)*s + row_h*f32(rows)
	kh_box(ui, x, y, width, height)
	for i in 0..<rows {
		row := &board.rows[i]
		top := y + 13*s + row_h*f32(i)
		left := x + 18*s
		kh_text(ui, KH_MUTED, fmt.tprintf("%d.", i+1), left, top, 18)
		color := KH_WHITE
		if !row.is_you {
			color = KH_RED
			if board.teams && board.local_team > 0 && row.team == board.local_team { color = KH_WHITE }
		}
		score := score_column >= 0 ? row.cells[score_column] : ""
		score_w := kh_measure(ui, score, 18)
		name_x := left + 28*s + 5*s
		name := scoreboard_fit_text(ui, row.name, 18*KH_EM*s, x + width - 18*s - score_w - 8*s - name_x)
		kh_text(ui, color, name, name_x, top, 18)
		kh_text(ui, KH_MUTED, score, x + width - 18*s - score_w, top, 18)
	}
	g_leaderboard_bottom = y + height
	stats_row_render(client, right, g_leaderboard_bottom + 10*s)
}

skull_icon_kills, skull_icon_deaths: u32

// .topRightCounters under the leaderboard, right-aligned: .statIcon boxes
// (black, a grey inner with 5px padding) with your kills and deaths (24px
// icon, 17px value at .7), and glorp's enemies-on-point counter ("on N").
stats_row_render :: proc(client: ^Client, right, top: f32) {
	if !client.krunker.connected { return }
	ui := client.ui
	s := ui.scale
	world := &client.krunker_world
	kills, deaths: u32
	for player in world.players { if player.sid == world.local_sid { kills, deaths = player.kills, player.deaths } }
	if client.me != nil { kills, deaths = max(kills, client.me.kills), max(deaths, client.me.deaths) }
	Cell :: struct { icon: u32, label, text: string }
	cells := make([dynamic]Cell, 0, 3, context.temp_allocator)
	if !client.hud_settings.hide_kill_counter { append(&cells, Cell{kill_feed_load_icon(&skull_icon_kills, "img/skull_0.png"), "", fmt.tprintf("%d", kills)}) }
	if !client.hud_settings.hide_death_counter { append(&cells, Cell{kill_feed_load_icon(&skull_icon_deaths, "img/skull_1.png"), "", fmt.tprintf("%d", deaths)}) }
	if !client.hud_settings.hide_enemy_counter && g_enemy_counter.enemy_team != 0 {
		append(&cells, Cell{0, "on", fmt.tprintf("%d", g_enemy_counter.count)})
	}
	line := 17*KH_LINE*s
	h := 16*s + line
	x := right
	for i := len(cells)-1; i >= 0; i -= 1 {
		cell := cells[i]
		lead: f32 = 0
		if cell.icon != 0 { lead = 24*s + 4*s }
		if len(cell.label) > 0 { lead = kh_measure(ui, cell.label, 15) + 4*s }
		w := 16*s + lead + kh_measure(ui, cell.text, 17)
		x -= w
		kh_box(ui, x, top, w, h)
		cx := x + 8*s
		if cell.icon != 0 { ui_draw_image(ui, cell.icon, cx, top + (h - 24*s)*0.5, 24*s, 24*s) }
		if len(cell.label) > 0 { kh_text(ui, KH_WHITE, cell.label, cx, top + 8*s + (17 - 15)*KH_ASCENT*s, 15) }
		color := KH_MUTED
		if len(cell.label) > 0 && g_enemy_counter.count > 0 { color = KH_RED }
		kh_text(ui, color, cell.text, cx + lead, top + 8*s, 17)
		x -= 5*s
	}
}

// The kill chat and player chat live in chat.odin.
