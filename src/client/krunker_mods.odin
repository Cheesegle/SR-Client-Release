package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import access "../browser_access"
import shared "../shared"
import kproto "../krunker"
import menuui "../menu"
import curl "vendor:curl"

// Krunker mods: "Browse mods" opens Krunker's own Mods window in the browser
// helper (sr_browser.exe). When the player presses Load Mod there, the helper
// reports the mod's zip link and closes; SR Client downloads and unpacks the
// zip in the background, then swaps the files live (mod_reload.odin), in the
// menu or in a match, without a restart.

KRUNKER_MOD_MAX_BYTES :: 256 * 1024 * 1024
KRUNKER_MOD_REQUEST_BASE :: u64(1) << 48 // Separate ids from login/captcha requests.

Download_Job :: struct {
	url:  string,
	data: [dynamic]byte,
	limit: int,
	ok:   bool,
	// Optional work on the download thread after a successful download (the
	// mod unpack); `finished` is true when it worked, `reason` says why not.
	finish:   proc(job: ^Download_Job) -> string,
	finished: bool,
	reason:   string,
	status:   int, // HTTP status of the download
	// A file the browser helper already saved (the exact zip Krunker loaded):
	// read from disk instead of downloading.
	local_path: string,
	keep_local: bool, // the player's own file: read it, never delete it
	finish_directory, finish_link: string,
	done: bool, // set last, atomically, by the download thread
	thread: ^thread.Thread,
}

Krunker_Mods_Browser :: struct {
	open:     bool,
	request:  u64,
	child:    access.Child,
	buffer:   [dynamic]byte,
	link:     string,
	download: ^Download_Job,
}

g_krunker_mods: Krunker_Mods_Browser

download_start :: proc(url: string, limit: int, finish: proc(job: ^Download_Job) -> string = nil, directory := "", link := "", local_path := "", keep_local := false) -> ^Download_Job {
	job := new(Download_Job)
	job.url, job.limit = strings.clone(url), limit
	job.local_path, job.keep_local = strings.clone(local_path), keep_local
	job.finish, job.finish_directory, job.finish_link = finish, strings.clone(directory), strings.clone(link)
	job.thread = thread.create_and_start_with_poly_data(job, download_run)
	if job.thread == nil { delete(job.url); delete(job.finish_directory); delete(job.finish_link); delete(job.local_path); free(job); return nil }
	return job
}

// Finished: true once the thread is done; the caller then owns job.data and
// must call download_free.
download_finished :: proc(job: ^Download_Job) -> bool {
	if job == nil || !sync.atomic_load(&job.done) { return false }
	if job.thread != nil { thread.join(job.thread); thread.destroy(job.thread); job.thread = nil }
	return true
}

download_free :: proc(job: ^Download_Job) {
	if job == nil { return }
	if job.thread != nil { thread.join(job.thread); thread.destroy(job.thread) }
	delete(job.data)
	delete(job.url)
	delete(job.finish_directory)
	delete(job.finish_link)
	delete(job.reason)
	delete(job.local_path)
	free(job)
}

@(private = "file")
download_write :: proc "c" (buffer: [^]byte, size, count: c.size_t, output: rawptr) -> c.size_t {
	context = runtime.default_context()
	total := int(size * count)
	job := cast(^Download_Job)output
	if job == nil || total <= 0 { return 0 }
	if len(job.data)+total > job.limit { return 0 } // Aborts oversized downloads.
	append(&job.data, ..buffer[:total])
	return c.size_t(total)
}

@(private = "file")
download_run :: proc(job: ^Download_Job) {
	cpu_pin_current_thread_off_game_core() // never on the game thread's core
	defer sync.atomic_store(&job.done, true)
	if len(job.local_path) > 0 {
		data, err := os.read_entire_file_from_path(job.local_path, context.allocator)
		if err == nil && len(data) <= job.limit { append(&job.data, ..data) }
		delete(data)
		if !job.keep_local { _ = os.remove(job.local_path) }
		job.ok = len(job.data) > 0
		download_finish(job)
		return
	}
	if curl.global_init(curl.GLOBAL_DEFAULT) != .E_OK { return }
	defer curl.global_cleanup()
	handle := curl.easy_init()
	if handle == nil { return }
	defer curl.easy_cleanup(handle)
	url := strings.clone_to_cstring(job.url)
	defer delete(url)
	curl.easy_setopt(handle, .URL, url)
	curl.easy_setopt(handle, .FOLLOWLOCATION, c.long(1))
	curl.easy_setopt(handle, .CONNECTTIMEOUT_MS, c.long(10000))
	curl.easy_setopt(handle, .TIMEOUT_MS, c.long(180000))
	// Look like the browser that loaded the mod, so hosts answer with the same file.
	curl.easy_setopt(handle, .USERAGENT, cstring("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36 Edg/131.0.0.0"))
	curl.easy_setopt(handle, .REFERER, cstring("https://krunker.io/"))
	curl.easy_setopt(handle, .ACCEPT_ENCODING, cstring("")) // decode gzip/br bodies
	headers: ^curl.slist
	headers = curl.slist_append(headers, "Origin: https://krunker.io")
	defer curl.slist_free_all(headers)
	curl.easy_setopt(handle, .HTTPHEADER, headers)
	curl.easy_setopt(handle, .WRITEFUNCTION, curl.write_callback(download_write))
	curl.easy_setopt(handle, .WRITEDATA, rawptr(job))
	code := curl.easy_perform(handle)
	status: c.long
	curl.easy_getinfo(handle, .RESPONSE_CODE, &status)
	job.status = int(status)
	job.ok = code == .E_OK && status >= 200 && status < 300 && len(job.data) > 0
	download_finish(job)
}

@(private = "file")
download_finish :: proc(job: ^Download_Job) {
	if !job.ok || job.finish == nil { return }
	reason := job.finish(job)
	job.finished = len(reason) == 0
	job.reason = strings.clone(reason)
	free_all(context.temp_allocator)
}

@(private = "file")
krunker_mod_prepare :: proc(job: ^Download_Job) -> string {
	return shared.mods_prepare(job.finish_directory, job.data[:], job.finish_link)
}

// Dropbox share links ("?dl=0") open a web page; "?dl=1" is the file itself.
krunker_mod_download_link :: proc(link: string) -> string {
	if !strings.contains(link, "dropbox.com/") { return link }
	if strings.contains(link, "dl=0") { out, _ := strings.replace_all(link, "dl=0", "dl=1", context.temp_allocator); return out }
	if !strings.contains(link, "dl=1") && !strings.contains(link, "raw=1") { return fmt.tprintf("%s%sdl=1", link, strings.contains(link, "?") ? "&" : "?") }
	return link
}

// A short label for Settings: the last path part of the mod link.
krunker_mod_label :: proc(link: string) -> string {
	if len(link) == 0 { return "" }
	path, _ := strings.replace_all(link, "\\", "/", context.temp_allocator) // a Windows file path
	if query := strings.index_byte(path, '?'); query >= 0 { path = path[:query] }
	path = strings.trim_right(path, "/")
	if slash := strings.last_index_byte(path, '/'); slash >= 0 && slash+1 < len(path) {
		name := path[slash+1:]
		if strings.has_suffix(strings.to_lower(name, context.temp_allocator), ".zip") && slash > 0 {
			// ".../<mod id>/mod.zip" style links: show the folder too.
			parent := path[:slash]
			if p := strings.last_index_byte(parent, '/'); p >= 0 { return fmt.tprintf("%s/%s", parent[p+1:], name) }
		}
		return name
	}
	return path
}

client_mods_browse :: proc(client: ^Client) {
	when ODIN_OS == .Windows {
		mods := &g_krunker_mods
		if mods.open || mods.download != nil { return }
		mods.request += 1
		if !access.start(&mods.child, KRUNKER_MOD_REQUEST_BASE+mods.request, false, "MODS", "") {
			client_mods_message(client, "Could not open Krunker's mods window. Reinstall SR Client if this repeats.", true)
			return
		}
		mods.open = true
		client_mods_message(client, "Krunker's Mods window opened. Press Load Mod on the mod you want.", false)
	} else {
		client_mods_message(client, "Krunker mods need the Windows version of SR Client.", true)
	}
}

// Settings > General > Mods > Paste link: a mod link (Dropbox, Krunker's
// user assets, any direct zip) or the path of a .zip on this PC.
client_mods_paste :: proc(client: ^Client, text: string) {
	mods := &g_krunker_mods
	if mods.download != nil { return }
	value := strings.trim(text, "\"' \t\r\n")
	if len(value) == 0 || len(value) > 4096 {
		client_mods_message(client, "Copy a mod link or the path of a mod .zip first, then press Paste link.", true)
		return
	}
	directory := len(shared.g_mods.directory) > 0 ? shared.g_mods.directory : shared.mods_directory(context.temp_allocator)
	lower := strings.to_lower(value, context.temp_allocator)
	delete(mods.link)
	mods.link = strings.clone(value)
	if strings.has_prefix(lower, "https://") || strings.has_prefix(lower, "http://") {
		mods.download = download_start(krunker_mod_download_link(value), KRUNKER_MOD_MAX_BYTES, krunker_mod_prepare, directory, value)
	} else if os.exists(value) {
		mods.download = download_start("", KRUNKER_MOD_MAX_BYTES, krunker_mod_prepare, directory, value, value, keep_local = true)
	} else {
		client_mods_message(client, "That is not a link or a file on this PC. Copy the mod's link or the path of its .zip.", true)
		return
	}
	if mods.download == nil { client_mods_message(client, "Could not start loading the mod.", true); return }
	client_mods_message(client, fmt.tprintf("Loading mod %s...", krunker_mod_label(value)), false)
}

client_mods_remove :: proc(client: ^Client) {
	if g_krunker_mods.download != nil { return }
	snapshot := mod_snapshot_take(client)
	defer mod_snapshot_free(&snapshot)
	shared.mods_remove()
	shared.mods_init()
	mod_snapshot_apply(client, &snapshot)
	client_mods_message(client, "Mod removed. The default files are back.", false)
}

client_mods_message :: proc(client: ^Client, text: string, is_error: bool) {
	menuui.settings_set_message(&client.menu, text, is_error)
}

// Runs every frame; cheap when idle.
client_mods_tick :: proc(client: ^Client) {
	mods := &g_krunker_mods
	when ODIN_OS == .Windows {
		if mods.open {
			message, ready, alive := access.receive(mods.child.output, &mods.buffer)
			if ready {
				defer { delete(message.kind); delete(message.value) }
				switch message.kind {
				case "MOD_URL":
					// The link of the mod whose bytes follow in MOD_FILE.
					delete(mods.link)
					mods.link = strings.clone(message.value)
				case "MOD_FILE", "MOD":
					// MOD_FILE: the helper saved the exact zip Krunker loaded.
					// MOD: only a link was seen; download it here.
					local := message.kind == "MOD_FILE" ? message.value : ""
					if message.kind == "MOD" { delete(mods.link); mods.link = strings.clone(message.value) }
					access.stop(&mods.child, KRUNKER_MOD_REQUEST_BASE+mods.request)
					delete(mods.buffer); mods.buffer = nil
					mods.open = false
					directory := len(shared.g_mods.directory) > 0 ? shared.g_mods.directory : shared.mods_directory(context.temp_allocator)
					link := len(mods.link) > 0 ? mods.link : "Krunker mod"
					mods.download = download_start(krunker_mod_download_link(mods.link), KRUNKER_MOD_MAX_BYTES, krunker_mod_prepare, directory, link, local)
					if mods.download == nil { client_mods_message(client, "Could not start loading the mod.", true) }
					else { client_mods_message(client, fmt.tprintf("Loading mod %s...", krunker_mod_label(link)), false) }
				case "ERROR":
					access.stop(&mods.child, KRUNKER_MOD_REQUEST_BASE+mods.request)
					delete(mods.buffer); mods.buffer = nil
					mods.open = false
					switch message.value {
					case "CANCELLED":
					case "MOD_SAVE_FAILED": client_mods_message(client, "The mod could not be copied from Krunker's window. Try again.", true)
					case: client_mods_message(client, "Krunker's mods window closed with an error.", true)
					}
				}
			} else if !alive {
				access.stop(&mods.child, KRUNKER_MOD_REQUEST_BASE+mods.request)
				delete(mods.buffer); mods.buffer = nil
				mods.open = false
			}
		}
	}
	if mods.download != nil && download_finished(mods.download) {
		job := mods.download
		mods.download = nil
		defer download_free(job)
		if !job.ok {
			kproto.network_log("mods", fmt.tprintf("download failed status=%d bytes=%d url=%s local=%v", job.status, len(job.data), job.url, len(job.local_path) > 0))
			client_mods_message(client, job.status >= 400 ? fmt.tprintf("The mod could not be downloaded (HTTP %d). Try again.", job.status) : "The mod could not be downloaded. Try again.", true)
		} else if !job.finished {
			kproto.network_log("mods", fmt.tprintf("unpack failed: %s url=%s bytes=%d", job.reason, job.url, len(job.data)))
			// Keep what was downloaded, to see what the host sent instead of a zip.
			if local, found := os.lookup_env_alloc("LOCALAPPDATA", context.temp_allocator); found && len(local) > 0 {
				_ = os.write_entire_file(fmt.tprintf("%s/SR-Client/mods-last-download.bin", local), job.data[:])
			}
			mods_reload_live(client) // the old mod files may be gone: fall back cleanly
			client_mods_message(client, fmt.tprintf("The mod could not be loaded: %s.", job.reason), true)
		} else {
			mods_reload_live(client)
			client_mods_message(client, fmt.tprintf("Mod %s loaded.", krunker_mod_label(mods.link)), false)
		}
	}
}
