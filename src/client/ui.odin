package main

import "core:fmt"
import "core:math"
import "core:strings"
import core_c "core:c"
import gl "vendor:OpenGL"
import stbtt "vendor:stb/truetype"
import shared "../shared"

g_font_info: stbtt.fontinfo
g_font_loaded: bool
g_font_data: []byte
// ascent - descent: stbtt.ScaleForPixelHeight(size) is size / g_font_height_units.
g_font_height_units: f32
// Kerning in font units for ASCII pairs, filled on first use (per font).
g_kern_caches: [Font_Slot][128][128]i32
g_kern_cacheds: [Font_Slot][128][128]bool

stb_font_metrics :: proc(ascent, descent, gap: ^i32) {
	load_font()
	if g_font_loaded {
		stbtt.GetFontVMetrics(&g_font_info, ascent, descent, gap)
	} else {
		ascent^ = 1
		descent^ = 0
		gap^ = 0
	}
}

// Glyphs above U+00FF (chat: č, š, ž, ...) are cached by rune here (per font).
g_glyph_extras: [Font_Slot]map[rune]^Glyph_Cache_Entry

// Two fonts: the menu's (Rajdhani) and Krunker's game font for the in-game
// HUD. The globals above are always the active font; ui_use_font swaps only
// the small font state, the glyph and kerning caches are kept per font
// (copying them on every switch cost about 0.5 MB of memory traffic a frame).
Font_Slot :: enum { UI, GAME }
Font_State :: struct {
	info: stbtt.fontinfo,
	loaded: bool,
	data: []byte,
	height_units: f32,
}
g_font_slot: Font_Slot
g_font_saved: [Font_Slot]Font_State
FONT_FILES := [Font_Slot]string{.UI = "css/fonts/Rajdhani-SemiBold.ttf", .GAME = "css/fonts/FrVrKrunkerBold2.ttf"}

ui_use_font :: proc(slot: Font_Slot) {
	if slot == g_font_slot { return }
	saved := &g_font_saved[g_font_slot]
	saved.info, saved.loaded, saved.data, saved.height_units = g_font_info, g_font_loaded, g_font_data, g_font_height_units
	next := &g_font_saved[slot]
	g_font_info, g_font_loaded, g_font_data, g_font_height_units = next.info, next.loaded, next.data, next.height_units
	next^ = {}
	g_font_slot = slot
}

load_glyph_rune :: proc(c: rune) -> ^Glyph_Cache_Entry {
	if c >= 0 && c < 256 { return load_glyph(u8(c)) }
	if cached, ok := g_glyph_extras[g_font_slot][c]; ok { return cached }
	if !g_font_loaded { load_font() }
	if !g_font_loaded { return load_glyph('?') }
	glyph: ^Glyph_Cache_Entry
	if stbtt.FindGlyphIndex(&g_font_info, c) != 0 {
		glyph = glyph_create(c)
	} else if g_font_slot == .GAME && g_font_saved[.UI].loaded && stbtt.FindGlyphIndex(&g_font_saved[.UI].info, c) != 0 {
		// Krunker's font has no č, š, ž...: borrow the menu font's glyph.
		glyph = glyph_create(c, &g_font_saved[.UI].info)
	} else {
		return load_glyph('?')
	}
	if glyph != nil { g_glyph_extras[g_font_slot][c] = glyph }
	return glyph
}

load_glyph :: proc(c: u8) -> ^Glyph_Cache_Entry {
	if cached := g_glyph_caches[g_font_slot][c]; cached != nil {
		return cached
	}
	glyph := glyph_create(rune(c))
	if glyph != nil { g_glyph_caches[g_font_slot][c] = glyph }
	return glyph
}

glyph_create :: proc(c: rune, from: ^stbtt.fontinfo = nil) -> ^Glyph_Cache_Entry {

	glyph := new(Glyph_Cache_Entry)

	// Font is loaded lazily from assets (matches C's freetype usage).
	if !g_font_loaded {
		load_font()
	}

	if !g_font_loaded {
		free(glyph)
		return nil
	}

	info := from != nil ? from : &g_font_info
	scale := stbtt.ScaleForPixelHeight(info, 100)
	advance_width, left_side_bearing: core_c.int
	stbtt.GetCodepointHMetrics(info, c, &advance_width, &left_side_bearing)

	width, height, xoff, yoff: core_c.int
	bitmap := stbtt.GetCodepointBitmap(info, scale, scale, c, &width, &height, &xoff, &yoff)

	if bitmap != nil && width > 0 && height > 0 {
		gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1)
		gl.GenTextures(1, &glyph.texture)
		gl.BindTexture(gl.TEXTURE_2D, glyph.texture)

		gl.TexImage2D(
			gl.TEXTURE_2D, 0, gl.RED,
			width, height,
			0, gl.RED, gl.UNSIGNED_BYTE,
			bitmap,
		)

		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
		// Glyphs are grayscale coverage textures. Linear filtering preserves
		// their edge coverage when the 100 px raster is scaled to UI size;
		// nearest filtering makes every menu and HUD character look jagged.
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)

		gl.PixelStorei(gl.UNPACK_ALIGNMENT, 4)
		stbtt.FreeBitmap(bitmap, nil)
		// Glyphs load during layout, between draws: the bind above must not
		// leave the material binding cache naming the previous texture.
		g_active_texture = 0
	}

	glyph.size.x = f32(width)
	glyph.size.y = f32(height)
	// Convert stb's baseline-relative offsets into the bearing convention used
	// by the original FreeType UI implementation.
	glyph.h_bearing = shared.Vec2{f32(xoff), -f32(yoff)}
	glyph.advance = f32(advance_width) * scale
	return glyph
}

load_font :: proc() {
	if g_font_loaded {
		return
	}

	font_path := shared.concat(shared.assets_path(), FONT_FILES[g_font_slot])
	font_data, ok := shared.read_file(font_path)
	delete(font_path)
	if !ok && g_font_slot != .UI {
		// No game font installed: the HUD uses the menu font.
		font_path = shared.concat(shared.assets_path(), FONT_FILES[.UI])
		font_data, ok = shared.read_file(font_path)
		delete(font_path)
	}

	if ok {
		g_font_data = font_data
		g_font_loaded = bool(stbtt.InitFont(&g_font_info, &g_font_data[0], 0))
	}
	if g_font_loaded {
		ascent, descent, gap: i32
		stbtt.GetFontVMetrics(&g_font_info, &ascent, &descent, &gap)
		g_font_height_units = f32(ascent - descent)
		g_kern_cacheds[g_font_slot] = {}
	}
}

ui_init :: proc() -> ^UI {
	ui := new(UI)

	ui.material = quad_material_init()
	ui.text_material = text_material_init()

	gl.GenBuffers(1, &ui.vbo)

	gl.GenVertexArrays(1, &ui.vao)
	gl.BindVertexArray(ui.vao)

	vertices := [?]Vertex{
		{{-1.0, -1.0, 0.0}, {0.0, 0.0}},
		{{1.0, -1.0, 0.0}, {1.0, 0.0}},
		{{1.0, 1.0, 0.0}, {1.0, 1.0}},
		{{-1.0, 1.0, 0.0}, {0.0, 1.0}},
	}

	gl.BindBuffer(gl.ARRAY_BUFFER, ui.vbo)
	gl.BufferData(gl.ARRAY_BUFFER, size_of(vertices), &vertices[0], gl.STATIC_DRAW)

	stride := i32(size_of(Vertex))

	gl.VertexAttribPointer(0, 3, gl.FLOAT, gl.FALSE, stride, 0)
	gl.VertexAttribPointer(1, 2, gl.FLOAT, gl.FALSE, stride, uintptr(3 * size_of(f32)))

	gl.EnableVertexAttribArray(0)
	gl.EnableVertexAttribArray(1)

	// ui_fill_polygon's dynamic vertices, allocated once up front.
	gl.GenVertexArrays(1, &ui.poly_vao)
	gl.GenBuffers(1, &ui.poly_vbo)
	gl.BindVertexArray(ui.poly_vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, ui.poly_vbo)
	gl.BufferData(gl.ARRAY_BUFFER, UI_POLYGON_MAX * size_of(Vertex), nil, gl.DYNAMIC_DRAW)
	gl.VertexAttribPointer(0, 3, gl.FLOAT, gl.FALSE, stride, 0)
	gl.VertexAttribPointer(1, 2, gl.FLOAT, gl.FALSE, stride, uintptr(3 * size_of(f32)))
	gl.EnableVertexAttribArray(0)
	gl.EnableVertexAttribArray(1)

	ui.vignette = damage_vignette_texture()

	return ui
}

ui_update :: proc(ui: ^UI, width, height: f32) {
	ui.width = width
	ui.height = height

	scale_factor: f32 = 1.5
	target_width: f32 = scale_factor * 1700.0
	target_height: f32 = scale_factor * 900.0

	scale_x := ui.width / target_width
	scale_y := ui.height / target_height

	ui.scale = min(scale_x, scale_y)

	gl.Disable(gl.DEPTH_TEST)
	gl.Enable(gl.BLEND)
	gl.PolygonMode(gl.FRONT_AND_BACK, gl.FILL)
}

ui_fill_rect_ :: proc(ui: ^UI, shader: u32, x, y, width, height: f32) {
	// A minimized window (0x0) or a NaN layout box would send NaN/Inf vertex
	// positions to the driver for every UI quad; draw nothing instead.
	finite :: proc(value: f32) -> bool { return !math.is_nan(value) && !math.is_inf(value) }
	if !(ui.width > 0 && ui.height > 0) || !finite(x) || !finite(y) || !finite(width) || !finite(height) {
		return
	}
	offset_x := (x + width * 0.5) / ui.width * 2.0 - 1.0
	offset_y := 1.0 - (y + height * 0.5) / ui.height * 2.0

	scale_x := width / ui.width
	scale_y := height / ui.height

	u := scene_uniforms(shader)

	gl.BindVertexArray(ui.vao)

	if u.offset > -1 {
		gl.Uniform2f(u.offset, offset_x, offset_y)
	}
	if u.scale > -1 {
		gl.Uniform2f(u.scale, scale_x, scale_y)
	}

	gl.DrawArrays(gl.TRIANGLE_FAN, 0, 4)
	g_draw_calls += 1
}

ui_fill_rect :: proc(ui: ^UI, color: shared.Vec4, x, y, width, height: f32) {
	ui.material.color = color
	ui.material.texture = 0

	ui.material.texture_viewport = [4]f32{0.0, 0.0, 1.0, 1.0}

	ui.material.border_bottom_left_radius = 0.0
	ui.material.border_bottom_right_radius = 0.0
	ui.material.border_top_left_radius = 0.0
	ui.material.border_top_right_radius = 0.0

	ui.material.r_clip = 0.0

	if g_active_shader != ui.material.base.program {
		gl.UseProgram(ui.material.base.program)
		g_active_shader = ui.material.base.program
	}

	material_update_uniforms(&ui.material.base)

	ui_fill_rect_(ui, ui.material.base.program, x, y, width, height)
}

// A convex (or center-visible) polygon in screen pixels, drawn as a triangle
// fan with the flat UI color. Used for rotated HUD shapes such as hitmarkers.
UI_POLYGON_MAX :: 64
ui_fill_polygon :: proc(ui: ^UI, color: shared.Vec4, points: []shared.Vec2) {
	if len(points) < 3 || len(points) > UI_POLYGON_MAX || !(ui.width > 0 && ui.height > 0) { return }
	vertices: [UI_POLYGON_MAX]Vertex
	for p, i in points {
		if math.is_nan(p.x) || math.is_nan(p.y) || math.is_inf(p.x) || math.is_inf(p.y) { return }
		// The centered texture coordinate never reaches the rounded-corner path.
		vertices[i] = {{p.x / ui.width * 2 - 1, 1 - p.y / ui.height * 2, 0}, {0.5, 0.5}}
	}
	if ui.poly_vao == 0 { return }
	ui.material.color = color
	ui.material.texture = 0
	ui.material.texture_viewport = [4]f32{0.0, 0.0, 1.0, 1.0}
	ui.material.border_bottom_left_radius = 0.0
	ui.material.border_bottom_right_radius = 0.0
	ui.material.border_top_left_radius = 0.0
	ui.material.border_top_right_radius = 0.0
	ui.material.r_clip = 0.0
	ui.material.stroke_width = 0
	if g_active_shader != ui.material.base.program {
		gl.UseProgram(ui.material.base.program)
		g_active_shader = ui.material.base.program
	}
	material_update_uniforms(&ui.material.base)
	u := scene_uniforms(ui.material.base.program)
	if u.offset > -1 { gl.Uniform2f(u.offset, 0, 0) }
	if u.scale > -1 { gl.Uniform2f(u.scale, 1, 1) }
	gl.BindVertexArray(ui.poly_vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, ui.poly_vbo)
	gl.BufferSubData(gl.ARRAY_BUFFER, 0, len(points) * size_of(Vertex), &vertices[0])
	gl.DrawArrays(gl.TRIANGLE_FAN, 0, i32(len(points)))
	g_draw_calls += 1
}

ui_round_rect :: proc(ui: ^UI, color: shared.Vec4, x, y, width, height, radius: f32) {
	ui.material.color = color
	ui.material.texture = 0

	ui.material.texture_viewport = [4]f32{0.0, 0.0, 1.0, 1.0}

	radius_mlt := radius / min(width, height)

	ui.material.aspect = width / height
	ui.material.border_bottom_left_radius = radius_mlt
	ui.material.border_bottom_right_radius = radius_mlt
	ui.material.border_top_left_radius = radius_mlt
	ui.material.border_top_right_radius = radius_mlt

	ui.material.r_clip = 0.0

	if g_active_shader != ui.material.base.program {
		gl.UseProgram(ui.material.base.program)
		g_active_shader = ui.material.base.program
	}

	material_update_uniforms(&ui.material.base)

	ui_fill_rect_(ui, ui.material.base.program, x, y, width, height)
}

// A rectangle with only its top corners rounded (border-radius: r r 0 0).
ui_round_rect_top :: proc(ui: ^UI, color: shared.Vec4, x, y, width, height, radius: f32) {
	ui.material.color = color
	ui.material.texture = 0
	ui.material.texture_viewport = [4]f32{0.0, 0.0, 1.0, 1.0}
	radius_mlt := radius / min(width, height)
	ui.material.aspect = width / height
	ui.material.border_top_left_radius = radius_mlt
	ui.material.border_top_right_radius = radius_mlt
	ui.material.border_bottom_left_radius = 0
	ui.material.border_bottom_right_radius = 0
	ui.material.r_clip = 0.0
	if g_active_shader != ui.material.base.program {
		gl.UseProgram(ui.material.base.program)
		g_active_shader = ui.material.base.program
	}
	material_update_uniforms(&ui.material.base)
	ui_fill_rect_(ui, ui.material.base.program, x, y, width, height)
}

ui_fill_rect_rclip :: proc(ui: ^UI, color: shared.Vec4, x, y, width, height, radius, r_clip: f32) {
	ui.material.color = color
	ui.material.texture = 0

	ui.material.texture_viewport = [4]f32{0.0, 0.0, 1.0, 1.0}

	radius_mlt := radius / min(width, height)

	ui.material.aspect = width / height
	ui.material.border_bottom_left_radius = radius_mlt
	ui.material.border_bottom_right_radius = radius_mlt
	ui.material.border_top_left_radius = radius_mlt
	ui.material.border_top_right_radius = radius_mlt

	ui.material.r_clip = r_clip

	if g_active_shader != ui.material.base.program {
		gl.UseProgram(ui.material.base.program)
		g_active_shader = ui.material.base.program
	}

	material_update_uniforms(&ui.material.base)

	ui_fill_rect_(ui, ui.material.base.program, x, y, width, height)
}

ui_stroke_round_rect :: proc(ui: ^UI, color: shared.Vec4, x, y, width, height, radius, thickness: f32) {
	ui.material.stroke_width = thickness / min(width, height)
	ui_round_rect(ui, color, x, y, width, height, radius)
	ui.material.stroke_width = 0
}

// mirror flips the image horizontally (CSS transform: scaleX(-1)).
ui_draw_image :: proc(ui: ^UI, texture_id: u32, x, y, width, height: f32, color := shared.Vec4{1.0, 1.0, 1.0, 1.0}, mirror := false) {
	ui.material.color = color
	ui.material.texture = texture_id

	// quad.frag samples u * viewport[2] - viewport[0]; {-1, 0, -1, 1} gives 1 - u.
	ui.material.texture_viewport = mirror ? [4]f32{-1.0, 0.0, -1.0, 1.0} : [4]f32{0.0, 0.0, 1.0, 1.0}

	ui.material.border_bottom_left_radius = 0.0
	ui.material.border_bottom_right_radius = 0.0
	ui.material.border_top_left_radius = 0.0
	ui.material.border_top_right_radius = 0.0

	ui.material.r_clip = 0.0

	if g_active_shader != ui.material.base.program {
		gl.UseProgram(ui.material.base.program)
		g_active_shader = ui.material.base.program
	}

	material_update_uniforms(&ui.material.base)

	ui_fill_rect_(ui, ui.material.base.program, x, y, width, height)
}

ui_draw_image_rounded :: proc(ui: ^UI, texture_id: u32, x, y, width, height, radius: f32) {
	ui.material.color = shared.Vec4{1.0, 1.0, 1.0, 1.0}
	ui.material.texture = texture_id

	ui.material.texture_viewport = [4]f32{0.0, 0.0, 1.0, 1.0}

	radius_mlt := radius / min(width, height)

	ui.material.aspect = width / height
	ui.material.border_bottom_left_radius = radius_mlt
	ui.material.border_bottom_right_radius = radius_mlt
	ui.material.border_top_left_radius = radius_mlt
	ui.material.border_top_right_radius = radius_mlt

	ui.material.r_clip = 0.0

	if g_active_shader != ui.material.base.program {
		gl.UseProgram(ui.material.base.program)
		g_active_shader = ui.material.base.program
	}

	material_update_uniforms(&ui.material.base)

	ui_fill_rect_(ui, ui.material.base.program, x, y, width, height)
}

ui_measure_text :: proc(ui: ^UI, text: string, size: f32) -> f32 {
	width: f32 = 0
	previous: rune

	for c in text {
		glyph := load_glyph_rune(c)
		if glyph == nil {
			continue
		}

		width += ui_text_kerning(previous, c, size) + glyph.advance * size / 100.0
		previous = c
	}

	return width
}

ui_text_kerning :: proc(previous, current: rune, size: f32) -> f32 {
	if previous == 0 || !g_font_loaded { return 0 }
	kern: i32
	if previous > 0 && previous < 128 && current >= 0 && current < 128 {
		slot := g_font_slot
		if !g_kern_cacheds[slot][previous][current] {
			g_kern_caches[slot][previous][current] = i32(stbtt.GetCodepointKernAdvance(&g_font_info, previous, current))
			g_kern_cacheds[slot][previous][current] = true
		}
		kern = g_kern_caches[slot][previous][current]
	} else {
		kern = i32(stbtt.GetCodepointKernAdvance(&g_font_info, previous, current))
	}
	// Same float division as stbtt.ScaleForPixelHeight, without the call.
	return f32(kern) * (size / g_font_height_units)
}

ui_fill_text :: proc(ui: ^UI, color: shared.Vec4, text: string, x, y, size: f32) -> f32 {
	start_x := x
	cursor_x := x
	previous: rune

	ui.text_material.color = color
	gl.BindVertexArray(ui.vao)

	if g_active_shader != ui.text_material.base.program {
		gl.UseProgram(ui.text_material.base.program)
		g_active_shader = ui.text_material.base.program
	}

	for c in text {
		glyph := load_glyph_rune(c)

		if glyph == nil {
			continue
		}

		cursor_x += ui_text_kerning(previous, c, size)
		if c != ' ' {
			ui.text_material.texture = glyph.texture
			material_update_uniforms(&ui.text_material.base)

			glyph_y := y - glyph.h_bearing.y * size / 100.0
			ui_fill_rect_(ui, ui.text_material.base.program, cursor_x + glyph.h_bearing.x * size / 100.0, glyph_y, glyph.size.x * size / 100.0, glyph.size.y * size / 100.0)
		}

		cursor_x += glyph.advance * size / 100.0
		previous = c
	}

	return cursor_x - start_x
}

ui_fini :: proc(ui: ^UI) {
	if ui == nil {
		return
	}
	// Free both fonts' glyphs (the inactive font's file stays loaded).
	for slot in Font_Slot {
		for glyph in g_glyph_caches[slot] {
			if glyph == nil { continue }
			if glyph.texture != 0 { gl.DeleteTextures(1, &glyph.texture) }
			free(glyph)
		}
		g_glyph_caches[slot] = {}
		for _, glyph in g_glyph_extras[slot] {
			if glyph.texture != 0 { gl.DeleteTextures(1, &glyph.texture) }
			free(glyph)
		}
		clear(&g_glyph_extras[slot])
		g_kern_cacheds[slot] = {}
	}

	if ui.vao != 0 {
		gl.DeleteVertexArrays(1, &ui.vao)
	}
	if ui.vbo != 0 {
		gl.DeleteBuffers(1, &ui.vbo)
	}
	if ui.poly_vao != 0 { gl.DeleteVertexArrays(1, &ui.poly_vao) }
	if ui.poly_vbo != 0 { gl.DeleteBuffers(1, &ui.poly_vbo) }
	if ui.vignette != 0 { gl.DeleteTextures(1, &ui.vignette) }
	material_fini(&ui.material.base)
	material_fini(&ui.text_material.base)
	delete(g_font_data)
	g_font_data = nil
	g_font_loaded = false
	free(ui)
}
