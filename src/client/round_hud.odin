package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import glfw "vendor:glfw"
import curl "vendor:curl"
import shared "../shared"
import kproto "../krunker"

// Krunker's round messages, as its canvas animates them (animateText,
// checked against Krunker's game code, 2026-11-18):
//
// - Countdown: for the last 5 seconds of "match starting in" and
//   "intermission", the number at 26% height, 300px shrinking to 120px at
//   1.2px/ms, shown 700ms (the last 100 fading), with a 15px #363636
//   outline, and the cntd_5 .. cntd_1 voice (volume 0.2).
// - Popups (Krunker's v86228): a white title at 215px (90px shrinking to
//   54px, 2.1s) over a #fbc02d subtitle at 280px (28px to 25.2px, 1.5s),
//   with pop_3 (0.3): the mode's title ("Hardpoint / Attack the Objective")
//   when play starts, and the server's "tx" ("Overtime / +60 Seconds").
// - An intermission begins (RDS): "Switching Sides" over "<team> is in the
//   Lead!" or "Both Teams are Equal!" with woosh_0 (0.5) instead of pop_3,
//   and "Switching Sides. Prepare for the next Round" in chat.
// - Every spawn (the server's "start"): reload_3 (0.2).
//
// Sounds Krunker's game-file pack lacks are downloaded from Krunker's asset
// host into assets/sound once, in the background.

// Krunker's generic team names (v8447); the lead message uses these, not
// the lobby's own team names.
KRUNKER_TEAM_LETTERS := [?]string{"Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot"}
ROUND_TEXT_SHADOW :: shared.Vec4{0x36/255.0, 0x36/255.0, 0x36/255.0, 1}
ROUND_SUB_COLOR :: shared.Vec4{0xfb/255.0, 0xc0/255.0, 0x2d/255.0, 1}
ROUND_SWITCH_CHAT :: "Switching Sides. Prepare for the next Round"

// One of Krunker's animated canvas texts. Sizes are canvas pixels (times
// the HUD scale), times are milliseconds.
Round_Text :: struct {
	text: [64]u8,
	length: int,
	color: shared.Vec4,
	top: f32,
	top_percent: bool,
	size, min_size, shrink: f32,
	life, fade, opacity: f32,
	shadow: f32,
}

Round_Hud :: struct {
	last_number: int,
	was_counting: bool,
	sounds_loaded: bool,
	timer, title, sub: Round_Text,
	last_tick: f64,
	sounds: ^thread.Thread,
	sounds_done: bool, // atomic
	sounds_applied: bool,
}

g_round: Round_Hud

// animateText(div, text, size, scaleSpeed, life, fade, delay, callback, minScale, shadow)
round_text_start :: proc(item: ^Round_Text, text: string, size, shrink, life, fade, min_fraction, shadow: f32) {
	item.length = copy(item.text[:], text)
	item.size, item.shrink = size, shrink
	item.min_size = shrink > 0 ? size*min_fraction : size
	item.life, item.fade, item.opacity, item.shadow = life, fade, 1, shadow
}

round_text_tick :: proc(item: ^Round_Text, ms: f32) {
	if item.life <= 0 { return }
	if item.size > item.min_size { item.size = max(item.min_size, item.size - item.shrink*ms) }
	item.life -= ms
	if item.life <= 0 { item.life = 0; return }
	if item.fade > 0 && item.life <= item.fade { item.opacity = item.life/item.fade }
}

round_text_render :: proc(ui: ^UI, item: ^Round_Text) {
	if item.life <= 0 || item.length == 0 { return }
	s := ui.scale
	y := item.top_percent ? ui.height*item.top/100 : item.top*s
	color := item.color
	color.a *= item.opacity
	shadow := ROUND_TEXT_SHADOW
	shadow.a *= item.opacity
	canvas_text(ui, color, string(item.text[:item.length]), ui.width*0.5, y, item.size*s, .MIDDLE, shadow, item.shadow*s, 1*s)
}

// Krunker's v86228(title, sub, quiet, sub_size).
round_hud_popup :: proc(client: ^Client, title, sub: string, quiet := false, sub_size: f32 = 28) {
	round := &g_round
	if !quiet && client.audio != nil { audio_play_effect(client.audio, "pop_3", .EFFECTS, 0.3, priority = 5) }
	if len(title) > 0 {
		round.title.color, round.title.top, round.title.top_percent = {1, 1, 1, 1}, 215, false
		round_text_start(&round.title, title, 90, 0.3, 2100, 100, 0.6, 10)
	}
	if len(sub) > 0 {
		round.sub.color, round.sub.top, round.sub.top_percent = ROUND_SUB_COLOR, 280, false
		round_text_start(&round.sub, sub, sub_size, 0.1, 1500, 100, 0.9, 8)
	}
}

round_lead_message :: proc(lead: i32) -> string {
	if lead >= 1 && int(lead) <= len(KRUNKER_TEAM_LETTERS) { return fmt.tprintf("%s is in the Lead!", KRUNKER_TEAM_LETTERS[lead-1]) }
	return "Both Teams are Equal!"
}

// RDS without "game over": the round ended and an intermission starts.
round_hud_intermission :: proc(client: ^Client, lead: i32) {
	if client.audio != nil { audio_play_effect(client.audio, "woosh_0", .EFFECTS, 0.5, priority = 5) }
	round_hud_popup(client, "Switching Sides", round_lead_message(lead), quiet = true)
	chat_system_add(ROUND_SWITCH_CHAT)
}

// "tx" [title, sub, quiet, sub_size]: a server popup ("Overtime").
round_hud_server_popup :: proc(client: ^Client, packet: []kproto.Krunker_Msgpack_Value) {
	title := len(packet) > 1 ? packet[1].(string) or_else "" : ""
	sub := len(packet) > 2 ? packet[2].(string) or_else "" : ""
	quiet := len(packet) > 3 && kproto.krunker_world_bool(packet[3])
	size: f32 = 28
	if len(packet) > 4 { if n := kproto.krunker_world_i32(packet[4], 0); n > 0 && n <= 200 { size = f32(n) } }
	if len(title) > 64 || len(sub) > 64 { return }
	round_hud_popup(client, title, sub, quiet, size)
}

// The server's "start": you are in the game (every spawn).
round_hud_spawned :: proc(client: ^Client) {
	if client.audio != nil { audio_play_effect(client.audio, "reload_3", .EFFECTS, 0.2, priority = 5) }
}

@(private = "file")
round_counting :: proc(client: ^Client) -> (number: int, counting: bool) {
	if !client.krunker.connected { return 0, false }
	world := &client.krunker_world
	if world.countdown != .STARTING && world.countdown != .INTERMISSION { return 0, false }
	remaining := world.countdown_remaining - f32(max(0, glfw.GetTime()-world.countdown_received_at))
	return int(remaining + 0.999), true
}

round_mode_title :: proc(client: ^Client) -> (title, sub: string) {
	switch client.krunker_world.mode_index {
	case 0: return "Free for All", "Destroy the Enemy"
	case 1: return "Team Deathmatch", "Destroy the Enemy"
	case 2: return "Hardpoint", "Attack the Objective"
	}
	if client.game.mode != nil && client.game.mode.objective { return "Hardpoint", "Attack the Objective" }
	if client.game.mode != nil && !client.game.mode.config.teams { return "Free for All", "Destroy the Enemy" }
	return "Team Deathmatch", "Destroy the Enemy"
}

round_hud_tick :: proc(client: ^Client) {
	round := &g_round
	now := glfw.GetTime()
	ms := f32(clamp((now - round.last_tick)*1000, 0, 250))
	round.last_tick = now
	round_text_tick(&round.timer, ms)
	round_text_tick(&round.title, ms)
	round_text_tick(&round.sub, ms)
	number, counting := round_counting(client)
	// Decode the five voice lines once, as soon as a countdown is running, so
	// the first number never waits for a file read.
	if counting && !round.sounds_loaded && client.audio != nil {
		round.sounds_loaded = true
		for n in 1..=5 { audio_load_sample(client.audio, fmt.tprintf("%ssound/cntd_%d.mp3", shared.assets_path(), n)) }
	}
	if counting && number >= 1 && number <= 5 && number != round.last_number {
		name := fmt.tprintf("cntd_%d", number)
		if !os.exists(fmt.tprintf("%ssound/%s.mp3", shared.assets_path(), name)) { name = "tick_0" }
		// Krunker's voice countdown is a game sound (its SFX volume), not a menu
		// click: on SR's UI channel it was silent for anyone with UI sounds off.
		audio_play_effect(client.audio, name, .EFFECTS, 0.2, priority = 5)
		round.timer.color, round.timer.top, round.timer.top_percent = {1, 1, 1, 1}, 26, true
		round_text_start(&round.timer, fmt.tprintf("%d", number), 300, 1.2, 700, 100, 0.4, 15)
	}
	round.last_number = counting ? number : 0
	if round.was_counting && !counting && client.krunker.connected && client.krunker_world.match.phase == .LIVE {
		title, sub := round_mode_title(client)
		round_hud_popup(client, title, sub)
	}
	round.was_counting = counting
}

round_hud_render :: proc(client: ^Client) {
	round := &g_round
	ui := client.ui
	round_text_render(ui, &round.sub)
	round_text_render(ui, &round.title)
	round_text_render(ui, &round.timer)
}

// ------------------------------------------------------------- sounds

ROUND_SOUND_HOSTS := [?]string{"https://assets.krunker.io/sound/", "https://krunker.io/sound/"}

// Krunker sounds the game-file pack lacks: fetched when missing.
KRUNKER_SOUNDS_MISSING := [?]string{"cntd_1", "cntd_2", "cntd_3", "cntd_4", "cntd_5", "pop_3", "woosh_0", "reload_3"}

// Krunker's own sound files that SR Client plays. Downloaded once from
// Krunker's asset host (as the browser loads them) and refreshed when this
// list's version changes, so SR always plays Krunker's real sounds (older
// game-file packages had placeholders, e.g. crit_0 identical to hit_0).
KRUNKER_SOUNDS_VERSION :: "1"
KRUNKER_SOUNDS_REFRESH := [?]string{
	"hit_0", "crit_0", "headshot_0", "jump_0", "jump_1", "step_0", "step_1",
	"slide_0", "takedmg_0", "takedmg_1", "whizz_0", "whizz_1", "reload_1", "reload_2",
}

Krunker_Sound_Job :: struct {
	directory: string,
	refresh: bool, // the version marker is old: fetch every refresh sound again
}

round_sounds_start :: proc() {
	directory := fmt.tprintf("%ssound/", shared.assets_path())
	marker, _ := os.read_entire_file_from_path(fmt.tprintf("%s.krunker-sounds", directory), context.temp_allocator)
	refresh := string(marker) != KRUNKER_SOUNDS_VERSION
	missing := refresh
	for name in KRUNKER_SOUNDS_MISSING { if !os.exists(fmt.tprintf("%s%s.mp3", directory, name)) { missing = true } }
	if !missing { return }
	job := new(Krunker_Sound_Job)
	job^ = {strings.clone(directory), refresh}
	g_round.sounds = thread.create_and_start_with_poly_data(job, round_sounds_run)
}

// After the background download: swap freshly downloaded sounds into the
// running mixer (main thread, once).
round_sounds_tick :: proc(client: ^Client) {
	if g_round.sounds == nil || !sync.atomic_load(&g_round.sounds_done) || g_round.sounds_applied { return }
	g_round.sounds_applied = true
	if client.audio == nil { return }
	for name in KRUNKER_SOUNDS_REFRESH {
		key := fmt.tprintf("%ssound/%s.mp3", shared.assets_path(), name)
		if sample, ok := client.audio.samples[key]; ok { audio_reload_sample(client.audio, key, sample) }
	}
}

// At exit: a finished download thread is cleaned up; a running one is left
// to the process exit so quitting never waits for the network.
round_sounds_stop :: proc() {
	if g_round.sounds != nil && sync.atomic_load(&g_round.sounds_done) { thread.join(g_round.sounds); thread.destroy(g_round.sounds); g_round.sounds = nil }
}

@(private = "file")
round_sound_write :: proc "c" (buffer: [^]byte, size, count: c.size_t, output: rawptr) -> c.size_t {
	context = runtime.default_context()
	data := cast(^[dynamic]byte)output
	total := int(size*count)
	if len(data)+total > 2*1024*1024 { return 0 }
	append(data, ..buffer[:total])
	return c.size_t(total)
}

@(private = "file")
round_sounds_download :: proc(url, path: string) -> bool {
	for host in ROUND_SOUND_HOSTS {
		handle := curl.easy_init()
		if handle == nil { return false }
		data: [dynamic]byte
		curl.easy_setopt(handle, .URL, strings.clone_to_cstring(fmt.tprintf("%s%s", host, url), context.temp_allocator))
		curl.easy_setopt(handle, .FOLLOWLOCATION, c.long(1))
		curl.easy_setopt(handle, .CONNECTTIMEOUT_MS, c.long(8000))
		curl.easy_setopt(handle, .TIMEOUT_MS, c.long(20000))
		curl.easy_setopt(handle, .USERAGENT, cstring("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"))
		curl.easy_setopt(handle, .REFERER, cstring("https://krunker.io/"))
		curl.easy_setopt(handle, .WRITEFUNCTION, curl.write_callback(round_sound_write))
		curl.easy_setopt(handle, .WRITEDATA, rawptr(&data))
		code := curl.easy_perform(handle)
		status: c.long
		curl.easy_getinfo(handle, .RESPONSE_CODE, &status)
		curl.easy_cleanup(handle)
		// An MP3 starts with an ID3 tag or a frame sync; anything else is an error page.
		is_mp3 := len(data) > 128 && (string(data[:3]) == "ID3" || (data[0] == 0xFF && (data[1] & 0xE0) == 0xE0))
		// Write beside, then replace: a failed download keeps the old file.
		saved := false
		if code == .E_OK && status == 200 && is_mp3 {
			temp := fmt.tprintf("%s.part", path)
			if os.write_entire_file(temp, data[:]) == nil {
				_ = os.remove(path)
				saved = os.rename(temp, path) == nil
			}
		}
		delete(data)
		if saved { return true }
	}
	return false
}

@(private = "file")
round_sounds_run :: proc(job: ^Krunker_Sound_Job) {
	defer { delete(job.directory); free(job) }
	defer sync.atomic_store(&g_round.sounds_done, true)
	if curl.global_init(curl.GLOBAL_DEFAULT) != .E_OK { return }
	defer curl.global_cleanup()
	for name in KRUNKER_SOUNDS_MISSING {
		path := fmt.tprintf("%s%s.mp3", job.directory, name)
		if !os.exists(path) { round_sounds_download(fmt.tprintf("%s.mp3", name), path) }
		free_all(context.temp_allocator)
	}
	if !job.refresh { return }
	all := true
	for name in KRUNKER_SOUNDS_REFRESH {
		if !round_sounds_download(fmt.tprintf("%s.mp3", name), fmt.tprintf("%s%s.mp3", job.directory, name)) { all = false }
		free_all(context.temp_allocator)
	}
	if all { _ = os.write_entire_file(fmt.tprintf("%s.krunker-sounds", job.directory), transmute([]byte)string(KRUNKER_SOUNDS_VERSION)) }
}
