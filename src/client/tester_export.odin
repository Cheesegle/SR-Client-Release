package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:time"
import "vendor:glfw"
import shared "../shared"
import menuui "../menu"

// Tester log export, developer builds only (release builds carry none of it).
//
// Every live game is saved automatically as one "=== Game N ===" section of
// logs/tester-export.txt, which only ever grows: who played, the weapons, the
// input rate, ping, FPS, the PC, the final board and every shot line of that
// game. Saving never depends on the tester:
//   - the game's section is written (and synced to disk) the moment it ends,
//     when the tester leaves early, and when SR closes normally (Alt+F4 too);
//   - while a game runs, the section so far is rewritten every 20 seconds to
//     logs/tester-export-current.txt; if SR is killed or crashes, the next
//     start adds it to the export as an unfinished game.
// The end screen's "Export logs" button copies the whole export to the
// Desktop as SR-Client-test-logs.txt and shows it in Explorer, ready to send.

TESTER_EXPORT :: HITREG_AUDIT
TESTER_EXPORT_FILE :: "logs/tester-export.txt"
TESTER_EXPORT_CURRENT :: "logs/tester-export-current.txt"
TESTER_EXPORT_DESKTOP_NAME :: "SR-Client-test-logs.txt"
TESTER_EXPORT_CHECKPOINT :: 20.0 // seconds between in-progress saves
TESTER_EXPORT_MAX_WEAPONS :: 8
// Frame times are counted in 0.1 ms bins up to 100 ms (one add per frame, no
// allocation), so the export can give the average, the 1% low and hitches
// without storing frames.
TESTER_EXPORT_FRAME_BINS :: 1000

Tester_Weapon_Stats :: struct {
	name: string,
	shots, crosshair_on, server_hits: int,
}

Tester_Export :: struct {
	open: bool, // a live game is being recorded
	shots: strings.Builder, // this game's shot lines (copies of hitreg.log's)
	started_wall: time.Time,
	started_at: f64,
	weapons: [TESTER_EXPORT_MAX_WEAPONS]Tester_Weapon_Stats,
	weapon_count: int,
	rates: [len(menuui.INPUT_RATES)]bool,
	rate_other: bool,
	frames: int,
	frame_seconds: f64,
	worst_frame: f64,
	frame_bins: [TESTER_EXPORT_FRAME_BINS]u32,
	hitches_50ms, hitches_250ms: int, // frames longer than 50 / 250 ms while playing
	ping_sq_sum: f64,
	ping_last: i32,
	ping_change_sum: f64, // sum of |ping - previous ping|, for jitter
	corrections_start, decode_errors_start, pings_answered_start: int,
	ping_sum: f64,
	ping_count: int,
	ping_min, ping_max: i32,
	last_ping_sample: f64,
	last_checkpoint: f64,
	map_name, mode_name, username: string, // heap copies, kept until the save
	recovered: bool,
	// What the end screen shows after a save or an export click.
	status: string,
	status_until: f64,
	last_click: bool,
}
g_export: Tester_Export

@(private = "file")
tester_export_set :: proc(field: ^string, value: string) {
	if field^ == value { return }
	delete(field^)
	field^ = strings.clone(value)
}

@(private = "file")
tester_export_reset :: proc() {
	strings.builder_destroy(&g_export.shots)
	delete(g_export.map_name); delete(g_export.mode_name); delete(g_export.username)
	for i in 0 ..< g_export.weapon_count { delete(g_export.weapons[i].name) }
	status, until, click := g_export.status, g_export.status_until, g_export.last_click
	g_export = {}
	g_export.status, g_export.status_until, g_export.last_click = status, until, click
}

// One resolved shot of the hit registration log (hitreg_audit.odin).
tester_export_shot :: proc(line, weapon: string, input_rate: int, crosshair_on, server_hit: bool) {
	when !TESTER_EXPORT { return }
	if !g_export.open { return }
	strings.write_string(&g_export.shots, line)
	slot := -1
	for i in 0 ..< g_export.weapon_count { if g_export.weapons[i].name == weapon { slot = i; break } }
	if slot < 0 && g_export.weapon_count < TESTER_EXPORT_MAX_WEAPONS {
		slot = g_export.weapon_count
		g_export.weapons[slot].name = strings.clone(weapon)
		g_export.weapon_count += 1
	}
	if slot >= 0 {
		g_export.weapons[slot].shots += 1
		if crosshair_on { g_export.weapons[slot].crosshair_on += 1 }
		if server_hit { g_export.weapons[slot].server_hits += 1 }
	}
	known := false
	for rate, i in menuui.INPUT_RATES { if int(rate) == input_rate { g_export.rates[i] = true; known = true } }
	if !known { g_export.rate_other = true }
}

// Every frame (developer builds): opens, samples and closes the game.
tester_export_tick :: proc(client: ^Client, delta: f32) {
	when !TESTER_EXPORT { return }
	now := glfw.GetTime()
	world := &client.krunker_world
	playing := client.krunker.connected && world.has_match && world.match.phase != .ENDED && world.in_game
	if !g_export.open {
		if playing {
			tester_export_reset()
			g_export.open, g_export.started_wall, g_export.started_at = true, time.now(), now
			g_export.ping_min, g_export.last_checkpoint = max(i32), now
			g_export.corrections_start = client.krunker.prediction_corrections
			g_export.decode_errors_start = client.krunker.decode_errors
			g_export.pings_answered_start = g_net_thread.po_sent
		}
		return
	}
	// Names can arrive after the game starts; keep the latest.
	if world.map_index >= 0 && int(world.map_index) < len(shared.DEFAULT_MAP_NAMES) { tester_export_set(&g_export.map_name, shared.DEFAULT_MAP_NAMES[world.map_index]) }
	title, _ := round_mode_title(client)
	tester_export_set(&g_export.mode_name, title)
	for player in world.players { if player.sid == world.local_sid && len(player.name) > 0 { tester_export_set(&g_export.username, player.name) } }
	// FPS only while actually playing (mouse locked), like a benchmark.
	if client.mouse_state.locked && delta > 0 && delta < 1 {
		g_export.frames += 1
		g_export.frame_seconds += f64(delta)
		g_export.worst_frame = max(g_export.worst_frame, f64(delta))
		g_export.frame_bins[min(int(delta * 10000), TESTER_EXPORT_FRAME_BINS - 1)] += 1
		if delta > 0.05 { g_export.hitches_50ms += 1 }
		if delta > 0.25 { g_export.hitches_250ms += 1 }
	}
	if world.has_ping && world.ping > 0 && now - g_export.last_ping_sample >= 1 {
		g_export.last_ping_sample = now
		g_export.ping_sum += f64(world.ping)
		g_export.ping_sq_sum += f64(world.ping) * f64(world.ping)
		if g_export.ping_count > 0 { g_export.ping_change_sum += abs(f64(world.ping - g_export.ping_last)) }
		g_export.ping_last = world.ping
		g_export.ping_count += 1
		g_export.ping_min, g_export.ping_max = min(g_export.ping_min, world.ping), max(g_export.ping_max, world.ping)
	}
	if client_match_ended(client) {
		hitreg_audit_resolve_all(client, now)
		tester_export_save(client, "finished")
	} else if !client.krunker.connected {
		tester_export_save(client, "left before the end")
	} else if now - g_export.last_checkpoint >= TESTER_EXPORT_CHECKPOINT {
		g_export.last_checkpoint = now
		section := tester_export_section(client, 0, "unfinished (SR closed unexpectedly)")
		tester_export_write(TESTER_EXPORT_CURRENT, section, false)
	}
}

// SR is closing (window closed, Alt+F4): save the game in progress.
tester_export_shutdown :: proc(client: ^Client) {
	when !TESTER_EXPORT { return }
	if !g_export.open { return }
	hitreg_audit_resolve_all(client, glfw.GetTime())
	tester_export_save(client, "unfinished (SR was closed during the game)")
}

// At start: a checkpoint left behind means SR was killed during a game.
tester_export_recover :: proc() {
	when !TESTER_EXPORT { return }
	data, err := os.read_entire_file_from_path(TESTER_EXPORT_CURRENT, context.temp_allocator)
	if err != nil { return }
	if len(data) > 0 {
		number := tester_export_next_number()
		text, _ := strings.replace(string(data), "=== Game 0 ", fmt.tprintf("=== Game %d ", number), 1, context.temp_allocator)
		tester_export_write(TESTER_EXPORT_FILE, text, true)
	}
	_ = os.remove(TESTER_EXPORT_CURRENT)
}

@(private = "file")
tester_export_next_number :: proc() -> int {
	data, err := os.read_entire_file_from_path(TESTER_EXPORT_FILE, context.temp_allocator)
	if err != nil { return 1 }
	return strings.count(string(data), "\n=== Game ") + (strings.has_prefix(string(data), "=== Game ") ? 1 : 0) + 1
}

tester_export_write :: proc(path, text: string, append: bool) -> bool {
	_ = os.make_directory("logs")
	flags: os.File_Flags = {.Write, .Create}
	flags += append ? {.Append} : {.Trunc}
	file, err := os.open(path, flags)
	if err != nil { return false }
	_, werr := os.write_string(file, text)
	_ = os.sync(file)
	os.close(file)
	return werr == nil
}

tester_export_save :: proc(client: ^Client, ending: string) {
	number := tester_export_next_number()
	section := tester_export_section(client, number, ending)
	ok := tester_export_write(TESTER_EXPORT_FILE, section, true)
	_ = os.remove(TESTER_EXPORT_CURRENT)
	g_export.status = ok ? fmt.aprintf("Game %d saved to the test log", number) : "Could not save the test log (logs folder not writable?)"
	g_export.status_until = glfw.GetTime() + 8
	tester_export_reset()
}

@(private = "file")
tester_export_section :: proc(client: ^Client, number: int, ending: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	buf: [32]u8
	date := time.to_string_yyyy_mm_dd(g_export.started_wall, buf[:])
	hour, minute, second := time.clock_from_time(g_export.started_wall)
	duration := glfw.GetTime() - g_export.started_at
	fmt.sbprintf(&b, "=== Game %d === %s %02d:%02d:%02d UTC, %d:%02d long, %s\n", number, date, hour, minute, second, int(duration) / 60, int(duration) % 60, ending)
	fmt.sbprintf(&b, "player: %s\n", len(g_export.username) > 0 ? g_export.username : "(unknown)")
	fmt.sbprintf(&b, "game: %s on %s\n", len(g_export.mode_name) > 0 ? g_export.mode_name : "?", len(g_export.map_name) > 0 ? g_export.map_name : "?")
	fmt.sbprintf(&b, "version: %s (dev)\n", strings.trim_space(SR_VERSION))
	strings.write_string(&b, "inputs per second:")
	any_rate := false
	for seen, i in g_export.rates { if seen { fmt.sbprintf(&b, " %d", menuui.INPUT_RATES[i]); any_rate = true } }
	if g_export.rate_other { strings.write_string(&b, " other") }
	if !any_rate && !g_export.rate_other { fmt.sbprintf(&b, " %d (no shots)", g_krunker_input_rate) }
	strings.write_string(&b, "\n")
	if g_export.ping_count > 0 {
		n := f64(g_export.ping_count)
		mean := g_export.ping_sum / n
		spread := math.sqrt(max(0, g_export.ping_sq_sum / n - mean * mean))
		jitter := g_export.ping_count > 1 ? g_export.ping_change_sum / (n - 1) : 0
		fmt.sbprintf(&b, "ping ms (Krunker's): avg %.0f, min %d, max %d, spread %.1f, jitter %.1f\n", mean, g_export.ping_min, g_export.ping_max, spread, jitter)
	} else { strings.write_string(&b, "ping ms: (none reported)\n") }
	if g_export.frames > 0 && g_export.frame_seconds > 0 {
		low1 := tester_export_frame_percentile(0.99)
		median := tester_export_frame_percentile(0.5)
		fmt.sbprintf(&b, "fps while playing: avg %.0f, median %.0f, 1%% low %.0f, worst frame %.1f ms, hitches over 50 ms: %d, over 250 ms: %d\n",
			f64(g_export.frames) / g_export.frame_seconds, median > 0 ? 1000 / median : 0, low1 > 0 ? 1000 / low1 : 0,
			g_export.worst_frame * 1000, g_export.hitches_50ms, g_export.hitches_250ms)
	}
	fmt.sbprintf(&b, "network: prediction corrections %d, decode errors %d, network thread %s (pings answered on it: %d)\n",
		client.krunker.prediction_corrections - g_export.corrections_start, client.krunker.decode_errors - g_export.decode_errors_start,
		menuui.hud_network_thread(client.hud_settings) ? "on" : "off", g_net_thread.po_sent - g_export.pings_answered_start)
	when SR_DEV { fmt.sbprintf(&b, "input sending: %s\n", menuui.NET_MODE_LABELS[menuui.net_mode_index(client.hud_settings)]) }
	if menuui.hud_input_clock(client.hud_settings) {
		built, q_sent, unstamped, late := krunker_input_clock_stats(&g_input_clock)
		fmt.sbprintf(&b, "inputs on a fixed clock: ON (since SR started: commands built %d, q sent %d, sent before the game thread stamped them %d, late shot stamps %d)\n", built, q_sent, unstamped, late)
	} else {
		strings.write_string(&b, "inputs on a fixed clock: off\n")
	}
	info := gpu_device_info()
	cores := g_cpu_physical_cores > 0 ? fmt.tprintf("%d cores / %d threads", g_cpu_physical_cores, os.get_processor_core_count()) : fmt.tprintf("%d threads", os.get_processor_core_count())
	vram := g_gpu_backend == .Vulkan ? vk_gpu_vram_mb() : 0
	fmt.sbprintf(&b, "pc: %s (%s) | %s%s | driver %s | %s\n", cpu_model_name(), cores, tester_export_gpu_name(),
		vram > 0 ? fmt.tprintf(" (%d GB VRAM)", (vram + 512) / 1024) : "", info.version, tester_export_system_text())
	if len(g_cpu_pinning_text) > 0 { fmt.sbprintf(&b, "cpu pinning: %s\n", g_cpu_pinning_text) }
	if monitor := glfw.GetPrimaryMonitor(); monitor != nil {
		mode := glfw.GetVideoMode(monitor)
		fmt.sbprintf(&b, "monitor: %dx%d @ %d Hz, fps limit %s\n", mode.width, mode.height, mode.refresh_rate, menuui.game_fps_limit_validate(client.hud_settings.fps_limit) > 0 ? fmt.tprintf("%d", menuui.game_fps_limit_validate(client.hud_settings.fps_limit)) : "off")
	}
	modes := [Display_Mode]string{.Windowed = "Windowed", .Borderless = "Borderless", .Fullscreen = "Fullscreen"}
	q := client.quality_settings
	fmt.sbprintf(&b, "settings: %s %dx%d, renderer %s, v-sync %s, msaa %d, shadows %s (%s), lighting %s, input rate setting %d\n",
		modes[client.display_mode], client.viewport_width, client.viewport_height, g_gpu_backend == .Vulkan ? "Vulkan" : "Classic (OpenGL)",
		client.vsync ? "on" : "off", q.msaa, q.shadows ? "on" : "off",
		menuui.SHADOW_QUALITY_LABELS[menuui.Shadow_Quality(clamp(q.shadow_quality, 0, 1))],
		menuui.LIGHTING_LABELS[menuui.Lighting_Quality(clamp(q.lighting, 0, 3))], menuui.input_rate_value(client.hud_settings.input_rate))
	strings.write_string(&b, "weapons (shots / crosshair on a player / server hits):\n")
	for i in 0 ..< g_export.weapon_count {
		w := g_export.weapons[i]
		fmt.sbprintf(&b, "  %s: %d / %d / %d\n", w.name, w.shots, w.crosshair_on, w.server_hits)
	}
	if client.krunker.connected && len(client.krunker_world.end_entries) > 0 {
		board := end_screen_board_from_world(&client.krunker_world)
		strings.write_string(&b, "final board:")
		for c in 0 ..< board.column_count { fmt.sbprintf(&b, " | %s", board.columns[c]) }
		strings.write_string(&b, "\n")
		for row in board.rows {
			fmt.sbprintf(&b, "  %s%s", row.is_you ? "* " : "  ", row.name)
			for c in 0 ..< board.column_count { fmt.sbprintf(&b, " | %s", row.cells[c]) }
			strings.write_string(&b, "\n")
		}
	}
	strings.write_string(&b, "shots:\n")
	strings.write_string(&b, strings.to_string(g_export.shots))
	strings.write_string(&b, "\n")
	return strings.to_string(b)
}

// The frame time (ms) at fraction p of this game's frames (0.99 = the 1% low).
@(private = "file")
tester_export_frame_percentile :: proc(p: f64) -> f64 {
	total: u64
	for n in g_export.frame_bins { total += u64(n) }
	if total == 0 { return 0 }
	want := u64(f64(total) * p)
	seen: u64
	for n, i in g_export.frame_bins {
		seen += u64(n)
		if seen > want { return (f64(i) + 0.5) / 10 }
	}
	return f64(TESTER_EXPORT_FRAME_BINS) / 10
}

@(private = "file")
tester_export_gpu_name :: proc() -> string {
	if g_gpu_backend == .Vulkan { return gpu_device_info().renderer }
	return "OpenGL"
}

// End screen button (developer builds): copy the export to the Desktop.
tester_export_button :: proc(client: ^Client, ui: ^UI, x, y, w, h: f32) {
	when !TESTER_EXPORT { return }
	if client.window == nil { return }
	s := ui.scale
	width, height := glfw.GetWindowSize(client.window)
	cx, cy := glfw.GetCursorPos(client.window)
	px, py := f32(cx) * ui.width / f32(max(width, 1)), f32(cy) * ui.height / f32(max(height, 1))
	hover := px >= x && px <= x + w && py >= y && py <= y + h
	down := glfw.GetMouseButton(client.window, glfw.MOUSE_BUTTON_LEFT) == glfw.PRESS
	clicked := hover && !down && g_export.last_click
	g_export.last_click = hover && down
	ui_round_rect(ui, hover ? {0.55, 0.85, 0.3, 1} : {0.4, 0.72, 0.22, 1}, x, y, w, h, 6*s)
	label := "Export logs"
	ui_fill_text(ui, {1, 1, 1, 1}, label, x + (w - ui_measure_text(ui, label, 22*s)) * 0.5, y + h * 0.5 + 8*s, 22*s)
	if clicked { tester_export_click() }
	now := glfw.GetTime()
	if len(g_export.status) > 0 && now < g_export.status_until {
		ui_fill_text(ui, {1, 1, 1, 0.85}, g_export.status, x + w - ui_measure_text(ui, g_export.status, 18*s), y + h + 24*s, 18*s)
	}
}

@(private = "file")
tester_export_click :: proc() {
	data, err := os.read_entire_file_from_path(TESTER_EXPORT_FILE, context.temp_allocator)
	if err != nil || len(data) == 0 {
		g_export.status, g_export.status_until = "No games saved yet: play a game to the end first", glfw.GetTime() + 8
		return
	}
	target := tester_export_desktop_path()
	if len(target) == 0 || !tester_export_write(target, string(data), false) {
		g_export.status, g_export.status_until = "Could not write to the Desktop; the log is in SR's logs folder (tester-export.txt)", glfw.GetTime() + 10
		return
	}
	games := strings.count(string(data), "=== Game ")
	g_export.status = fmt.aprintf("%d game(s) exported to your Desktop: %s", games, TESTER_EXPORT_DESKTOP_NAME)
	g_export.status_until = glfw.GetTime() + 10
	tester_export_show_in_folder(target)
}
