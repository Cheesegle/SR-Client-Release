#+build windows

package main

import "base:runtime"
import "core:fmt"
import "core:sync"
import win "core:sys/windows"
import "core:thread"
import glfw "vendor:glfw"
import shared "../shared"

// Windows raw mouse input has two paths.
//
// Preferred: a dedicated input thread (Raw_Input_Thread, below) owns a
// message-only window that is the process's raw-mouse target. High-rate mice
// (2-8 kHz) send thousands of WM_INPUT messages per second. When those went to
// the game window, Windows delivered them in bursts and the main thread's
// glfw.PollEvents stalled for 20-80 ms. On the input thread they only cost that
// thread time, and the main thread reads one atomic delta per frame.
//
// Fallback (Native_Mouse subclass): GLFW registers raw motion for the game
// window and we subclass its window procedure to drain queued reports in
// batches. Used only if the thread, its window or its registration fails.
//
// Both paths decode reports with the same native_mouse_accumulate /
// native_mouse_consume_buffer code, so sensitivity is identical. GLFW keeps
// cursor capture, keyboard, buttons and scrolling on both paths.
Native_Mouse :: struct {
	window: glfw.WindowHandle,
	hwnd: win.HWND,
	previous_proc: win.WNDPROC,
	active, buffer_failed: bool,
	x, y: i64,
	absolute: [8]struct { device: win.HANDLE, valid: bool, x, y: i64 },
	buffer: [8192]u64, // 64 KiB, aligned for native RAWINPUT records.
}

g_native_mouse: Native_Mouse

native_mouse_reset :: proc(mouse: ^Native_Mouse) {
	mouse.x, mouse.y = 0, 0
	for &device in mouse.absolute { device.valid = false }
}

native_mouse_sync :: proc(mouse: ^Native_Mouse) {
	active := mouse.window != nil &&
		glfw.GetWindowAttrib(mouse.window, glfw.FOCUSED) != 0 &&
		glfw.GetInputMode(mouse.window, glfw.CURSOR) == glfw.CURSOR_DISABLED &&
		glfw.GetInputMode(mouse.window, glfw.RAW_MOUSE_MOTION) != 0
	if active != mouse.active {
		native_mouse_reset(mouse)
		mouse.active = active
	}
}

native_mouse_accumulate :: proc(mouse: ^Native_Mouse, input: ^win.RAWINPUT) {
	if input.header.dwType != win.RIM_TYPEMOUSE { return }
	report := &input.data.mouse
	input_probe_event()
	if report.usFlags & win.MOUSE_MOVE_ABSOLUTE == 0 {
		mouse.x += i64(report.lLastX)
		mouse.y += i64(report.lLastY)
		return
	}
	// Tablets / remote desktops can report normalized absolute coordinates.
	// Track each device separately and establish a baseline without a camera jump.
	width, height := win.GetSystemMetrics(win.SM_CXSCREEN), win.GetSystemMetrics(win.SM_CYSCREEN)
	if report.usFlags & win.MOUSE_VIRTUAL_DESKTOP != 0 {
		width, height = win.GetSystemMetrics(win.SM_CXVIRTUALSCREEN), win.GetSystemMetrics(win.SM_CYVIRTUALSCREEN)
	}
	x := i64(report.lLastX) * i64(width) / 65535
	y := i64(report.lLastY) * i64(height) / 65535
	slot := &mouse.absolute[0]
	for &device in mouse.absolute {
		if device.valid && device.device == input.header.hDevice { slot = &device; break }
		if !device.valid { slot = &device }
	}
	if slot.valid && slot.device == input.header.hDevice {
		mouse.x += x - slot.x
		mouse.y += y - slot.y
	}
	slot^ = {device = input.header.hDevice, valid = true, x = x, y = y}
}

native_mouse_consume_buffer :: proc(mouse: ^Native_Mouse, data: []u8, count: u32) -> bool {
	offset := 0
	for _ in 0..<count {
		if len(data) - offset < size_of(win.RAWINPUTHEADER) { return false }
		input := cast(^win.RAWINPUT)&data[offset]
		size := int(input.header.dwSize)
		if size < size_of(win.RAWINPUTHEADER) || size > len(data) - offset { return false }
		if input.header.dwType == win.RIM_TYPEMOUSE {
			if size < size_of(win.RAWINPUT) { return false }
			native_mouse_accumulate(mouse, input)
		}
		// NEXTRAWINPUTBLOCK aligns to a native pointer on Windows.
		offset += (size + size_of(uintptr) - 1) & ~int(size_of(uintptr) - 1)
	}
	return true
}

native_mouse_drain :: proc(mouse: ^Native_Mouse) {
	if mouse.buffer_failed { return }
	// Bound each batch; new reports are handled by the normal event pump.
	for _ in 0..<4 {
		size := u32(size_of(mouse.buffer))
		count := win.GetRawInputBuffer(cast(^win.RAWINPUT)&mouse.buffer[0], &size, size_of(win.RAWINPUTHEADER))
		if count == 0 { break }
		if count == max(u32) { mouse.buffer_failed = true; break }
		data := (cast([^]u8)&mouse.buffer[0])[:size_of(mouse.buffer)]
		if !native_mouse_consume_buffer(mouse, data, count) { mouse.buffer_failed = true; break }
	}
}

native_mouse_window_proc :: proc "system" (hwnd: win.HWND, message: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) -> win.LRESULT {
	context = runtime.default_context()
	mouse := &g_native_mouse
	if message == win.WM_INPUT {
		native_mouse_sync(mouse)
		if mouse.active {
			// The WM_INPUT already removed by PeekMessage is not returned by
			// GetRawInputBuffer. Read it exactly once, then drain the queued rest.
			input: win.RAWINPUT
			size := u32(size_of(input))
			read := win.GetRawInputData(win.HRAWINPUT(lparam), win.RID_INPUT, &input, &size, size_of(win.RAWINPUTHEADER))
			if read != max(u32) && read >= size_of(win.RAWINPUT) && input.header.dwType == win.RIM_TYPEMOUSE {
				native_mouse_accumulate(mouse, &input)
				native_mouse_drain(mouse)
				// Required cleanup for the foreground WM_INPUT handle.
				return win.DefWindowProcW(hwnd, message, wparam, lparam)
			}
		}
	}
	if message == win.WM_KILLFOCUS || message == win.WM_SETFOCUS {
		native_mouse_reset(mouse)
		mouse.active = false
	}
	mouse_capture_drop(hwnd, message, wparam)
	return win.CallWindowProcW(mouse.previous_proc, hwnd, message, wparam, lparam)
}

// Fallback path: wrap GLFW's window procedure. Needs GLFW raw motion enabled.
native_mouse_subclass_init :: proc(window: glfw.WindowHandle) -> bool {
	if g_native_mouse.previous_proc != nil { return g_native_mouse.window == window }
	if !bool(glfw.RawMouseMotionSupported()) || size_of(uintptr) != 8 { return false }
	glfw.SetInputMode(window, glfw.RAW_MOUSE_MOTION, 1)
	mouse := &g_native_mouse
	mouse.window = window
	mouse.hwnd = glfw.GetWin32Window(window)
	previous := win.SetWindowLongPtrW(mouse.hwnd, win.GWLP_WNDPROC, transmute(win.LONG_PTR)win.WNDPROC(native_mouse_window_proc))
	if previous == 0 { mouse^ = {}; return false }
	mouse.previous_proc = transmute(win.WNDPROC)previous
	return true
}

native_mouse_subclass_fini :: proc() {
	mouse := &g_native_mouse
	if mouse.previous_proc != nil {
		win.SetWindowLongPtrW(mouse.hwnd, win.GWLP_WNDPROC, transmute(win.LONG_PTR)mouse.previous_proc)
	}
	mouse^ = {}
}

native_mouse_take_delta :: proc(mouse: ^Native_Mouse) -> shared.Vec2 {
	delta := shared.Vec2{f32(mouse.x), f32(mouse.y)}
	mouse.x, mouse.y = 0, 0
	return delta
}

// ---------------------------------------------------------------------------
// Dedicated raw input thread.
//
// A process has one raw-input target window per device usage, so this path
// must never let GLFW register its own. GLFW only registers when
// RAW_MOUSE_MOTION is enabled while the cursor is disabled, so client_mouse_init
// leaves RAW_MOUSE_MOTION off when the thread starts. GLFW still captures the
// cursor with CURSOR_DISABLED.
//
// Without raw motion, GLFW's disabled cursor follows WM_MOUSEMOVE and recentres
// the cursor with SetCursorPos on every poll after it moved. Under 8 kHz input
// SetCursorPos waits behind the system input queue: the harness measured
// 10 ms average / 40-50 ms max per poll from that alone. While the game has the
// mouse captured, raw_input_game_window_proc therefore hides WM_MOUSEMOVE from
// GLFW, so its cursor never "moves" and is never recentred. That is the same
// state GLFW was in on the old path, where raw motion made it ignore
// WM_MOUSEMOVE and our subclass consumed its WM_INPUT. The cursor stays hidden
// and clipped to the window by GLFW; menus (cursor not disabled) are unaffected.

Raw_Input_Thread :: struct {
	handle: ^thread.Thread,
	window: glfw.WindowHandle, // game window, used by the main thread only
	hwnd: win.HWND,            // message-only window, owned by the input thread
	game_hwnd: win.HWND,
	game_previous_proc: win.WNDPROC, // GLFW's window procedure, if we wrapped it
	started: sync.Sema,        // posted once setup has succeeded or failed
	ok: bool,                  // setup result, written before `started` is posted
	failed_step: string,
	// Shared, atomic. The main thread publishes `active` (game window focused,
	// cursor captured); the input thread adds motion to dx/dy only while it is set.
	active: bool,
	dx, dy: i64,
	// Owned by the input thread.
	seen_active: bool,
	mouse: Native_Mouse,
}

g_raw_input_thread: Raw_Input_Thread

RAW_INPUT_THREAD_CLASS :: "SR ClientRawMouseInput"

// Input thread: notice changes of the active flag. Each transition drops
// absolute baselines, so a tablet or remote cursor never jumps after alt-tab
// or a menu.
raw_input_thread_sync :: proc(t: ^Raw_Input_Thread) -> bool {
	active := sync.atomic_load(&t.active)
	if active != t.seen_active {
		native_mouse_reset(&t.mouse)
		t.seen_active = active
	}
	return active
}

// Input thread: hand decoded motion to the main thread, or drop it while the
// game is not capturing the mouse.
raw_input_thread_publish :: proc(t: ^Raw_Input_Thread, active: bool) {
	if active {
		if t.mouse.x != 0 { sync.atomic_add(&t.dx, t.mouse.x) }
		if t.mouse.y != 0 { sync.atomic_add(&t.dy, t.mouse.y) }
		t.mouse.x, t.mouse.y = 0, 0
	} else {
		native_mouse_reset(&t.mouse)
	}
}

// Main thread: publish whether motion counts. Motion accumulated around a
// transition is discarded, so focus or capture changes never leak a delta.
raw_input_thread_set_active :: proc(t: ^Raw_Input_Thread, active: bool) {
	if active == sync.atomic_load(&t.active) { return }
	sync.atomic_store(&t.active, active)
	sync.atomic_exchange(&t.dx, 0)
	sync.atomic_exchange(&t.dy, 0)
}

// Main thread: take everything accumulated since the last call. x and y are
// exchanged separately; a report landing in between is not lost, only split
// across two frames.
raw_input_thread_take_delta :: proc(t: ^Raw_Input_Thread) -> shared.Vec2 {
	x := sync.atomic_exchange(&t.dx, 0)
	y := sync.atomic_exchange(&t.dy, 0)
	return {f32(x), f32(y)}
}

raw_input_thread_wanted :: proc(window: glfw.WindowHandle) -> bool {
	// A fullscreen window is iconified while alt-tabbed and can report focus
	// while it is being restored; it is only "playing" once it is shown again.
	return window != nil &&
		glfw.GetWindowAttrib(window, glfw.FOCUSED) != 0 &&
		glfw.GetWindowAttrib(window, glfw.ICONIFIED) == 0 &&
		glfw.GetInputMode(window, glfw.CURSOR) == glfw.CURSOR_DISABLED
}

// Main thread: the game window's procedure while the input thread runs. Only
// WM_MOUSEMOVE during capture is withheld (see the comment above); everything
// else, including buttons, wheel and keys, goes to GLFW unchanged.
raw_input_game_window_proc :: proc "system" (hwnd: win.HWND, message: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) -> win.LRESULT {
	context = runtime.default_context()
	t := &g_raw_input_thread
	if message == win.WM_MOUSEMOVE && raw_input_thread_wanted(t.window) { return 0 }
	mouse_capture_drop(hwnd, message, wparam)
	return win.CallWindowProcW(t.game_previous_proc, hwnd, message, wparam, lparam)
}

raw_input_thread_window_proc :: proc "system" (hwnd: win.HWND, message: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) -> win.LRESULT {
	context = runtime.default_context()
	t := &g_raw_input_thread
	switch message {
	case win.WM_INPUT:
		active := raw_input_thread_sync(t)
		// Read the report that triggered this message, then drain the queued
		// rest in 64 KiB batches. Inactive reports are read too, then dropped,
		// so the queue never backs up.
		input: win.RAWINPUT
		size := u32(size_of(input))
		read := win.GetRawInputData(win.HRAWINPUT(lparam), win.RID_INPUT, &input, &size, size_of(win.RAWINPUTHEADER))
		if read != max(u32) && read >= size_of(win.RAWINPUT) && input.header.dwType == win.RIM_TYPEMOUSE {
			native_mouse_accumulate(&t.mouse, &input)
		}
		native_mouse_drain(&t.mouse)
		raw_input_thread_publish(t, active)
		// Required cleanup for the WM_INPUT handle.
		return win.DefWindowProcW(hwnd, message, wparam, lparam)
	case win.WM_CLOSE:
		device := win.RAWINPUTDEVICE{usUsagePage = 1, usUsage = 2, dwFlags = win.RIDEV_REMOVE}
		win.RegisterRawInputDevices(&device, 1, size_of(device))
		win.DestroyWindow(hwnd)
		return 0
	case win.WM_DESTROY:
		win.PostQuitMessage(0)
		return 0
	}
	return win.DefWindowProcW(hwnd, message, wparam, lparam)
}

raw_input_thread_main :: proc(data: rawptr) {
	cpu_pin_current_thread_off_game_core()
	t := (^Raw_Input_Thread)(data)
	instance := win.HINSTANCE(win.GetModuleHandleW(nil))
	class := win.WNDCLASSEXW{
		cbSize = size_of(win.WNDCLASSEXW),
		lpfnWndProc = raw_input_thread_window_proc,
		hInstance = instance,
		lpszClassName = win.L(RAW_INPUT_THREAD_CLASS),
	}
	if win.RegisterClassExW(&class) == 0 {
		t.failed_step = "RegisterClassExW"
		sync.sema_post(&t.started)
		return
	}
	defer win.UnregisterClassW(win.L(RAW_INPUT_THREAD_CLASS), instance)
	// A message-only window is invisible, never focused, and only receives
	// what is sent to it: here, raw input routed by RIDEV_INPUTSINK.
	t.hwnd = win.CreateWindowExW(0, win.L(RAW_INPUT_THREAD_CLASS), nil, 0, 0, 0, 0, 0, win.HWND_MESSAGE, nil, instance, nil)
	if t.hwnd == nil {
		t.failed_step = "CreateWindowExW"
		sync.sema_post(&t.started)
		return
	}
	// INPUTSINK delivers reports although this window is never in the
	// foreground; the main thread's `active` flag decides whether they count.
	device := win.RAWINPUTDEVICE{usUsagePage = 1, usUsage = 2, dwFlags = win.RIDEV_INPUTSINK, hwndTarget = t.hwnd}
	if !win.RegisterRawInputDevices(&device, 1, size_of(device)) {
		win.DestroyWindow(t.hwnd)
		t.failed_step = "RegisterRawInputDevices"
		sync.sema_post(&t.started)
		return
	}
	t.ok = true
	sync.sema_post(&t.started)
	msg: win.MSG
	for win.GetMessageW(&msg, nil, 0, 0) > 0 {
		win.DispatchMessageW(&msg)
	}
}

raw_input_thread_start :: proc(window: glfw.WindowHandle) -> (ok: bool, failed_step: string) {
	t := &g_raw_input_thread
	if t.handle != nil { return t.window == window, "already started for another window" }
	if size_of(uintptr) != 8 { return false, "32-bit build" }
	t^ = {}
	t.window = window
	t.handle = thread.create_and_start_with_data(t, raw_input_thread_main, priority = .High, name = "raw mouse input")
	if t.handle == nil { return false, "thread creation" }
	sync.sema_wait(&t.started)
	if !t.ok {
		failed_step = t.failed_step
		thread.join(t.handle)
		thread.destroy(t.handle)
		t^ = {}
		return false, failed_step
	}
	// If wrapping fails, raw input still works; GLFW just keeps recentring.
	t.game_hwnd = glfw.GetWin32Window(window)
	previous := win.SetWindowLongPtrW(t.game_hwnd, win.GWLP_WNDPROC, transmute(win.LONG_PTR)win.WNDPROC(raw_input_game_window_proc))
	if previous != 0 {
		t.game_previous_proc = transmute(win.WNDPROC)previous
	} else {
		fmt.eprintln("[Input] Could not wrap the game window procedure; cursor recentring stays on")
	}
	return true, ""
}

raw_input_thread_stop :: proc() {
	t := &g_raw_input_thread
	if t.handle == nil { return }
	if t.game_previous_proc != nil {
		win.SetWindowLongPtrW(t.game_hwnd, win.GWLP_WNDPROC, transmute(win.LONG_PTR)t.game_previous_proc)
	}
	// WM_CLOSE unregisters raw input and destroys the window on its own
	// thread; WM_DESTROY then ends the GetMessageW loop.
	if !win.PostMessageW(t.hwnd, win.WM_CLOSE, 0, 0) {
		win.PostThreadMessageW(t.handle.win32_thread_id, win.WM_QUIT, 0, 0)
	}
	thread.join(t.handle)
	thread.destroy(t.handle)
	t^ = {}
}

// ---------------------------------------------------------------------------
// Client entry points.

// Returns true when native raw mouse input is in use. On the thread path
// GLFW's RAW_MOUSE_MOTION stays off (see above); the fallback enables it.
client_mouse_init :: proc(window: glfw.WindowHandle) -> bool {
	ok, failed_step := raw_input_thread_start(window)
	if ok { return true }
	fmt.eprintfln("[Input] Raw mouse input thread unavailable (%s); using the window-procedure path", failed_step)
	return native_mouse_subclass_init(window)
}

client_mouse_fini :: proc() {
	mouse_capture_release()
	raw_input_thread_stop()
	native_mouse_subclass_fini()
}

// Hold mouse capture (SetCapture) on the game window while playing.
//
// Without capture, Windows hit-tests the window for every mouse report and
// sends it WM_NCHITTEST, WM_SETCURSOR and WM_MOUSEMOVE. At 2-8 kHz polling
// these arrive in bursts of 1000+ messages and stalled event polling for
// 20-140 ms (measured: 96.6 ms worst poll, 1086 messages, 362 of each type).
// With capture held, the same burst is ~2 messages and the worst poll ~2 ms.
// Holding a mouse button already did this, because GLFW captures on button
// down. Capture is taken only while the window is focused with the cursor
// disabled, and released in menus; Windows itself drops it on alt-tab, and it
// is re-taken on the next poll if the game is still being played.
g_mouse_capture_held: bool

Mouse_Capture_Action :: enum u8 { NONE, TAKE, RELEASE }

// playing: focused with the cursor disabled. has: the window holds capture.
// held: we took it. button_down: GLFW holds it for a pressed button.
mouse_capture_decide :: proc(playing, has, held, button_down: bool) -> (action: Mouse_Capture_Action, held_after: bool) {
	if playing { return has ? .NONE : .TAKE, true }
	if !held { return .NONE, false }
	// Leave capture alone while GLFW itself holds it for a pressed button.
	return has && !button_down ? .RELEASE : .NONE, false
}

mouse_button_down :: proc(window: glfw.WindowHandle) -> bool {
	for button in i32(glfw.MOUSE_BUTTON_1) ..= i32(glfw.MOUSE_BUTTON_LAST) {
		if glfw.GetMouseButton(window, button) == glfw.PRESS { return true }
	}
	return false
}

mouse_capture_update :: proc(window: glfw.WindowHandle, playing: Maybe(bool) = nil) {
	if window == nil { return }
	hwnd := glfw.GetWin32Window(window)
	is_playing := playing.? or_else raw_input_thread_wanted(window)
	action, held := mouse_capture_decide(is_playing, win.GetCapture() == hwnd, g_mouse_capture_held, mouse_button_down(window))
	g_mouse_capture_held = held
	switch action {
	case .TAKE: win.SetCapture(hwnd)
	case .RELEASE: win.ReleaseCapture()
	case .NONE:
	}
}

// Messages after which the window must not keep mouse capture: losing focus or
// activation, or being minimised (a fullscreen window is minimised on
// alt-tab). Releasing here, inside the window procedure, means capture is gone
// before Windows routes the next click (the taskbar, alt-tab back); waiting
// for the next poll left a minimised fullscreen window holding capture, so it
// could not be restored.
mouse_capture_should_drop :: proc(message: win.UINT, wparam: win.WPARAM) -> bool {
	switch message {
	case win.WM_KILLFOCUS: return true
	case win.WM_ACTIVATEAPP: return wparam == 0
	case win.WM_ACTIVATE: return win.LOWORD(win.DWORD(wparam)) == win.WA_INACTIVE
	case win.WM_SIZE: return wparam == win.SIZE_MINIMIZED
	}
	return false
}

mouse_capture_drop :: proc(hwnd: win.HWND, message: win.UINT, wparam: win.WPARAM) {
	if !g_mouse_capture_held || !mouse_capture_should_drop(message, wparam) { return }
	g_mouse_capture_held = false
	if win.GetCapture() == hwnd { win.ReleaseCapture() }
}

mouse_capture_release :: proc() {
	w := g_raw_input_thread.window
	if w == nil { w = g_native_mouse.window }
	if w != nil { mouse_capture_update(w, false) }
	g_mouse_capture_held = false
}

client_mouse_delta :: proc(fallback: shared.Vec2) -> shared.Vec2 {
	if t := &g_raw_input_thread; t.handle != nil {
		active := raw_input_thread_wanted(t.window)
		raw_input_thread_set_active(t, active)
		if !active { return fallback }
		delta := raw_input_thread_take_delta(t)
		if delta != {} { gpu_probe_note_input(input_probe_take()) }
		return delta
	}
	mouse := &g_native_mouse
	if mouse.previous_proc == nil { return fallback }
	native_mouse_sync(mouse)
	if !mouse.active { return fallback }
	delta := native_mouse_take_delta(mouse)
	if delta != {} { gpu_probe_note_input(input_probe_take()) }
	return delta
}

client_poll_events :: proc() {
	if t := &g_raw_input_thread; t.handle != nil {
		glfw.PollEvents()
		// Publish focus and capture changes as soon as GLFW has processed them.
		raw_input_thread_set_active(t, raw_input_thread_wanted(t.window))
		mouse_capture_update(t.window)
		return
	}
	mouse := &g_native_mouse
	if mouse.previous_proc != nil {
		native_mouse_sync(mouse)
		if mouse.active { native_mouse_drain(mouse) }
	}
	glfw.PollEvents()
	mouse_capture_update(mouse.window)
}

// Idle-frame wait: sleeps on a high-resolution timer (glfwWaitEventsTimeout
// rounds to whole milliseconds) until the timeout or a window message, then
// processes messages. The input thread keeps reading on its own. On the
// fallback path raw WM_INPUT still reaches native_mouse_window_proc while
// GLFW dispatches messages, so buffered mouse motion is not lost.
client_wait_events :: proc(timeout: f64) {
	client_wait_for_message(timeout)
	client_poll_events()
}
