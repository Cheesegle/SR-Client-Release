#+build windows

package main

import "core:testing"
import gl "vendor:OpenGL"
import glfw "vendor:glfw"

when ODIN_TEST {
	@(test)
	software_cursor_reads_system_arrow :: proc(t: ^testing.T) {
		rgba, width, height, hot_x, hot_y, ok := system_arrow_cursor_rgba(context.temp_allocator)
		if !testing.expect(t, ok, "the user's arrow cursor must be readable") do return
		testing.expect(t, width >= 16 && height >= 16 && len(rgba) == int(width*height*4), "cursor image has a real size")
		testing.expect(t, hot_x >= 0 && hot_x < width && hot_y >= 0 && hot_y < height, "hotspot lies inside the image")
		opaque, clear := 0, 0
		for i := 3; i < len(rgba); i += 4 {
			if rgba[i] == 255 { opaque += 1 }
			if rgba[i] == 0 { clear += 1 }
		}
		testing.expectf(t, opaque > 10 && clear > 10, "the arrow has both drawn and transparent pixels (%dx%d, %d opaque, %d clear)", width, height, opaque, clear)
	}

	@(test)
	software_cursor_hidden_window_lifecycle :: proc(t: ^testing.T) {
		if !testing.expect(t, bool(glfw.Init())) do return
		defer glfw.Terminate()
		glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)
		glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 5)
		window := glfw.CreateWindow(160, 120, "Software cursor regression", nil, nil)
		if !testing.expect(t, window != nil) do return
		defer glfw.DestroyWindow(window)
		glfw.MakeContextCurrent(window)
		gl.load_up_to(4, 5, glfw.gl_set_proc_address)
		defer software_cursor_fini()
		cursor := &g_software_cursor

		// A window that is not exclusive fullscreen keeps the OS cursor.
		software_cursor_update(window)
		testing.expect(t, !cursor.active && !cursor.loaded, "windowed mode must not hide or replace the OS cursor")

		// What exclusive fullscreen does: load the image, hide the OS cursor.
		software_cursor_load(cursor)
		if !testing.expect(t, cursor.loaded && cursor.texture != 0, "the cursor texture must upload") do return
		w, h: i32
		gl.BindTexture(gl.TEXTURE_2D, u32(cursor.texture))
		gl.GetTexLevelParameteriv(gl.TEXTURE_2D, 0, gl.TEXTURE_WIDTH, &w)
		gl.GetTexLevelParameteriv(gl.TEXTURE_2D, 0, gl.TEXTURE_HEIGHT, &h)
		gl.BindTexture(gl.TEXTURE_2D, 0)
		testing.expect(t, w == cursor.width && h == cursor.height, "texture matches the cursor size")
		software_cursor_set_os_cursor_hidden(cursor, window, true)
		testing.expect(t, cursor.active && cursor.blank != nil, "the transparent OS cursor must be set")
		testing.expect(t, glfw.GetInputMode(window, glfw.CURSOR) == glfw.CURSOR_NORMAL, "the cursor mode stays NORMAL, so raw input and capture logic see a menu")
		testing.expect(t, !raw_input_thread_wanted(window), "a hidden menu cursor is never treated as play")

		// Leaving exclusive fullscreen restores the OS cursor and frees the image.
		software_cursor_update(window)
		testing.expect(t, !cursor.active && !cursor.loaded && cursor.texture == 0, "windowed again: OS cursor back, image released")

		// Gameplay in exclusive fullscreen: GLFW hides the cursor, we draw nothing.
		glfw.SetInputMode(window, glfw.CURSOR, glfw.CURSOR_DISABLED)
		testing.expect(t, !software_cursor_wanted(true, glfw.GetInputMode(window, glfw.CURSOR) == glfw.CURSOR_DISABLED, false, true), "disabled cursor means no game-drawn cursor")
	}
}
