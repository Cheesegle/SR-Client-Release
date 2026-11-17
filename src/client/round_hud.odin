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

// Krunker's round countdown: for the last 5 seconds of "match starting in"
// and "intermission" a big number in the middle of the screen with the
// cntd_5 .. cntd_1 sounds (volume 0.2), then the mode's title popup
// ("Hardpoint / Attack the Objective") when play starts.
//
// The cntd sounds are not part of the game files; they are downloaded from
// Krunker's asset host into assets/sound once, in the background.

ROUND_POPUP_TIME :: 2.6

Round_Hud :: struct {
	last_number: int,
	was_counting: bool,
	sounds_loaded: bool,
	popup_until: f64,
	popup_title, popup_sub: string,
	sounds: ^thread.Thread,
	sounds_done: bool, // atomic
	sounds_applied: bool,
}

g_round: Round_Hud

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
	}
	round.last_number = counting ? number : 0
	if round.was_counting && !counting && client.krunker.connected && client.krunker_world.match.phase == .LIVE {
		round.popup_title, round.popup_sub = round_mode_title(client)
		round.popup_until = glfw.GetTime() + ROUND_POPUP_TIME
	}
	round.was_counting = counting
}

round_hud_render :: proc(client: ^Client) {
	round := &g_round
	ui := client.ui
	s := ui.scale
	if number, counting := round_counting(client); counting && number >= 1 && number <= 5 {
		text := fmt.tprintf("%d", number)
		size := 150*s
		ui_fill_text(ui, shared.Vec4{1, 1, 1, 0.55}, text, (ui.width-ui_measure_text(ui, text, size))*0.5, ui.height*0.42+size*0.35, size)
	}
	now := glfw.GetTime()
	if now < round.popup_until && len(round.popup_title) > 0 {
		alpha := f32(clamp((round.popup_until-now)/0.5, 0, 1))
		size, small := 56*s, 26*s
		y := max(ui.height*0.16, 190*s) // below the round score at the top
		ui_fill_text(ui, shared.Vec4{1, 1, 1, alpha}, round.popup_title, (ui.width-ui_measure_text(ui, round.popup_title, size))*0.5, y, size)
		ui_fill_text(ui, shared.Vec4{1, 0.78, 0.2, alpha}, round.popup_sub, (ui.width-ui_measure_text(ui, round.popup_sub, small))*0.5, y+small*1.3, small)
	}
}

// ------------------------------------------------------------- sounds

ROUND_SOUND_HOSTS := [?]string{"https://assets.krunker.io/sound/", "https://krunker.io/sound/"}

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
	for n in 1..=5 { if !os.exists(fmt.tprintf("%scntd_%d.mp3", directory, n)) { missing = true } }
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
	for n in 1..=5 {
		path := fmt.tprintf("%scntd_%d.mp3", job.directory, n)
		if !os.exists(path) { round_sounds_download(fmt.tprintf("cntd_%d.mp3", n), path) }
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
