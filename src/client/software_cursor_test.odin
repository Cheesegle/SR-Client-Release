package main

import "core:testing"

when ODIN_TEST {
	@(test)
	software_cursor_only_in_exclusive_fullscreen_menus :: proc(t: ^testing.T) {
		testing.expect(t, software_cursor_wanted(true, false, false, true), "exclusive fullscreen menus draw the cursor")
		testing.expect(t, !software_cursor_wanted(false, false, false, true), "windowed and borderless keep the OS cursor")
		testing.expect(t, !software_cursor_wanted(true, true, false, true), "gameplay (cursor disabled) draws no cursor")
		testing.expect(t, !software_cursor_wanted(true, false, true, true), "a minimised (alt-tabbed) window leaves the OS cursor alone")
		testing.expect(t, !software_cursor_wanted(true, false, false, false), "without the cursor image the OS cursor stays visible")
	}

	@(test)
	software_cursor_rect_places_hotspot_on_cursor :: proc(t: ^testing.T) {
		x, y, w, h := software_cursor_rect(100, 50, 1920, 1080, 1920, 1080, 3, 4, 48, 48)
		testing.expect(t, x == 97 && y == 46 && w == 48 && h == 48, "hotspot sits on the cursor at 1:1")
		x, y, _, _ = software_cursor_rect(100, 50, 1280, 720, 2560, 1440, 0, 0, 32, 32)
		testing.expect(t, x == 200 && y == 100, "window coordinates scale to framebuffer pixels")
		x, y, _, _ = software_cursor_rect(10, 20, 0, 0, 0, 0, 0, 0, 32, 32)
		testing.expect(t, x == 10 && y == 20, "a zero-sized (minimised) window does not divide by zero")
	}

	@(test)
	software_cursor_recovers_alpha_and_flips_rows :: proc(t: ^testing.T) {
		// 1x3 BGRA column, top to bottom: transparent, opaque red, half white.
		on_black := []u8{0, 0, 0, 0, 0, 0, 255, 0, 128, 128, 128, 0}
		on_white := []u8{255, 255, 255, 0, 0, 0, 255, 0, 255, 255, 255, 0}
		rgba := software_cursor_pixels_from_backgrounds(on_black, on_white, 1, 3, context.temp_allocator)
		if !testing.expect(t, len(rgba) == 12) do return
		// Rows come out bottom-up: half white, red, transparent.
		testing.expect(t, rgba[3] == 128 && rgba[0] == 255 && rgba[1] == 255 && rgba[2] == 255, "partial coverage keeps its colour and alpha")
		testing.expect(t, rgba[4] == 255 && rgba[5] == 0 && rgba[6] == 0 && rgba[7] == 255, "BGRA becomes RGBA and opaque stays opaque")
		testing.expect(t, rgba[11] == 0, "background pixels are transparent")
		// An inverting pixel: white over black, black over white.
		invert := software_cursor_pixels_from_backgrounds([]u8{255, 255, 255, 0}, []u8{0, 0, 0, 0}, 1, 1, context.temp_allocator)
		testing.expect(t, len(invert) == 4 && invert[3] == 255, "inverting pixels stay visible")
		testing.expect(t, software_cursor_pixels_from_backgrounds(on_black, on_white, 2, 3) == nil, "short buffers are rejected")
		// GDI blends opaque pixels a level or two apart over black and white.
		near := software_cursor_pixels_from_backgrounds([]u8{10, 20, 30, 0}, []u8{11, 21, 31, 0}, 1, 1, context.temp_allocator)
		testing.expect(t, len(near) == 4 && near[3] == 255 && near[0] == 30 && near[2] == 10, "near-opaque rounding snaps to opaque")
	}
}
