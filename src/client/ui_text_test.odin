package main

import "base:runtime"
import "core:testing"
import gl "vendor:OpenGL"
import glfw "vendor:glfw"
import stbtt "vendor:stb/truetype"

when ODIN_TEST {
	// The glyph array and cached kerning must measure exactly what the old
	// per-pair stbtt.GetCodepointKernAdvance * ScaleForPixelHeight did.
	@(test)
	text_measure_matches_direct_kerning :: proc(t: ^testing.T) {
		// Glyphs are allocated with the default allocator, as in the menu callback.
		logger := context.logger
		context = runtime.default_context()
		context.logger = logger
		if !testing.expect(t, bool(glfw.Init()), "GLFW initialization failed") do return
		defer glfw.Terminate()
		glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)
		glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 5)
		window := glfw.CreateWindow(320, 240, "Text measure", nil, nil)
		if !testing.expect(t, window != nil, "hidden OpenGL window failed") do return
		defer glfw.DestroyWindow(window)
		defer glfw.DefaultWindowHints()
		glfw.MakeContextCurrent(window)
		gl.load_up_to(4, 5, glfw.gl_set_proc_address)
		ui := ui_init()
		defer { ui_fini(ui); resource_cache_fini() }
		ui_update(ui, 320, 240)

		samples := []string{"AVATAR Wa To. Ty Yo LT", "SR Client - Settings", "1920 x 1080", "AVéA"}
		sizes := []f32{11, 16, 24.5, 48}
		for pass in 0 ..< 2 { // the second pass reads every pair from the cache
			for sample in samples {
				for size in sizes {
					expected: f32
					previous: rune
					for c in sample {
						glyph := load_glyph(u8(c))
						if glyph == nil { continue }
						kern: f32
						if previous != 0 {
							units := stbtt.GetCodepointKernAdvance(&g_font_info, previous, c)
							kern = f32(units) * stbtt.ScaleForPixelHeight(&g_font_info, size)
						}
						expected += kern + glyph.advance * size / 100.0
						previous = c
					}
					measured := ui_measure_text(ui, sample, size)
					drawn := ui_fill_text(ui, {1, 1, 1, 1}, sample, 0, 100, size)
					testing.expectf(t, measured == expected && drawn == expected, "pass %d %q at %v: measured %v drawn %v, expected %v", pass, sample, size, measured, drawn, expected)
				}
			}
		}
		// stb reads no kerning from the bundled Rajdhani today, so also check every
		// printable ASCII pair and a non-ASCII one directly against the old formula.
		testing.expect(t, g_font_loaded, "the UI font must load")
		for size in sizes {
			for a in rune(32) ..< 127 {
				for b in rune(32) ..< 127 {
					expected := f32(stbtt.GetCodepointKernAdvance(&g_font_info, a, b)) * stbtt.ScaleForPixelHeight(&g_font_info, size)
					if ui_text_kerning(a, b, size) != expected { testing.expectf(t, false, "kerning %q%q at %v differs", a, b, size); return }
				}
			}
			testing.expect(t, ui_text_kerning('é', 'A', size) == f32(stbtt.GetCodepointKernAdvance(&g_font_info, 'é', 'A')) * stbtt.ScaleForPixelHeight(&g_font_info, size), "non-ASCII kerning must match")
			testing.expect(t, ui_text_kerning(0, 'A', size) == 0, "the first character has no kerning")
		}
		testing.expect(t, g_glyph_caches[g_font_slot]['A'] != nil && load_glyph('A') == g_glyph_caches[g_font_slot]['A'], "glyphs must be cached by byte")
	}
}
