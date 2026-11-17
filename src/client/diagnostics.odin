package main

import "base:runtime"
import "core:fmt"
import "core:hash"
import "core:os"
import "core:strings"
import "core:sync"
import gl "vendor:OpenGL"

// Tester diagnostics: cheap, always-on breadcrumbs plus optional GL debug output.
//
// - phase_mark records what the main loop is doing in a small ring. Crash and
//   hang reports (logs/crash.log, logs/hang.log) print the last few entries.
// - `--gl-debug` creates a debug context and logs every distinct
//   KHR_debug message to logs/gl-debug.log, once each, with a repeat count.
// - Without it, gl_check polls glGetError once per frame (per phase after the
//   first error) and logs the first error of each site to logs/gl-errors.log.
// Nothing here allocates per frame; the cost without errors is a ring write
// per phase and one glGetError call per frame.

SR_VERSION :: #load("../../VERSION", string)

DIAGNOSTICS_LOG_DIR :: "logs"
GL_DEBUG_LOG_PATH :: "logs/gl-debug.log"
GL_ERROR_LOG_PATH :: "logs/gl-errors.log"
CRASH_LOG_PATH :: "logs/crash.log"
CRASH_DUMP_PATH :: "logs/crash.dmp"
HANG_LOG_PATH :: "logs/hang.log"
HANG_DUMP_PATH :: "logs/hang.dmp"

// Phases are small integers rather than strings, so the hang watchdog thread
// can read the ring without ever seeing a torn (pointer, length) pair.
Phase :: enum u8 {
	NONE,
	STARTUP,
	MAP_LOAD,
	BATCH_BUILD,
	BATCH_SELF_TEST,
	TICK,
	RENDER_WORLD,
	RENDER_SCENE,
	RENDER_VIEWMODEL,
	PREVIEW_GRAPHICS,
	HUD,
	MENU_VIEW,
	MONITOR_CACHE_REFRESH,
	MENU_BUILD,
	SETTINGS_TAB_MAIN,
	SETTINGS_TAB_INPUT,
	SETTINGS_TAB_VIDEO,
	SETTINGS_TAB_VISUALS,
	SETTINGS_TAB_GAMEPLAY,
	SETTINGS_TAB_AUDIO,
	SETTINGS_TAB_HUD,
	SETTINGS_SEARCH,
	MENU_RENDER,
	MENU_ACTION,
	APPLY_SETTINGS,
	APPLY_DISPLAY,
	DEBUG_WINDOW,
	SWAP_BUFFERS,
	POLL_EVENTS,
	IDLE_WAIT,
	SHUTDOWN,
}

PHASE_NAMES := [Phase]string{
	.NONE                  = "none",
	.STARTUP               = "startup",
	.MAP_LOAD              = "load map",
	.BATCH_BUILD           = "build map batches",
	.BATCH_SELF_TEST       = "batching self-test",
	.TICK                  = "tick",
	.RENDER_WORLD          = "render world",
	.RENDER_SCENE          = "render scene",
	.RENDER_VIEWMODEL      = "render view model",
	.PREVIEW_GRAPHICS      = "preview visuals/quality",
	.HUD                   = "hud",
	.MENU_VIEW             = "menu: build view",
	.MONITOR_CACHE_REFRESH = "menu: refresh monitor modes",
	.MENU_BUILD            = "menu: layout",
	.SETTINGS_TAB_MAIN     = "settings: build General tab",
	.SETTINGS_TAB_INPUT    = "settings: build Controls tab",
	.SETTINGS_TAB_VIDEO    = "settings: build Display tab",
	.SETTINGS_TAB_VISUALS  = "settings: build Render tab",
	.SETTINGS_TAB_GAMEPLAY = "settings: build Game tab",
	.SETTINGS_TAB_AUDIO    = "settings: build Sound tab",
	.SETTINGS_TAB_HUD      = "settings: build Experimental tab",
	.SETTINGS_SEARCH       = "settings: build search results",
	.MENU_RENDER           = "menu: draw",
	.MENU_ACTION           = "menu: apply action",
	.APPLY_SETTINGS        = "settings: save",
	.APPLY_DISPLAY         = "apply display mode",
	.DEBUG_WINDOW          = "debug window",
	.SWAP_BUFFERS          = "swap buffers",
	.POLL_EVENTS           = "poll events",
	.IDLE_WAIT             = "idle frame wait",
	.SHUTDOWN              = "shutdown",
}

PHASE_RING_SIZE :: 32

Phase_Entry :: struct {
	frame: u32,
	phase: Phase,
}

Diagnostics :: struct {
	frame:      u32, // Main-loop frame counter; the hang watchdog watches it.
	phase_head: u32,
	phases:     [PHASE_RING_SIZE]Phase_Entry,
	// Copied once at startup so the crash handler never calls into GL.
	gl_vendor, gl_renderer, gl_version: [128]u8,
	gl_vendor_len, gl_renderer_len, gl_version_len: int,
	gl_debug_context: bool, // The context reports CONTEXT_FLAG_DEBUG_BIT.
	gl_debug_output: bool,  // The KHR_debug callback is installed.
	gl_debug_log: ^os.File,
	gl_error_log: ^os.File,
	gl_debug_lines: int,
	// Message counts by type, for tests and the shutdown summary.
	gl_errors, gl_warnings, gl_other: int,
	gl_seen: [512]GL_Message_Seen,
	gl_seen_count: int,
	// The most recent distinct GL message, quoted in crash reports.
	gl_last_message: [512]u8,
	gl_last_message_len: int,
	// glGetError polling: first error of each call site.
	gl_error_sites: [64]string,
	gl_error_site_count: int,
	gl_check_errors: int,
	gl_check_detailed: bool, // Per-phase checks, on after the first error.
}

GL_Message_Seen :: struct {
	key:   u64,
	count: u32,
}

// Cap on lines written to gl-debug.log, so a driver that reports something
// every draw call cannot fill the disk.
GL_DEBUG_MAX_LINES :: 4000

g_diag: Diagnostics

phase_mark :: #force_inline proc "contextless" (phase: Phase) {
	head := g_diag.phase_head
	g_diag.phases[head % PHASE_RING_SIZE] = {g_diag.frame, phase}
	sync.atomic_store_explicit(&g_diag.phase_head, head + 1, .Release)
}

phase_frame_begin :: #force_inline proc "contextless" () {
	sync.atomic_store_explicit(&g_diag.frame, g_diag.frame + 1, .Release)
}

phase_current :: proc "contextless" () -> Phase {
	head := sync.atomic_load_explicit(&g_diag.phase_head, .Acquire)
	if head == 0 { return .NONE }
	return g_diag.phases[(head - 1) % PHASE_RING_SIZE].phase
}

settings_tab_phase :: proc "contextless" (tab: int) -> Phase {
	phases := [?]Phase{.SETTINGS_TAB_MAIN, .SETTINGS_TAB_INPUT, .SETTINGS_TAB_VIDEO, .SETTINGS_TAB_VISUALS, .SETTINGS_TAB_GAMEPLAY, .SETTINGS_TAB_AUDIO, .SETTINGS_TAB_HUD}
	return tab >= 0 && tab < len(phases) ? phases[tab] : .MENU_BUILD
}

diagnostics_make_log_dir :: proc() {
	if !os.exists(DIAGNOSTICS_LOG_DIR) { os.make_directory(DIAGNOSTICS_LOG_DIR) }
}

// Records the GL strings for crash reports. Call once after the context exists.
diagnostics_capture_gl_info :: proc() {
	copy_gl_string :: proc(name: u32, dst: ^[128]u8, length: ^int) {
		value := cstring(gl.GetString(name))
		length^ = value == nil ? 0 : copy(dst[:], string(value))
	}
	copy_gl_string(gl.VENDOR, &g_diag.gl_vendor, &g_diag.gl_vendor_len)
	copy_gl_string(gl.RENDERER, &g_diag.gl_renderer, &g_diag.gl_renderer_len)
	copy_gl_string(gl.VERSION, &g_diag.gl_version, &g_diag.gl_version_len)
	flags: i32
	gl.GetIntegerv(gl.CONTEXT_FLAGS, &flags)
	g_diag.gl_debug_context = flags & gl.CONTEXT_FLAG_DEBUG_BIT != 0
}

diagnostics_gl_renderer :: proc() -> string {
	return string(g_diag.gl_renderer[:g_diag.gl_renderer_len])
}

// --- KHR_debug ---------------------------------------------------------------

gl_debug_source_name :: proc(source: u32) -> string {
	switch source {
	case gl.DEBUG_SOURCE_API: return "API"
	case gl.DEBUG_SOURCE_WINDOW_SYSTEM: return "WINDOW_SYSTEM"
	case gl.DEBUG_SOURCE_SHADER_COMPILER: return "SHADER_COMPILER"
	case gl.DEBUG_SOURCE_THIRD_PARTY: return "THIRD_PARTY"
	case gl.DEBUG_SOURCE_APPLICATION: return "APPLICATION"
	}
	return "OTHER"
}

gl_debug_type_name :: proc(type: u32) -> string {
	switch type {
	case gl.DEBUG_TYPE_ERROR: return "ERROR"
	case gl.DEBUG_TYPE_DEPRECATED_BEHAVIOR: return "DEPRECATED"
	case gl.DEBUG_TYPE_UNDEFINED_BEHAVIOR: return "UNDEFINED_BEHAVIOR"
	case gl.DEBUG_TYPE_PORTABILITY: return "PORTABILITY"
	case gl.DEBUG_TYPE_PERFORMANCE: return "PERFORMANCE"
	case gl.DEBUG_TYPE_MARKER: return "MARKER"
	case gl.DEBUG_TYPE_PUSH_GROUP: return "PUSH_GROUP"
	case gl.DEBUG_TYPE_POP_GROUP: return "POP_GROUP"
	}
	return "OTHER"
}

gl_debug_severity_name :: proc(severity: u32) -> string {
	switch severity {
	case gl.DEBUG_SEVERITY_HIGH: return "HIGH"
	case gl.DEBUG_SEVERITY_MEDIUM: return "MEDIUM"
	case gl.DEBUG_SEVERITY_LOW: return "LOW"
	}
	return "NOTIFICATION"
}

// Counts and logs one debug message. Identical messages (same source, type,
// id, severity and text) are written once; the shutdown summary gives counts.
// Repeats are also noted at 10, 100, 1000... so per-frame spam is visible
// even if the process never shuts down cleanly. Returns true when the message
// was new.
gl_debug_record :: proc(source, type, id, severity: u32, message: string) -> bool {
	switch {
	case type == gl.DEBUG_TYPE_ERROR: g_diag.gl_errors += 1
	case type == gl.DEBUG_TYPE_UNDEFINED_BEHAVIOR || type == gl.DEBUG_TYPE_PORTABILITY || type == gl.DEBUG_TYPE_DEPRECATED_BEHAVIOR ||
	     type == gl.DEBUG_TYPE_PERFORMANCE && severity != gl.DEBUG_SEVERITY_NOTIFICATION:
		g_diag.gl_warnings += 1
	case: g_diag.gl_other += 1
	}
	header := [4]u32{source, type, id, severity}
	key := hash.fnv64a(transmute([]u8)message, hash.fnv64a(([^]u8)(&header[0])[:size_of(header)]))
	seen: ^GL_Message_Seen
	for &entry in g_diag.gl_seen[:g_diag.gl_seen_count] {
		if entry.key == key { seen = &entry; break }
	}
	is_new := seen == nil
	count: u32 = 1
	if seen != nil {
		seen.count += 1
		count = seen.count
	} else if g_diag.gl_seen_count < len(g_diag.gl_seen) {
		g_diag.gl_seen[g_diag.gl_seen_count] = {key, 1}
		g_diag.gl_seen_count += 1
	}
	if is_new && severity != gl.DEBUG_SEVERITY_NOTIFICATION {
		g_diag.gl_last_message_len = copy(g_diag.gl_last_message[:], message)
	}
	repeat_milestone := !is_new && (count == 10 || count == 100 || count == 1000 || count == 10000 || count == 100000)
	// Notifications (NVIDIA reports where every buffer lives) are only counted.
	loggable := severity != gl.DEBUG_SEVERITY_NOTIFICATION
	if loggable && (is_new || repeat_milestone) && g_diag.gl_debug_log != nil && g_diag.gl_debug_lines < GL_DEBUG_MAX_LINES {
		buffer: [2048]u8
		line: string
		if is_new {
			line = fmt.bprintf(buffer[:], "[frame %d, %s] %s %s %s id=%d: %s\n", g_diag.frame, PHASE_NAMES[phase_current()],
				gl_debug_severity_name(severity), gl_debug_type_name(type), gl_debug_source_name(source), id, strings.trim_space(message))
		} else {
			line = fmt.bprintf(buffer[:], "[frame %d, %s] repeated %d times: %s %s id=%d\n", g_diag.frame, PHASE_NAMES[phase_current()],
				count, gl_debug_type_name(type), gl_debug_source_name(source), id)
		}
		os.write_string(g_diag.gl_debug_log, line)
		g_diag.gl_debug_lines += 1
		if g_diag.gl_debug_lines == GL_DEBUG_MAX_LINES {
			os.write_string(g_diag.gl_debug_log, "Log limit reached; further messages are only counted.\n")
		}
	}
	return is_new
}

gl_debug_callback :: proc "c" (source, type, id, severity: u32, length: i32, message: cstring, user: rawptr) {
	context = runtime.default_context()
	text := length >= 0 ? string(([^]u8)(message)[:length]) : string(message)
	gl_debug_record(source, type, id, severity, text)
}

// Installs the KHR_debug logger (OpenGL 4.3+ core). Synchronous output makes
// the callback run inside the offending GL call, so the logged phase is the
// one that issued it. Returns false when the context has no debug output.
gl_debug_install :: proc(log_path := GL_DEBUG_LOG_PATH) -> bool {
	if gl.DebugMessageCallback == nil { return false }
	if len(log_path) > 0 {
		diagnostics_make_log_dir()
		file, err := os.open(log_path, {.Write, .Create, .Trunc})
		if err == nil {
			g_diag.gl_debug_log = file
			fmt.fprintf(file, "SR Client GL debug log\nGL_VENDOR: %s\nGL_RENDERER: %s\nGL_VERSION: %s\nDebug context: %v\n\n",
				string(g_diag.gl_vendor[:g_diag.gl_vendor_len]), diagnostics_gl_renderer(), string(g_diag.gl_version[:g_diag.gl_version_len]), g_diag.gl_debug_context)
		}
	}
	gl.Enable(gl.DEBUG_OUTPUT)
	gl.Enable(gl.DEBUG_OUTPUT_SYNCHRONOUS)
	gl.DebugMessageControl(gl.DONT_CARE, gl.DONT_CARE, gl.DONT_CARE, 0, nil, true)
	gl.DebugMessageCallback(gl_debug_callback, nil)
	g_diag.gl_debug_output = true
	return true
}

gl_debug_shutdown :: proc() {
	if g_diag.gl_debug_output && gl.DebugMessageCallback != nil {
		gl.DebugMessageCallback(nil, nil)
		gl.Disable(gl.DEBUG_OUTPUT)
	}
	g_diag.gl_debug_output = false
	if g_diag.gl_debug_log != nil {
		fmt.fprintf(g_diag.gl_debug_log, "\nSummary after %d frames: %d errors, %d warnings, %d other messages, %d distinct.\n",
			g_diag.frame, g_diag.gl_errors, g_diag.gl_warnings, g_diag.gl_other, g_diag.gl_seen_count)
		os.close(g_diag.gl_debug_log)
		g_diag.gl_debug_log = nil
	}
	if g_diag.gl_error_log != nil {
		os.close(g_diag.gl_error_log)
		g_diag.gl_error_log = nil
	}
}

gl_debug_reset_counts :: proc() {
	g_diag.gl_errors, g_diag.gl_warnings, g_diag.gl_other = 0, 0, 0
	g_diag.gl_seen_count = 0
	g_diag.gl_error_site_count, g_diag.gl_check_errors, g_diag.gl_check_detailed = 0, 0, false
	g_diag.gl_last_message_len = 0
}

// --- glGetError polling ------------------------------------------------------

gl_error_name :: proc(error: u32) -> string {
	switch error {
	case gl.INVALID_ENUM: return "GL_INVALID_ENUM"
	case gl.INVALID_VALUE: return "GL_INVALID_VALUE"
	case gl.INVALID_OPERATION: return "GL_INVALID_OPERATION"
	case gl.STACK_OVERFLOW: return "GL_STACK_OVERFLOW"
	case gl.STACK_UNDERFLOW: return "GL_STACK_UNDERFLOW"
	case gl.OUT_OF_MEMORY: return "GL_OUT_OF_MEMORY"
	case gl.INVALID_FRAMEBUFFER_OPERATION: return "GL_INVALID_FRAMEBUFFER_OPERATION"
	case 0x0507: return "GL_CONTEXT_LOST"
	}
	return "unknown GL error"
}

// Polls glGetError when the debug callback is off. The main loop checks once
// per frame; per-phase checks (`per_phase`) start only after the first error,
// to name the phase that raised it. glGetError does not wait for the GPU, but
// threaded drivers may sync with their worker thread, so it stays rare. The
// first error of each site is logged with its phase; later ones are counted.
gl_check :: proc(site: string, per_phase := false) -> bool {
	if g_diag.gl_debug_output || per_phase && !g_diag.gl_check_detailed { return true }
	clean := true
	for _ in 0 ..< 8 {
		error := gl.GetError()
		if error == gl.NO_ERROR { break }
		clean = false
		g_diag.gl_check_errors += 1
		g_diag.gl_check_detailed = true
		known := false
		for logged in g_diag.gl_error_sites[:g_diag.gl_error_site_count] {
			if logged == site { known = true; break }
		}
		if known || g_diag.gl_error_site_count >= len(g_diag.gl_error_sites) { continue }
		g_diag.gl_error_sites[g_diag.gl_error_site_count] = site
		g_diag.gl_error_site_count += 1
		buffer: [512]u8
		line := fmt.bprintf(buffer[:], "[frame %d, %s] %s (0x%04X) after %s\n", g_diag.frame, PHASE_NAMES[phase_current()], gl_error_name(error), error, site)
		g_diag.gl_last_message_len = copy(g_diag.gl_last_message[:], line)
		if g_diag.gl_error_log == nil {
			diagnostics_make_log_dir()
			file, err := os.open(GL_ERROR_LOG_PATH, {.Write, .Create, .Trunc})
			if err == nil {
				g_diag.gl_error_log = file
				fmt.fprintf(file, "GL_RENDERER: %s\nGL_VERSION: %s\n", diagnostics_gl_renderer(), string(g_diag.gl_version[:g_diag.gl_version_len]))
			}
		}
		if g_diag.gl_error_log != nil { os.write_string(g_diag.gl_error_log, line) }
		fmt.eprint("[GL] ", line)
	}
	return clean
}

// --- Crash and hang reports --------------------------------------------------

Crash_Info :: struct {
	title:          string, // "Unhandled exception" or "Main loop not responding".
	code:           u32,
	code_name:      string,
	address:        uintptr,
	module_path:    string,
	module_base:    uintptr,
	access:         string, // "read", "write" or "execute" for access violations.
	access_address: uintptr,
	detail:         string,
	stack:          []uintptr, // Return addresses, innermost first (optional).
	stack_modules:  []string,  // Module path per stack entry (optional).
	stack_bases:    []uintptr,
}

// The crash report, formatted into `buffer` without heap allocation.
crash_report_format :: proc(buffer: []u8, info: Crash_Info) -> string {
	b := strings.builder_from_bytes(buffer)
	fmt.sbprintf(&b, "SR Client %s\n", info.title)
	fmt.sbprintf(&b, "Build: %s%s\n", SR_VERSION, SR_DEV ? " (dev)" : "")
	fmt.sbprintf(&b, "GL_VENDOR: %s\nGL_RENDERER: %s\nGL_VERSION: %s\n", string(g_diag.gl_vendor[:g_diag.gl_vendor_len]), diagnostics_gl_renderer(), string(g_diag.gl_version[:g_diag.gl_version_len]))
	fmt.sbprintf(&b, "GL debug output: %v\n\n", g_diag.gl_debug_output)
	if info.code != 0 { fmt.sbprintf(&b, "Exception: 0x%08X %s\n", info.code, info.code_name) }
	if info.address != 0 {
		if len(info.module_path) > 0 {
			fmt.sbprintf(&b, "Address: 0x%X = %s+0x%X\n", info.address, info.module_path, info.address - info.module_base)
		} else {
			fmt.sbprintf(&b, "Address: 0x%X (no module)\n", info.address)
		}
	}
	if len(info.access) > 0 { fmt.sbprintf(&b, "Access violation: %s of address 0x%X\n", info.access, info.access_address) }
	if len(info.detail) > 0 { fmt.sbprintf(&b, "%s\n", info.detail) }
	if len(info.stack) > 0 {
		fmt.sbprintf(&b, "\nStack (innermost first):\n")
		for address, i in info.stack {
			if i < len(info.stack_modules) && len(info.stack_modules[i]) > 0 {
				fmt.sbprintf(&b, "  0x%X = %s+0x%X\n", address, info.stack_modules[i], address - info.stack_bases[i])
			} else {
				fmt.sbprintf(&b, "  0x%X\n", address)
			}
		}
	}
	fmt.sbprintf(&b, "\nFrame: %d\nLast phases (oldest first):\n", g_diag.frame)
	head := sync.atomic_load_explicit(&g_diag.phase_head, .Acquire)
	start := head > PHASE_RING_SIZE ? head - PHASE_RING_SIZE : 0
	for i in start ..< head {
		entry := g_diag.phases[i % PHASE_RING_SIZE]
		fmt.sbprintf(&b, "  frame %d: %s\n", entry.frame, PHASE_NAMES[entry.phase])
	}
	if g_diag.gl_last_message_len > 0 {
		fmt.sbprintf(&b, "\nLast new GL message: %s\n", strings.trim_space(string(g_diag.gl_last_message[:g_diag.gl_last_message_len])))
	}
	fmt.sbprintf(&b, "GL messages so far: %d errors, %d warnings; glGetError reported %d\n", g_diag.gl_errors, g_diag.gl_warnings, g_diag.gl_check_errors)
	return strings.to_string(b)
}

// Static so the crash path never needs the heap, which may be the thing that broke.
@(private = "file")
g_crash_buffer: [16384]u8

// Writes a crash/hang report to `path` (truncating) and flushes it to disk.
crash_log_write :: proc(path: string, info: Crash_Info) -> bool {
	report := crash_report_format(g_crash_buffer[:], info)
	return crash_file_write(path, transmute([]u8)report)
}
