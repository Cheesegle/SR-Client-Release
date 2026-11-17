package main

import glfw "vendor:glfw"

// Menu cursor in exclusive fullscreen.
//
// Testers saw no mouse cursor in the menus with Display mode = Fullscreen,
// while Windows itself reported the arrow as shown (GetCursorInfo:
// CURSOR_SHOWING, the IDC_ARROW handle, cursor inside the monitor, no capture)
// at startup, after moving the mouse and after alt-tab, at native and lower
// resolutions. In exclusive fullscreen the OpenGL driver page-flips the
// window straight to the display and the desktop compositor is bypassed.
// Whenever Windows draws the pointer in software rather than on the display
// hardware's cursor plane (enlarged or custom pointers, pointer trails,
// accessibility tools, hybrid-GPU laptops, some drivers), the compositor is
// what would have drawn it, so it is not drawn at all. GLFW works around one
// trigger (it turns mouse trails off while fullscreen); the others cannot be
// switched off by an application. Borderless and windowed are composited and
// never had the problem.
//
// So while the window is exclusive fullscreen and the cursor is free (menus,
// end screen, loading), the game draws the user's own arrow cursor itself,
// as part of the frame, and gives Windows a transparent cursor for the window
// so the two never show at once. Gameplay (CURSOR_DISABLED) is untouched.
Software_Cursor :: struct {
	texture: Gpu_Texture,
	width, height: i32,
	hot_x, hot_y: i32,
	loaded, load_failed: bool,
	blank: glfw.CursorHandle, // transparent GLFW cursor, set while drawing our own
	active: bool,             // the blank cursor is currently set on the window
	window: glfw.WindowHandle,
}

g_software_cursor: Software_Cursor

// The game draws the cursor only in exclusive fullscreen, while the cursor is
// free and the window is shown, and only if the system arrow could be read.
software_cursor_wanted :: proc(exclusive_fullscreen, cursor_disabled, iconified, image_available: bool) -> bool {
	return exclusive_fullscreen && !cursor_disabled && !iconified && image_available
}

// Framebuffer rectangle for the cursor image: GLFW reports the cursor in
// window coordinates, the frame is drawn in framebuffer pixels, and the
// image's hotspot sits on the cursor position.
software_cursor_rect :: proc(cursor_x, cursor_y: f64, window_width, window_height, framebuffer_width, framebuffer_height, hot_x, hot_y, width, height: i32) -> (x, y, w, h: f32) {
	scale_x, scale_y: f32 = 1, 1
	if window_width > 0 && framebuffer_width > 0 { scale_x = f32(framebuffer_width) / f32(window_width) }
	if window_height > 0 && framebuffer_height > 0 { scale_y = f32(framebuffer_height) / f32(window_height) }
	x = f32(cursor_x) * scale_x - f32(hot_x)
	y = f32(cursor_y) * scale_y - f32(hot_y)
	return x, y, f32(width), f32(height)
}

// Recovers straight-alpha RGBA from the same cursor drawn once over black and
// once over white (BGRA rows, as GDI writes them). A pixel the cursor covers
// fully looks the same on both; a transparent one is the background; partial
// coverage is in between. Inverting (XOR) pixels come out opaque. Rows are
// flipped to bottom-up, the order UI textures are uploaded in.
SOFTWARE_CURSOR_OPAQUE_SNAP :: 252

software_cursor_pixels_from_backgrounds :: proc(on_black, on_white: []u8, width, height: i32, allocator := context.allocator) -> []u8 {
	count := int(width) * int(height)
	if width <= 0 || height <= 0 || len(on_black) < count * 4 || len(on_white) < count * 4 { return nil }
	rgba := make([]u8, count * 4, allocator)
	for row in 0..<int(height) {
		out_row := int(height) - 1 - row
		for column in 0..<int(width) {
			src := (row * int(width) + column) * 4
			dst := (out_row * int(width) + column) * 4
			// Over white the background shows through by (1 - alpha); average
			// the three channels against rounding. GDI's blend leaves fully
			// covered pixels 1-2 levels apart, so those snap back to opaque.
			difference := 0
			for c in 0..<3 { difference += int(on_white[src+c]) - int(on_black[src+c]) }
			alpha := clamp(255 - (difference + 1) / 3, 0, 255)
			if alpha >= SOFTWARE_CURSOR_OPAQUE_SNAP { alpha = 255 }
			// GDI is BGRA; the texture is RGBA. Over black the drawn value is
			// colour * alpha, so divide alpha back out.
			for c in 0..<3 {
				value := 0
				if alpha > 0 { value = min(int(on_black[src+2-c]) * 255 / alpha, 255) }
				rgba[dst+c] = u8(value)
			}
			rgba[dst+3] = u8(alpha)
		}
	}
	return rgba
}

software_cursor_upload :: proc(rgba: []u8, width, height: i32) -> Gpu_Texture {
	return gpu_texture_create({width = width, height = height, format = .RGBA8, sampler = GPU_SAMPLER_UI_NEAREST}, rgba)
}

// Reads the user's arrow cursor (their pointer scheme and size) into a
// texture. Called again whenever exclusive fullscreen starts, since a mode
// change can change the pointer size.
software_cursor_load :: proc(cursor: ^Software_Cursor) {
	software_cursor_unload_image(cursor)
	rgba, width, height, hot_x, hot_y, ok := system_arrow_cursor_rgba(context.temp_allocator)
	if !ok {
		cursor.load_failed = true
		return
	}
	cursor.texture = software_cursor_upload(rgba, width, height)
	cursor.width, cursor.height, cursor.hot_x, cursor.hot_y = width, height, hot_x, hot_y
	cursor.loaded = true
}

software_cursor_unload_image :: proc(cursor: ^Software_Cursor) {
	gpu_texture_destroy(&cursor.texture)
	cursor.loaded, cursor.load_failed = false, false
}

software_cursor_set_os_cursor_hidden :: proc(cursor: ^Software_Cursor, window: glfw.WindowHandle, hidden: bool) {
	if hidden == cursor.active { return }
	if hidden && cursor.blank == nil {
		pixels: [4]u8 // one transparent pixel
		image := glfw.Image{width = 1, height = 1, pixels = raw_data(pixels[:])}
		cursor.blank = glfw.CreateCursor(&image, 0, 0)
		if cursor.blank == nil { return }
	}
	// NORMAL mode shows the window's cursor; nil is GLFW's default arrow.
	glfw.SetCursor(window, hidden ? cursor.blank : nil)
	cursor.active = hidden
	cursor.window = window
}

// Once per frame, before the frame is drawn: decide whether the game draws
// the cursor, and hide or restore the OS cursor to match.
software_cursor_update :: proc(window: glfw.WindowHandle) {
	cursor := &g_software_cursor
	if window == nil { return }
	exclusive := glfw.GetWindowMonitor(window) != nil
	if !exclusive && cursor.loaded { software_cursor_unload_image(cursor) }
	if !exclusive { cursor.load_failed = false }
	disabled := glfw.GetInputMode(window, glfw.CURSOR) == glfw.CURSOR_DISABLED
	iconified := glfw.GetWindowAttrib(window, glfw.ICONIFIED) != 0
	if exclusive && !cursor.loaded && !cursor.load_failed { software_cursor_load(cursor) }
	software_cursor_set_os_cursor_hidden(cursor, window, software_cursor_wanted(exclusive, disabled, iconified, cursor.loaded))
}

// Last thing in the frame, so it is above menus, overlays and the debug window.
software_cursor_render :: proc(client: ^Client) {
	cursor := &g_software_cursor
	if !cursor.active || cursor.texture == 0 || client.window == nil || client.ui == nil { return }
	// This frame may have just started play; GLFW already hides the cursor then.
	if glfw.GetInputMode(client.window, glfw.CURSOR) == glfw.CURSOR_DISABLED { return }
	cursor_x, cursor_y := glfw.GetCursorPos(client.window)
	window_width, window_height := glfw.GetWindowSize(client.window)
	x, y, w, h := software_cursor_rect(cursor_x, cursor_y, window_width, window_height, client.viewport_width, client.viewport_height, cursor.hot_x, cursor.hot_y, cursor.width, cursor.height)
	ui_update(client.ui, f32(client.viewport_width), f32(client.viewport_height))
	ui_draw_image(client.ui, cursor.texture, x, y, w, h)
}

software_cursor_fini :: proc() {
	cursor := &g_software_cursor
	if cursor.window != nil && cursor.active { glfw.SetCursor(cursor.window, nil) }
	if cursor.blank != nil { glfw.DestroyCursor(cursor.blank) }
	software_cursor_unload_image(cursor)
	cursor^ = {}
}
