package main

import "base:runtime"
import "core:fmt"
import "core:sync"
import win "core:sys/windows"
import "core:thread"
import "core:time"

// Top-level crash handler and hang watchdog (Windows).
//
// An unhandled exception on any thread writes logs/crash.log (exception,
// faulting module+offset, stack return addresses, recent phases, GL info) and
// a small minidump, logs/crash.dmp, then lets Windows terminate the process as
// before. A watchdog thread writes logs/hang.log and logs/hang.dmp, once per
// stall, when the main loop has not finished a frame for HANG_SECONDS; the
// report names the phase and the main thread's instruction pointer (for
// example inside the GPU driver).

foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention = "system")
foreign kernel32 {
	GetModuleHandleExW :: proc(dwFlags: win.DWORD, lpModuleName: rawptr, phModule: ^win.HMODULE) -> win.BOOL ---
}

GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT :: 0x2
GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS :: 0x4
CONTEXT_AMD64_CONTROL :: 0x00100001

HANG_SECONDS :: 6

@(private = "file")
Aligned_Context :: struct #align (16) {
	ctx: win.CONTEXT,
}

@(private = "file")
Crash_State :: struct {
	installed:      bool,
	handling:       i32,
	main_thread:    win.HANDLE,
	watchdog:       ^thread.Thread,
	watchdog_stop:  bool,
	module_paths:   [32][260]u8,
	stack:          [48]uintptr,
	stack_modules:  [48]string,
	stack_bases:    [48]uintptr,
	context_buffer: Aligned_Context,
}

@(private = "file")
g_crash: Crash_State

crash_exception_name :: proc(code: u32) -> string {
	switch code {
	case 0xC0000005: return "EXCEPTION_ACCESS_VIOLATION"
	case 0xC000001D: return "EXCEPTION_ILLEGAL_INSTRUCTION (Odin bounds check or assertion trap)"
	case 0x80000003: return "EXCEPTION_BREAKPOINT"
	case 0xC0000094: return "EXCEPTION_INT_DIVIDE_BY_ZERO"
	case 0xC00000FD: return "EXCEPTION_STACK_OVERFLOW"
	case 0xC0000409: return "STATUS_STACK_BUFFER_OVERRUN (fail fast)"
	case 0xC0000374: return "STATUS_HEAP_CORRUPTION"
	case 0xC0000006: return "EXCEPTION_IN_PAGE_ERROR"
	case 0xC000008E: return "EXCEPTION_FLT_DIVIDE_BY_ZERO"
	case 0xC0000017: return "STATUS_NO_MEMORY"
	case 0xE06D7363: return "C++ exception (likely from a driver or system DLL)"
	}
	return "unknown exception"
}

// Module (path, base) containing `address`, written into `path_buffer`.
crash_module_of :: proc(address: uintptr, path_buffer: ^[260]u8) -> (path: string, base: uintptr) {
	module: win.HMODULE
	if address == 0 || !bool(GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT, rawptr(address), &module)) {
		return "", 0
	}
	wide: [260]u16
	length := win.GetModuleFileNameW(module, &wide[0], len(wide))
	if length == 0 { return "", uintptr(module) }
	bytes := win.WideCharToMultiByte(win.CP_UTF8, 0, cstring16(&wide[0]), i32(length), &path_buffer[0], len(path_buffer), nil, nil)
	return string(path_buffer[:max(bytes, 0)]), uintptr(module)
}

crash_file_write :: proc(path: string, data: []u8) -> bool {
	win.CreateDirectoryW(win.L(DIAGNOSTICS_LOG_DIR), nil)
	wide: [520]u16
	length := win.MultiByteToWideChar(win.CP_UTF8, 0, raw_data(path), i32(len(path)), &wide[0], len(wide) - 1)
	if length <= 0 { return false }
	wide[length] = 0
	file := win.CreateFileW(cstring16(&wide[0]), win.GENERIC_WRITE, win.FILE_SHARE_READ, nil, win.CREATE_ALWAYS, win.FILE_ATTRIBUTE_NORMAL, nil)
	if file == win.INVALID_HANDLE_VALUE { return false }
	defer win.CloseHandle(file)
	written: win.DWORD
	ok := bool(win.WriteFile(file, raw_data(data), win.DWORD(len(data)), &written, nil))
	win.FlushFileBuffers(file)
	return ok && int(written) == len(data)
}

@(private = "file")
crash_write_dump :: proc(path: win.wstring, exception: ^win.EXCEPTION_POINTERS, thread_id: win.DWORD) {
	file := win.CreateFileW(path, win.GENERIC_WRITE, 0, nil, win.CREATE_ALWAYS, win.FILE_ATTRIBUTE_NORMAL, nil)
	if file == win.INVALID_HANDLE_VALUE { return }
	defer win.CloseHandle(file)
	info := win.MINIDUMP_EXCEPTION_INFORMATION{ThreadId = thread_id, ExceptionPointers = exception, ClientPointers = false}
	dump_type := win.MINIDUMP_TYPE(u32(win.MINIDUMP_TYPE.WithThreadInfo) | u32(win.MINIDUMP_TYPE.WithIndirectlyReferencedMemory) | u32(win.MINIDUMP_TYPE.WithUnloadedModules))
	win.MiniDumpWriteDump(win.GetCurrentProcess(), win.GetCurrentProcessId(), file, dump_type, exception != nil ? &info : nil, nil, nil)
}

@(private = "file")
crash_filter :: proc "system" (pointers: ^win.EXCEPTION_POINTERS) -> win.LONG {
	// A second fault while reporting the first must not recurse.
	if sync.atomic_add(&g_crash.handling, 1) != 0 { return win.EXCEPTION_CONTINUE_SEARCH }
	context = runtime.default_context()
	record := pointers.ExceptionRecord
	info := Crash_Info{title = "crash report (unhandled exception)", code = u32(record.ExceptionCode), address = uintptr(record.ExceptionAddress)}
	info.code_name = crash_exception_name(info.code)
	info.module_path, info.module_base = crash_module_of(info.address, &g_crash.module_paths[0])
	if info.code == 0xC0000005 && record.NumberParameters >= 2 {
		switch uintptr(record.ExceptionInformation[0]) {
		case 0: info.access = "read"
		case 1: info.access = "write"
		case 8: info.access = "execute"
		case: info.access = "access"
		}
		info.access_address = uintptr(record.ExceptionInformation[1])
	}
	// The filter runs on the faulting thread above the exception dispatcher,
	// so the walk continues into the frames that faulted.
	frames := int(win.RtlCaptureStackBackTrace(0, len(g_crash.stack), cast([^]rawptr)&g_crash.stack[0], nil))
	module_slots := len(g_crash.module_paths) - 1
	for i in 0 ..< frames {
		if i < module_slots {
			g_crash.stack_modules[i], g_crash.stack_bases[i] = crash_module_of(g_crash.stack[i], &g_crash.module_paths[i + 1])
		}
	}
	info.stack = g_crash.stack[:frames]
	info.stack_modules = g_crash.stack_modules[:min(frames, module_slots)]
	info.stack_bases = g_crash.stack_bases[:min(frames, module_slots)]
	info.detail = "Please send logs/crash.log (and logs/crash.dmp, plus logs/gl-debug.log or logs/gpu-debug.log if you ran with --gpu-debug)."
	written := crash_log_write(CRASH_LOG_PATH, info)
	crash_write_dump(win.L(CRASH_DUMP_PATH), pointers, win.GetCurrentThreadId())
	if written { fmt.eprintln("\n[Crash] Report written to", CRASH_LOG_PATH) }
	return win.EXCEPTION_CONTINUE_SEARCH
}

@(private = "file")
crash_watchdog :: proc(t: ^thread.Thread) {
	cpu_pin_current_thread_off_game_core()
	last_frame := sync.atomic_load_explicit(&g_diag.frame, .Acquire)
	last_change := time.tick_now()
	reported := false
	for !sync.atomic_load(&g_crash.watchdog_stop) {
		time.sleep(500 * time.Millisecond)
		frame := sync.atomic_load_explicit(&g_diag.frame, .Acquire)
		if frame != last_frame {
			if reported { fmt.eprintln("[Hang] Main loop resumed") }
			last_frame, last_change, reported = frame, time.tick_now(), false
			continue
		}
		if reported || frame == 0 || time.duration_seconds(time.tick_since(last_change)) < HANG_SECONDS { continue }
		reported = true
		crash_write_hang_report()
	}
}

@(private = "file")
crash_write_hang_report :: proc() {
	info := Crash_Info{title = "hang report (main loop stopped for 6 seconds)"}
	if g_crash.main_thread != nil && win.SuspendThread(g_crash.main_thread) != ~win.DWORD(0) {
		g_crash.context_buffer.ctx = {}
		g_crash.context_buffer.ctx.ContextFlags = CONTEXT_AMD64_CONTROL
		if win.GetThreadContext(g_crash.main_thread, &g_crash.context_buffer.ctx) {
			info.address = uintptr(g_crash.context_buffer.ctx.Rip)
		}
		win.ResumeThread(g_crash.main_thread)
		info.module_path, info.module_base = crash_module_of(info.address, &g_crash.module_paths[0])
	}
	if info.address != 0 { info.detail = "Address is the main thread's instruction pointer. Dragging or resizing the window also pauses the loop (phase: poll events)." }
	crash_log_write(HANG_LOG_PATH, info)
	crash_write_dump(win.L(HANG_DUMP_PATH), nil, 0)
	fmt.eprintln("[Hang] Main loop has not finished a frame for", HANG_SECONDS, "seconds; wrote", HANG_LOG_PATH)
}

// Installs the unhandled-exception filter and the hang watchdog. Call from the
// main thread. Reports include the GL strings once diagnostics_capture_gpu_info
// has run; the watchdog ignores the time before the first frame.
crash_handler_install :: proc() {
	if g_crash.installed { return }
	g_crash.installed = true
	win.SetUnhandledExceptionFilter(crash_filter)
	process := win.GetCurrentProcess()
	win.DuplicateHandle(process, win.GetCurrentThread(), process, &g_crash.main_thread, 0, false, win.DUPLICATE_SAME_ACCESS)
	g_crash.watchdog = thread.create(crash_watchdog)
	if g_crash.watchdog != nil { thread.start(g_crash.watchdog) }
}

crash_handler_uninstall :: proc() {
	if !g_crash.installed { return }
	sync.atomic_store(&g_crash.watchdog_stop, true)
	if g_crash.watchdog != nil {
		thread.join(g_crash.watchdog)
		thread.destroy(g_crash.watchdog)
		g_crash.watchdog = nil
	}
	win.SetUnhandledExceptionFilter(nil)
	if g_crash.main_thread != nil { win.CloseHandle(g_crash.main_thread); g_crash.main_thread = nil }
	g_crash.installed = false
	g_crash.watchdog_stop = false
}
