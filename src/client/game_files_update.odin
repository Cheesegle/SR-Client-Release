package main

import "base:runtime"
import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import curl "vendor:curl"
import shared "../shared"

// Game files auto-update, like Glorp's: when SR Client starts, it asks Krunker
// for its current game version (one request). The same version as last time
// means nothing changed and the check ends at once. A new version (or the
// first start) checks each map with If-Modified-Since, so unchanged maps cost
// one tiny request. Join and Host wait until the check is done, so nothing of
// it runs while you play. A changed map is checked (valid JSON,
// objects and spawns, the expected name) and written over the old file; SR
// loads maps when it starts, so the new map is used from the next start.
//
// Performance: nothing runs in the game loop. The thread only sleeps on the
// network and parses a changed map once; quitting never waits for it.

GAME_FILES_MAPS_URL :: "https://gapi.svc.krunker.io/maps/"
GAME_FILES_LIST_URL :: "https://matchmaker.krunker.io/game-list?hostname=krunker.io"
GAME_FILES_STATE :: "cache/game-files.txt"
GAME_FILES_LOG :: "logs/game-files.log"
GAME_FILES_MAX_MAP_BYTES :: 16 * 1024 * 1024

Game_Files_Update :: struct {
	thread:  ^thread.Thread,
	done:    bool, // atomic
	updated: int,  // atomic: maps replaced by this run (shown in the menu)
	failed:  int,  // atomic
	reported: bool, // the result was shown in the menu
}
g_game_files: Game_Files_Update

game_files_update_start :: proc() {
	when ODIN_TEST { return }
	g_game_files.thread = thread.create_and_start(game_files_update_run, priority = .Low)
}

// At exit: a finished thread is cleaned up; a running one is left to the
// process exit, as the round sounds download does.
game_files_update_stop :: proc() {
	if g_game_files.thread != nil && sync.atomic_load(&g_game_files.done) {
		thread.join(g_game_files.thread); thread.destroy(g_game_files.thread); g_game_files.thread = nil
	}
}

Game_Files_State :: struct {
	checked:  i64,
	version:  string,      // Krunker's game version at the last complete check
	modified: map[int]i64, // map index -> the server's Last-Modified (unix)
}

game_files_state_load :: proc() -> (state: Game_Files_State) {
	state.modified = make(map[int]i64)
	data, err := os.read_entire_file_from_path(GAME_FILES_STATE, context.temp_allocator)
	if err != nil { return }
	for line in strings.split_lines(string(data), context.temp_allocator) {
		fields := strings.fields(line, context.temp_allocator)
		if len(fields) != 2 { continue }
		if fields[0] == "version" { state.version = strings.clone(fields[1]); continue }
		value, ok := strconv.parse_i64(fields[1])
		if !ok { continue }
		if fields[0] == "checked" { state.checked = value; continue }
		if index, index_ok := strconv.parse_int(fields[0]); index_ok { state.modified[index] = value }
	}
	return
}

game_files_state_save :: proc(state: Game_Files_State) {
	builder := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&builder, "checked %d\n", state.checked)
	if len(state.version) > 0 { fmt.sbprintf(&builder, "version %s\n", state.version) }
	for index in 0..<len(shared.DEFAULT_MAP_NAMES) {
		if value, found := state.modified[index]; found { fmt.sbprintf(&builder, "%d %d\n", index, value) }
	}
	_ = os.make_directory("cache")
	_ = os.write_entire_file(GAME_FILES_STATE, transmute([]byte)strings.to_string(builder))
}

game_files_log :: proc(text: string) {
	_ = os.make_directory("logs")
	line := fmt.tprintf("%v %s\n", time.now(), text)
	file, err := os.open(GAME_FILES_LOG, {.Write, .Create, .Append})
	if err != nil { return }
	defer os.close(file)
	os.write_string(file, line)
}

// The "data" object of Krunker's map response ({"data":{...}}), byte for
// byte, so numbers keep exactly the server's text.
game_files_map_data :: proc(body: string) -> (data: string, ok: bool) {
	trimmed := strings.trim_space(body)
	PREFIX :: `{"data":`
	if !strings.has_prefix(trimmed, PREFIX) || !strings.has_suffix(trimmed, "}") { return }
	data = strings.trim_space(trimmed[len(PREFIX):len(trimmed)-1])
	return data, len(data) > 2 && data[0] == '{' && data[len(data)-1] == '}'
}

// A downloaded map is used only if it parses and is the map SR expects at
// that index: Krunker's map name (lower case, "_" for spaces) is SR's file
// name, or the same name the current file has (Krunker calls Stalk Factory
// just "Factory").
game_files_map_valid :: proc(data: string, index: int, current_name := "") -> bool {
	value, err := json.parse_string(data, parse_integers = true, allocator = context.temp_allocator)
	if err != .None { return false }
	object, ok := value.(json.Object)
	if !ok { return false }
	objects, objects_ok := object["objects"].(json.Array)
	spawns, spawns_ok := object["spawns"].(json.Array)
	name, name_ok := object["name"].(json.String)
	if !objects_ok || !spawns_ok || !name_ok || len(objects) == 0 || len(spawns) == 0 { return false }
	slug, _ := strings.replace_all(strings.to_lower(string(name), context.temp_allocator), " ", "_", context.temp_allocator)
	if index < 0 || index >= len(shared.DEFAULT_MAP_NAMES) { return false }
	return slug == shared.DEFAULT_MAP_NAMES[index] || (len(current_name) > 0 && string(name) == current_name)
}

// The "name" of a map file already on disk ("" if unreadable).
game_files_map_name :: proc(file: string) -> string {
	value, err := json.parse_string(file, parse_integers = true, allocator = context.temp_allocator)
	if err != .None { return "" }
	object, ok := value.(json.Object)
	if !ok { return "" }
	name, _ := object["name"].(json.String)
	return string(name)
}

@(private = "file")
game_files_write_body :: proc "c" (buffer: [^]byte, size, count: c.size_t, output: rawptr) -> c.size_t {
	context = runtime.default_context()
	data := cast(^[dynamic]byte)output
	total := int(size*count)
	if len(data)+total > GAME_FILES_MAX_MAP_BYTES { return 0 }
	append(data, ..buffer[:total])
	return c.size_t(total)
}

@(private = "file")
game_files_update_run :: proc() {
	defer sync.atomic_store(&g_game_files.done, true)
	if curl.global_init(curl.GLOBAL_DEFAULT) != .E_OK { return }
	defer curl.global_cleanup()
	host_images_download() // Host's map images, once: nothing when they exist.
	state := game_files_state_load()
	defer delete(state.modified)
	defer delete(state.version)
	// One request: Krunker's current game version (the "v" its game list carries).
	version := game_files_krunker_version()
	defer delete(version)
	if len(version) > 0 && version == state.version {
		game_files_log(fmt.tprintf("Krunker version %s unchanged; nothing to update", version))
		return
	}
	game_files_log(fmt.tprintf("Krunker version %s (last check: %s); checking maps", len(version) > 0 ? version : "unknown", len(state.version) > 0 ? state.version : "none"))
	checked, replaced, failed := 0, 0, 0
	for name, index in shared.DEFAULT_MAP_NAMES {
		defer free_all(context.temp_allocator)
		handle := curl.easy_init()
		if handle == nil { return }
		body: [dynamic]byte
		defer delete(body)
		url := strings.clone_to_cstring(fmt.tprintf("%s%d", GAME_FILES_MAPS_URL, index), context.temp_allocator)
		curl.easy_setopt(handle, .URL, url)
		curl.easy_setopt(handle, .FOLLOWLOCATION, c.long(1))
		curl.easy_setopt(handle, .CONNECTTIMEOUT_MS, c.long(8000))
		curl.easy_setopt(handle, .TIMEOUT_MS, c.long(30000))
		curl.easy_setopt(handle, .ACCEPT_ENCODING, cstring("")) // gzip: the maps are mostly text
		curl.easy_setopt(handle, .USERAGENT, cstring("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"))
		curl.easy_setopt(handle, .REFERER, cstring("https://krunker.io/"))
		curl.easy_setopt(handle, .FILETIME, c.long(1))
		known, have_known := state.modified[index]
		local_path := fmt.tprintf("%smaps/%s.json", shared.assets_path(), shared.map_asset_name(name))
		if have_known && os.exists(local_path) {
			curl.easy_setopt(handle, .TIMECONDITION, c.long(curl.TIMECOND_IFMODSINCE))
			curl.easy_setopt(handle, .TIMEVALUE, c.long(known))
		}
		curl.easy_setopt(handle, .WRITEFUNCTION, curl.write_callback(game_files_write_body))
		curl.easy_setopt(handle, .WRITEDATA, rawptr(&body))
		code := curl.easy_perform(handle)
		status, unmet, filetime: c.long
		curl.easy_getinfo(handle, .RESPONSE_CODE, &status)
		curl.easy_getinfo(handle, .CONDITION_UNMET, &unmet)
		curl.easy_getinfo(handle, .FILETIME, &filetime)
		curl.easy_cleanup(handle)
		if code != .E_OK { failed += 1; continue }
		checked += 1
		if status == 304 || unmet != 0 { continue } // Unchanged since the last check.
		if status != 200 { failed += 1; continue }
		current, read_err := os.read_entire_file_from_path(local_path, context.temp_allocator)
		current_name := read_err == nil ? game_files_map_name(string(current)) : ""
		data, ok := game_files_map_data(string(body[:]))
		if !ok || !game_files_map_valid(data, index, current_name) {
			game_files_log(fmt.tprintf("map %d (%s): the download was not a valid map; the current file is kept", index, name))
			failed += 1
			continue
		}
		if read_err != nil || strings.trim_space(string(current)) != data {
			temporary := fmt.tprintf("%s.download", local_path)
			if os.write_entire_file(temporary, transmute([]byte)data) != nil { failed += 1; continue }
			if os.rename(temporary, local_path) != nil {
				_ = os.remove(temporary)
				game_files_log(fmt.tprintf("map %d (%s): could not replace the map file (in use?); retried next start", index, name))
				failed += 1
				continue
			}
			replaced += 1
			sync.atomic_add(&g_game_files.updated, 1)
			game_files_log(fmt.tprintf("map %d (%s): updated to Krunker's current version", index, name))
		}
		if filetime > 0 { state.modified[index] = i64(filetime) }
	}
	// A run that reached the map service counts as a check; a failed one is
	// retried on the next start.
	if checked > 0 && failed == 0 {
		state.checked = time.time_to_unix(time.now())
		if len(version) > 0 { delete(state.version); state.version = strings.clone(version) }
	}
	sync.atomic_store(&g_game_files.failed, failed)
	game_files_state_save(state)
	game_files_log(fmt.tprintf("check done: %d maps checked, %d updated, %d failed", checked, replaced, failed))
}

// Krunker's current game version ("" when the game list can't be read).
game_files_krunker_version :: proc() -> string {
	handle := curl.easy_init()
	if handle == nil { return "" }
	body: [dynamic]byte
	defer delete(body)
	curl.easy_setopt(handle, .URL, cstring(GAME_FILES_LIST_URL))
	curl.easy_setopt(handle, .CONNECTTIMEOUT_MS, c.long(8000))
	curl.easy_setopt(handle, .TIMEOUT_MS, c.long(15000))
	curl.easy_setopt(handle, .ACCEPT_ENCODING, cstring(""))
	curl.easy_setopt(handle, .USERAGENT, cstring("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"))
	curl.easy_setopt(handle, .REFERER, cstring("https://krunker.io/"))
	curl.easy_setopt(handle, .WRITEFUNCTION, curl.write_callback(game_files_write_body))
	curl.easy_setopt(handle, .WRITEDATA, rawptr(&body))
	code := curl.easy_perform(handle)
	status: c.long
	curl.easy_getinfo(handle, .RESPONSE_CODE, &status)
	curl.easy_cleanup(handle)
	if code != .E_OK || status != 200 { return "" }
	value, err := json.parse_string(string(body[:]), parse_integers = true, allocator = context.temp_allocator)
	if err != .None { return "" }
	version := krunker_ws_game_version(value)
	if version == "1.0.0" { delete(version); return "" } // the fallback: no version found
	return version
}

// Every frame until the start-up check has been reported; then returns at once.
game_files_update_tick :: proc(client: ^Client) {
	if g_game_files.reported { return }
	if g_game_files.thread == nil { g_game_files.reported = true; return }
	if !sync.atomic_load(&g_game_files.done) {
		if len(client.join_status) == 0 { krunker_ws_set_status(client, "Checking for Krunker updates...") }
		return
	}
	g_game_files.reported = true
	updated := sync.atomic_load(&g_game_files.updated)
	switch {
	case updated > 0: krunker_ws_set_status(client, fmt.tprintf("Krunker updated %d map(s); SR Client updated them. They're used from the next start.", updated))
	case sync.atomic_load(&g_game_files.failed) > 0: krunker_ws_set_status(client, "Couldn't check every Krunker map; SR Client will try again next start.")
	case: krunker_ws_set_status(client, "Game files are up to date.")
	}
}

// Join and Host wait for the start-up check (a few seconds at most).
game_files_checking :: proc() -> bool {
	return g_game_files.thread != nil && !sync.atomic_load(&g_game_files.done)
}

