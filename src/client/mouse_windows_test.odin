#+build windows

package main

import "core:sync"
import "core:testing"
import win "core:sys/windows"
import glfw "vendor:glfw"
import shared "../shared"

when ODIN_TEST {
	g_mouse_test_scroll: f64
	mouse_test_scroll :: proc "c" (window: glfw.WindowHandle, x, y: f64) { g_mouse_test_scroll += y }
	g_mouse_test_cursor: [2]f64
	mouse_test_cursor :: proc "c" (window: glfw.WindowHandle, x, y: f64) { g_mouse_test_cursor = {x, y} }

	@(test)
	buffered_mouse_preserves_high_rate_motion :: proc(t: ^testing.T) {
		mouse := new(Native_Mouse)
		defer free(mouse)
		// A full second of 8 kHz input, including reversals and no-motion
		// button reports, delivered in the same bounded chunks as the OS API.
		expected_x, expected_y: i64
		for batch in 0..<8 {
			for i in 0..<1000 {
				index := batch * 1000 + i
				report := cast(^win.RAWINPUT)&mouse.buffer[i * size_of(win.RAWINPUT) / size_of(u64)]
				report^ = {}
				report.header = {dwType = win.RIM_TYPEMOUSE, dwSize = size_of(win.RAWINPUT)}
				report.data.mouse.lLastX = i32(index % 17 - 8)
				report.data.mouse.lLastY = i32(index % 13 - 6)
				expected_x += i64(report.data.mouse.lLastX)
				expected_y += i64(report.data.mouse.lLastY)
			}
			data := (cast([^]u8)&mouse.buffer[0])[:size_of(mouse.buffer)]
			testing.expect(t, native_mouse_consume_buffer(mouse, data, 1000), "valid 8 kHz input batches must decode")
		}
		testing.expect(t, mouse.x == expected_x && mouse.y == expected_y, "batching must preserve the exact sum without dropping or duplicating reports")
		testing.expect(t, native_mouse_take_delta(mouse) == (shared.Vec2{f32(expected_x), f32(expected_y)}), "a frame must receive the complete raw delta")
		testing.expect(t, native_mouse_take_delta(mouse) == (shared.Vec2{}), "the next frame must not repeat consumed movement")
		// Relative movement remains raw, even at values beyond 32-bit totals.
		large := win.RAWINPUT{header = {dwType = win.RIM_TYPEMOUSE, dwSize = size_of(win.RAWINPUT)}}
		large.data.mouse.lLastX = max(i32)
		native_mouse_accumulate(mouse, &large)
		native_mouse_accumulate(mouse, &large)
		testing.expect(t, mouse.x == i64(max(i32)) * 2, "accumulation must not wrap at 32 bits")
		native_mouse_reset(mouse)
		testing.expect(t, mouse.x == 0 && mouse.y == 0, "focus/capture transitions must discard stale movement")
	}

	@(test)
	buffered_mouse_handles_record_alignment_and_absolute_devices :: proc(t: ^testing.T) {
		mouse := new(Native_Mouse)
		defer free(mouse)
		data := (cast([^]u8)&mouse.buffer[0])[:size_of(mouse.buffer)]
		// Variable-length HID records have padding before the next mouse record.
		hid := cast(^win.RAWINPUTHEADER)&data[0]
		hid^ = {dwType = win.RIM_TYPEHID, dwSize = size_of(win.RAWINPUTHEADER) + 1}
		offset := (int(hid.dwSize) + 7) & ~int(7)
		report := cast(^win.RAWINPUT)&data[offset]
		report.header = {dwType = win.RIM_TYPEMOUSE, dwSize = size_of(win.RAWINPUT)}
		report.data.mouse.lLastX, report.data.mouse.lLastY = 23, -41
		testing.expect(t, native_mouse_consume_buffer(mouse, data[:offset + size_of(win.RAWINPUT)], 2) && mouse.x == 23 && mouse.y == -41,
			"non-mouse records must not corrupt the next aligned mouse record")
		testing.expect(t, !native_mouse_consume_buffer(mouse, data[:offset + size_of(win.RAWINPUT) - 1], 2), "truncated records must be rejected")
		hid.dwSize = 0
		testing.expect(t, !native_mouse_consume_buffer(mouse, data, 1), "zero-size records must not loop or read outside the buffer")
		native_mouse_reset(mouse)
		report.data.mouse.usFlags = win.MOUSE_MOVE_ABSOLUTE | win.MOUSE_VIRTUAL_DESKTOP
		report.data.mouse.lLastX, report.data.mouse.lLastY = 10000, 20000
		native_mouse_accumulate(mouse, report)
		testing.expect(t, mouse.x == 0 && mouse.y == 0, "the first absolute report must establish a baseline without a camera jump")
		report.data.mouse.lLastX, report.data.mouse.lLastY = 11000, 19000
		native_mouse_accumulate(mouse, report)
		testing.expect(t, mouse.x > 0 && mouse.y < 0, "absolute devices must retain directional movement")
		native_mouse_reset(mouse)
		native_mouse_accumulate(mouse, report)
		testing.expect(t, mouse.x == 0 && mouse.y == 0, "returning from focus loss must rebaseline absolute input")
	}

	@(test)
	buffered_mouse_window_lifecycle :: proc(t: ^testing.T) {
		if !testing.expect(t, bool(glfw.Init())) do return
		defer glfw.Terminate()
		glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)
		window := glfw.CreateWindow(160, 120, "Mouse input regression", nil, nil)
		if !testing.expect(t, window != nil) do return
		defer glfw.DestroyWindow(window)
		hwnd := glfw.GetWin32Window(window)
		previous := win.GetWindowLongPtrW(hwnd, win.GWLP_WNDPROC)
		if !testing.expect(t, native_mouse_subclass_init(window), "the Windows input hook must install") do return
		defer native_mouse_subclass_fini()
		testing.expect(t, native_mouse_subclass_init(window), "initialization must be safe to repeat without creating a recursive hook")
		testing.expect(t, win.GetWindowLongPtrW(hwnd, win.GWLP_WNDPROC) != previous, "window procedure must be wrapped")
		fallback := shared.Vec2{12, -3}
		testing.expect(t, client_mouse_delta(fallback) == fallback, "menu/unfocused input must retain GLFW cursor movement")
		win.SendMessageW(hwnd, win.WM_LBUTTONDOWN, 0, 0)
		testing.expect(t, glfw.GetMouseButton(window, glfw.MOUSE_BUTTON_LEFT) == glfw.PRESS, "mouse buttons must still reach GLFW")
		win.SendMessageW(hwnd, win.WM_LBUTTONUP, 0, 0)
		testing.expect(t, glfw.GetMouseButton(window, glfw.MOUSE_BUTTON_LEFT) == glfw.RELEASE, "mouse button releases must still reach GLFW")
		g_mouse_test_scroll = 0
		glfw.SetScrollCallback(window, mouse_test_scroll)
		win.SendMessageW(hwnd, win.WM_MOUSEWHEEL, 120 << 16, 0)
		testing.expect(t, g_mouse_test_scroll == 1, "scroll wheel input must still reach GLFW")
		win.SendMessageW(hwnd, win.WM_KEYDOWN, 'W', 0x00110000)
		testing.expect(t, glfw.GetKey(window, glfw.KEY_W) == glfw.PRESS, "keyboard input must still reach GLFW")
		win.SendMessageW(hwnd, win.WM_KEYUP, 'W', 0xC0110000)
		testing.expect(t, glfw.GetKey(window, glfw.KEY_W) == glfw.RELEASE, "keyboard releases must still reach GLFW")
		g_native_mouse.x = 100
		win.SendMessageW(hwnd, win.WM_KILLFOCUS, 0, 0)
		testing.expect(t, g_native_mouse.x == 0 && !g_native_mouse.active, "focus loss must clear queued movement")
		client_poll_events()
		native_mouse_subclass_fini()
		testing.expect(t, win.GetWindowLongPtrW(hwnd, win.GWLP_WNDPROC) == previous, "shutdown must restore GLFW's original window procedure")
		testing.expect(t, client_mouse_delta(fallback) == fallback, "fallback must remain usable after shutdown")
	}

	mouse_test_relative_report :: proc(dx, dy: i32) -> win.RAWINPUT {
		report := win.RAWINPUT{header = {dwType = win.RIM_TYPEMOUSE, dwSize = size_of(win.RAWINPUT)}}
		report.data.mouse.lLastX, report.data.mouse.lLastY = dx, dy
		return report
	}

	mouse_test_absolute_report :: proc(device: uintptr, x, y: i32) -> win.RAWINPUT {
		report := win.RAWINPUT{header = {dwType = win.RIM_TYPEMOUSE, dwSize = size_of(win.RAWINPUT), hDevice = win.HANDLE(device)}}
		report.data.mouse.usFlags = win.MOUSE_MOVE_ABSOLUTE
		report.data.mouse.lLastX, report.data.mouse.lLastY = x, y
		return report
	}

	@(test)
	raw_input_thread_matches_window_procedure_sensitivity :: proc(t: ^testing.T) {
		old := new(Native_Mouse)
		defer free(old)
		state := new(Raw_Input_Thread)
		defer free(state)
		raw_input_thread_set_active(state, true)

		// Relative: one second of 8 kHz motion in the GetRawInputBuffer layout,
		// 1000-report batches on both paths. The thread path publishes per
		// WM_INPUT and the main thread takes once per "frame" (every 3 batches);
		// the totals must be identical.
		old_total, new_total: shared.Vec2
		for batch in 0..<8 {
			for i in 0..<1000 {
				index := batch * 1000 + i
				record := mouse_test_relative_report(i32(index % 17 - 8), i32(index % 13 - 6))
				(cast(^win.RAWINPUT)&old.buffer[i * size_of(win.RAWINPUT) / size_of(u64)])^ = record
				(cast(^win.RAWINPUT)&state.mouse.buffer[i * size_of(win.RAWINPUT) / size_of(u64)])^ = record
			}
			old_data := (cast([^]u8)&old.buffer[0])[:size_of(old.buffer)]
			new_data := (cast([^]u8)&state.mouse.buffer[0])[:size_of(state.mouse.buffer)]
			testing.expect(t, native_mouse_consume_buffer(old, old_data, 1000))
			active := raw_input_thread_sync(state)
			testing.expect(t, native_mouse_consume_buffer(&state.mouse, new_data, 1000))
			raw_input_thread_publish(state, active)
			if batch % 3 == 2 { new_total += raw_input_thread_take_delta(state) }
		}
		old_total += native_mouse_take_delta(old)
		new_total += raw_input_thread_take_delta(state)
		testing.expect_value(t, new_total, old_total)
		testing.expect(t, old_total != (shared.Vec2{}), "the reference sequence must produce motion")
		testing.expect_value(t, raw_input_thread_take_delta(state), shared.Vec2{})

		// Single WM_INPUT reports (GetRawInputData path), including totals past 32 bits.
		for dx in ([]i32{max(i32), max(i32), -5, 7}) {
			record := mouse_test_relative_report(dx, -dx / 2)
			native_mouse_accumulate(old, &record)
			native_mouse_accumulate(&state.mouse, &record)
			raw_input_thread_publish(state, raw_input_thread_sync(state))
		}
		testing.expect(t, sync.atomic_load(&state.dx) == old.x && sync.atomic_load(&state.dy) == old.y, "per-message reports must sum identically without 32-bit wrap")
		testing.expect_value(t, raw_input_thread_take_delta(state), native_mouse_take_delta(old))

		// Absolute devices: two interleaved devices with per-device baselines.
		absolute := [?]win.RAWINPUT{
			mouse_test_absolute_report(1, 10000, 20000),
			mouse_test_absolute_report(2, 30000, 30000),
			mouse_test_absolute_report(1, 11000, 19000),
			mouse_test_absolute_report(2, 29000, 32000),
			mouse_test_absolute_report(1, 12500, 18000),
		}
		for &record in absolute {
			native_mouse_accumulate(old, &record)
			native_mouse_accumulate(&state.mouse, &record)
			raw_input_thread_publish(state, raw_input_thread_sync(state))
		}
		old_absolute := native_mouse_take_delta(old)
		testing.expect(t, old_absolute.x > 0, "absolute reference must move")
		testing.expect_value(t, raw_input_thread_take_delta(state), old_absolute)
	}

	@(test)
	raw_input_thread_drops_inactive_motion :: proc(t: ^testing.T) {
		state := new(Raw_Input_Thread)
		defer free(state)
		move := mouse_test_relative_report(40, -20)

		// Inactive from the start (menu open): reports are read and dropped.
		native_mouse_accumulate(&state.mouse, &move)
		raw_input_thread_publish(state, raw_input_thread_sync(state))
		testing.expect_value(t, raw_input_thread_take_delta(state), shared.Vec2{})

		// Active: motion counts, and an absolute baseline is established.
		raw_input_thread_set_active(state, true)
		first := mouse_test_absolute_report(7, 10000, 10000)
		native_mouse_accumulate(&state.mouse, &first)
		raw_input_thread_publish(state, raw_input_thread_sync(state))
		native_mouse_accumulate(&state.mouse, &move)
		raw_input_thread_publish(state, raw_input_thread_sync(state))
		testing.expect_value(t, raw_input_thread_take_delta(state), shared.Vec2{40, -20})

		// Motion published but not yet taken when the game loses focus is
		// discarded by the transition, not delivered after alt-tab.
		native_mouse_accumulate(&state.mouse, &move)
		raw_input_thread_publish(state, raw_input_thread_sync(state))
		raw_input_thread_set_active(state, false)
		far := mouse_test_absolute_report(7, 60000, 60000)
		native_mouse_accumulate(&state.mouse, &far)
		native_mouse_accumulate(&state.mouse, &move)
		raw_input_thread_publish(state, raw_input_thread_sync(state))
		raw_input_thread_set_active(state, true)
		testing.expect_value(t, raw_input_thread_take_delta(state), shared.Vec2{})

		// Back in game: the absolute device re-baselines instead of jumping
		// by the distance it travelled while inactive.
		back := mouse_test_absolute_report(7, 20000, 20000)
		active := raw_input_thread_sync(state)
		native_mouse_accumulate(&state.mouse, &back)
		raw_input_thread_publish(state, active)
		testing.expect_value(t, raw_input_thread_take_delta(state), shared.Vec2{})
	}

	mouse_test_registered_target :: proc() -> (target: win.HWND, found: bool) {
		devices: [16]win.RAWINPUTDEVICE
		count := u32(len(devices))
		n := win.GetRegisteredRawInputDevices(&devices[0], &count, size_of(win.RAWINPUTDEVICE))
		if n == max(u32) { return nil, false }
		for device in devices[:n] {
			if device.usUsagePage == 1 && device.usUsage == 2 { return device.hwndTarget, true }
		}
		return nil, false
	}

	@(test)
	raw_input_thread_lifecycle :: proc(t: ^testing.T) {
		if !testing.expect(t, bool(glfw.Init())) do return
		defer glfw.Terminate()
		glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)
		window := glfw.CreateWindow(160, 120, "Raw input thread regression", nil, nil)
		if !testing.expect(t, window != nil) do return
		defer glfw.DestroyWindow(window)
		hwnd := glfw.GetWin32Window(window)
		previous := win.GetWindowLongPtrW(hwnd, win.GWLP_WNDPROC)

		if !testing.expect(t, client_mouse_init(window), "the raw input thread must start") do return
		defer client_mouse_fini()
		state := &g_raw_input_thread
		testing.expect(t, state.handle != nil && state.hwnd != nil, "the thread path must be chosen over the window-procedure fallback")
		testing.expect(t, g_native_mouse.previous_proc == nil && state.game_previous_proc != nil, "the thread path must be chosen and only wrap the game window once")
		testing.expect(t, client_mouse_init(window), "initialization must be safe to repeat")
		testing.expect(t, glfw.GetInputMode(window, glfw.RAW_MOUSE_MOTION) == 0, "GLFW must not compete for the raw mouse registration")
		target, found := mouse_test_registered_target()
		testing.expect(t, found && target == state.hwnd, "raw mouse input must target the message-only window")

		// Capturing the cursor must not let GLFW re-register raw input.
		glfw.SetInputMode(window, glfw.CURSOR, glfw.CURSOR_DISABLED)
		client_poll_events()
		target, found = mouse_test_registered_target()
		testing.expect(t, found && target == state.hwnd, "cursor capture must keep our registration")
		fallback := shared.Vec2{12, -3}
		testing.expect_value(t, client_mouse_delta(fallback), fallback) // a hidden window is never focused
		testing.expect(t, !sync.atomic_load(&state.active), "an unfocused window must not count raw motion")
		client_poll_events()
		testing.expect(t, win.GetCapture() != glfw.GetWin32Window(window) && !g_mouse_capture_held, "an unfocused window must not take mouse capture")
		glfw.SetInputMode(window, glfw.CURSOR, glfw.CURSOR_NORMAL)

		win.SendMessageW(hwnd, win.WM_LBUTTONDOWN, 0, 0)
		testing.expect(t, glfw.GetMouseButton(window, glfw.MOUSE_BUTTON_LEFT) == glfw.PRESS, "mouse buttons must still reach GLFW")
		win.SendMessageW(hwnd, win.WM_LBUTTONUP, 0, 0)
		g_mouse_test_scroll = 0
		glfw.SetScrollCallback(window, mouse_test_scroll)
		win.SendMessageW(hwnd, win.WM_MOUSEWHEEL, 120 << 16, 0)
		testing.expect(t, g_mouse_test_scroll == 1, "scroll wheel input must still reach GLFW")
		win.SendMessageW(hwnd, win.WM_KEYDOWN, 'W', 0x00110000)
		testing.expect(t, glfw.GetKey(window, glfw.KEY_W) == glfw.PRESS, "keyboard input must still reach GLFW")
		win.SendMessageW(hwnd, win.WM_KEYUP, 'W', 0xC0110000)
		client_wait_events(0.001)

		// Menus (cursor not captured) still get GLFW cursor movement.
		g_mouse_test_cursor = {}
		glfw.SetCursorPosCallback(window, mouse_test_cursor)
		win.SendMessageW(hwnd, win.WM_MOUSEMOVE, 0, win.LPARAM(40 | 30 << 16))
		testing.expect_value(t, g_mouse_test_cursor, [2]f64{40, 30})

		client_mouse_fini()
		testing.expect(t, state.handle == nil, "shutdown must join the input thread")
		testing.expect(t, win.GetWindowLongPtrW(hwnd, win.GWLP_WNDPROC) == previous, "shutdown must restore GLFW's window procedure")
		_, found = mouse_test_registered_target()
		testing.expect(t, !found, "shutdown must remove the raw mouse registration")
		testing.expect_value(t, client_mouse_delta(fallback), fallback)
		// The class is unregistered on exit, so the thread can start again.
		testing.expect(t, client_mouse_init(window), "the input thread must restart after shutdown")
	}

	@(test)
	mouse_capture_is_held_only_while_playing :: proc(t: ^testing.T) {
		// Holding capture while playing stops Windows sending WM_NCHITTEST,
		// WM_SETCURSOR and WM_MOUSEMOVE per mouse report (the 2-8 kHz stall).
		Case :: struct { playing, has, held, button: bool, action: Mouse_Capture_Action, held_after: bool }
		cases := [?]Case{
			{playing = true,  has = false, held = false, button = false, action = .TAKE,    held_after = true},  // start playing
			{playing = true,  has = true,  held = true,  button = false, action = .NONE,    held_after = true},  // keep it
			{playing = true,  has = false, held = true,  button = false, action = .TAKE,    held_after = true},  // GLFW released on button up: re-take
			{playing = true,  has = true,  held = false, button = true,  action = .NONE,    held_after = true},  // GLFW already holds it for a button
			{playing = false, has = true,  held = true,  button = false, action = .RELEASE, held_after = false}, // opened a menu
			{playing = false, has = true,  held = true,  button = true,  action = .NONE,    held_after = false}, // button still down: GLFW releases it
			{playing = false, has = false, held = true,  button = false, action = .NONE,    held_after = false}, // alt-tab: Windows dropped it
			{playing = false, has = true,  held = false, button = false, action = .NONE,    held_after = false}, // not ours (GLFW's button capture in menus)
			{playing = false, has = false, held = false, button = false, action = .NONE,    held_after = false},
		}
		for c, i in cases {
			action, held := mouse_capture_decide(c.playing, c.has, c.held, c.button)
			testing.expectf(t, action == c.action && held == c.held_after, "case %d: got %v/%v, want %v/%v", i, action, held, c.action, c.held_after)
		}
	}

	@(test)
	mouse_capture_drops_on_focus_loss_and_minimise :: proc(t: ^testing.T) {
		// Alt-tab out of fullscreen: capture must be gone before the window is
		// minimised, or the minimised window can keep it and never restore.
		testing.expect(t, mouse_capture_should_drop(win.WM_KILLFOCUS, 0), "losing focus drops capture")
		testing.expect(t, mouse_capture_should_drop(win.WM_ACTIVATEAPP, 0) && !mouse_capture_should_drop(win.WM_ACTIVATEAPP, 1), "app deactivation drops it, activation does not")
		testing.expect(t, mouse_capture_should_drop(win.WM_ACTIVATE, win.WPARAM(win.WA_INACTIVE)), "window deactivation drops it")
		testing.expect(t, !mouse_capture_should_drop(win.WM_ACTIVATE, win.WPARAM(win.WA_ACTIVE)) && !mouse_capture_should_drop(win.WM_ACTIVATE, win.WPARAM(win.WA_CLICKACTIVE)), "activation keeps it")
		testing.expect(t, mouse_capture_should_drop(win.WM_SIZE, win.SIZE_MINIMIZED) && !mouse_capture_should_drop(win.WM_SIZE, win.SIZE_RESTORED), "minimising drops it, restoring does not")
		testing.expect(t, !mouse_capture_should_drop(win.WM_SETFOCUS, 0) && !mouse_capture_should_drop(win.WM_MOUSEMOVE, 0), "other messages keep it")
		// Dropping clears our hold even if Windows already released capture.
		g_mouse_capture_held = true
		mouse_capture_drop(nil, win.WM_KILLFOCUS, 0)
		testing.expect(t, !g_mouse_capture_held, "the hold is cleared")
	}
}
