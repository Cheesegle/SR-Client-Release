package main

// The interface renderer: every ui_* call appends an element to one draw list
// (g_ui_batch), and ui_flush draws the list with the ui shader (ui.vert,
// ui.frag), one draw per run of elements that share a texture and clip.
// Flushes happen at the GPU layer's boundaries (gpu_flush_deferred: the next
// world pass, target change, readback or present); code that reads pixels or
// draws behind the GPU layer calls ui_flush first. Glyphs come from one R8
// atlas instead of a texture each.

import "core:fmt"
import "core:math"
import "core:slice"
import core_c "core:c"
import stbtt "vendor:stb/truetype"
import shared "../shared"
import clay "../third_party/clay"

g_font_info: stbtt.fontinfo
g_font_loaded: bool
g_font_data: []byte
// ascent - descent: stbtt.ScaleForPixelHeight(size) is size / g_font_height_units.
g_font_height_units: f32
// Kerning in font units for ASCII pairs, filled on first use (per font).
g_kern_caches: [Font_Slot][128][128]i32
g_kern_cacheds: [Font_Slot][128][128]bool

// The interface program, shared by every UI (resource_cache_fini frees it).
g_ui_program: Gpu_Program

UI_Kind :: enum u8 {
	Textured = 0, // texture * color, rounded corners, stroke, r_clip
	Glyph    = 1, // atlas coverage * color
	Solid    = 2, // color only: never breaks a run on its texture
}

// One corner of an element; the element's values repeat on its corners.
UI_Vertex :: struct {
	position: [2]f32, // clip space
	local:    [2]f32, // 0..1 across the element, y up
	uv:       [2]f32,
	color:    [4]f32,
	radii:    [4]f32, // bottom left, bottom right, top left, top right
	params:   [4]f32, // aspect, r_clip, stroke width, kind
}
#assert(size_of(UI_Vertex) == 72)

// A run of indices drawn with one texture and clip.
UI_Command :: struct {
	texture: Gpu_Texture, // 0 while the run is only solid elements
	clip_on: bool,
	clip:    [4]i32, // glScissor convention: x, y from the bottom, width, height
	first:   u32,
	count:   u32,
}

// Flushed early past this many vertices, so one flush always fits the
// transient rings.
UI_BATCH_MAX_VERTICES :: 32768

g_ui_batch: struct {
	vertices: [dynamic]UI_Vertex,
	indices:  [dynamic]u32,
	commands: [dynamic]UI_Command,
	clip_on:  bool,
	clip:     [4]i32,
}

// Glyph bitmaps, packed in shelves. Each cell has a one-texel border copied
// from the glyph's edge, so linear filtering at the glyph's edge reads what
// clamp-to-edge did with a texture per glyph.
UI_ATLAS_SIZE :: 2048

g_glyph_atlas: struct {
	texture: Gpu_Texture,
	x, y:    i32, // next free cell
	row:     i32, // height of the current shelf
}

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

// Copies a w x h coverage bitmap into the atlas; `texel` is its top-left
// texel there. A full atlas is emptied (glyphs then reload on use).
@(private = "file")
ui_atlas_insert :: proc(bitmap: []u8, w, h: i32) -> (texel: [2]i32, ok: bool) {
	atlas := &g_glyph_atlas
	cw, ch := w + 2, h + 2
	if cw > UI_ATLAS_SIZE || ch > UI_ATLAS_SIZE { return }
	if atlas.texture == 0 {
		atlas.texture = gpu_texture_create({width = UI_ATLAS_SIZE, height = UI_ATLAS_SIZE, format = .R8, sampler = GPU_SAMPLER_UI_LINEAR})
		if atlas.texture == 0 { return }
	}
	if atlas.x + cw > UI_ATLAS_SIZE { atlas.x, atlas.y, atlas.row = 0, atlas.y + atlas.row, 0 }
	if atlas.y + ch > UI_ATLAS_SIZE {
		fmt.eprintln("[UI] Glyph atlas full; rebuilding it")
		ui_flush() // queued text still reads the old cells
		ui_glyph_caches_free()
		atlas.x, atlas.y, atlas.row = 0, 0, 0
	}
	cell := make([]u8, int(cw) * int(ch), context.temp_allocator)
	for row in 0 ..< ch {
		src_row := clamp(row - 1, 0, h - 1)
		for col in 0 ..< cw {
			cell[int(row) * int(cw) + int(col)] = bitmap[int(src_row) * int(w) + int(clamp(col - 1, 0, w - 1))]
		}
	}
	gpu_texture_update(atlas.texture, .R8, atlas.x, atlas.y, cw, ch, cell)
	texel = {atlas.x + 1, atlas.y + 1}
	atlas.x += cw
	atlas.row = max(atlas.row, ch)
	return texel, true
}

// Forgets every cached glyph of both fonts (their atlas cells are reused).
ui_glyph_caches_free :: proc() {
	g_ui_record_generation += 1 // recorded glyph cells are reused
	for slot in Font_Slot {
		for &glyph in g_glyph_caches[slot] { if glyph != nil { free(glyph); glyph = nil } }
		for _, glyph in g_glyph_extras[slot] { free(glyph) }
		clear(&g_glyph_extras[slot])
	}
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

	// Font is loaded lazily from assets (matches C's freetype usage).
	if !g_font_loaded {
		load_font()
	}

	if !g_font_loaded {
		return nil
	}

	info := from != nil ? from : &g_font_info
	scale := stbtt.ScaleForPixelHeight(info, 100)
	advance_width, left_side_bearing: core_c.int
	stbtt.GetCodepointHMetrics(info, c, &advance_width, &left_side_bearing)

	width, height, xoff, yoff: core_c.int
	bitmap := stbtt.GetCodepointBitmap(info, scale, scale, c, &width, &height, &xoff, &yoff)

	glyph := new(Glyph_Cache_Entry)
	if bitmap != nil && width > 0 && height > 0 {
		// Grayscale coverage, filtered linearly: that preserves edge coverage
		// when the 100 px raster is scaled to UI size, where nearest filtering
		// makes every menu and HUD character look jagged.
		glyph.atlas, glyph.in_atlas = ui_atlas_insert(bitmap[:int(width) * int(height)], width, height)
		stbtt.FreeBitmap(bitmap, nil)
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
	if g_ui_program == 0 { g_ui_program = gpu_program_create_ui() }
	g_gpu_deferred.flush = ui_flush
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
}

// The run the next element joins: the last one when its clip matches and its
// texture does (solid elements match any texture), else a new one.
@(private = "file")
ui_batch_command :: proc(texture: Gpu_Texture) -> ^UI_Command {
	b := &g_ui_batch
	if n := len(b.commands); n > 0 {
		last := &b.commands[n - 1]
		same_clip := last.clip_on == b.clip_on && (!b.clip_on || last.clip == b.clip)
		if same_clip && (texture == 0 || last.texture == 0 || last.texture == texture) {
			if last.texture == 0 { last.texture = texture }
			return last
		}
	}
	append(&b.commands, UI_Command{texture = texture, clip_on = b.clip_on, clip = b.clip, first = u32(len(b.indices))})
	return &b.commands[len(b.commands) - 1]
}

// Appends a box (x, y: top-left in UI pixels). `uv` maps local (0,0) and (1,1)
// to texture coordinates: uv[0] + local * uv[1].
@(private = "file")
ui_box :: proc(ui: ^UI, kind: UI_Kind, texture: Gpu_Texture, x, y, width, height: f32, color: shared.Vec4, radius: f32 = 0, aspect: f32 = 1, r_clip: f32 = 0, stroke: f32 = 0, uv := [2][2]f32{{0, 0}, {1, 1}}) {
	ui_box_radii(ui, kind, texture, x, y, width, height, color, {radius, radius, radius, radius}, aspect, r_clip, stroke, uv)
}

// ui_box with a radius per corner: bottom-left, bottom-right, top-left,
// top-right (in units of the shorter side, like ui_box's radius).
ui_box_radii :: proc(ui: ^UI, kind: UI_Kind, texture: Gpu_Texture, x, y, width, height: f32, color: shared.Vec4, radii: [4]f32, aspect: f32 = 1, r_clip: f32 = 0, stroke: f32 = 0, uv := [2][2]f32{{0, 0}, {1, 1}}) {
	// A minimized window (0x0) or a NaN layout box would send NaN/Inf vertex
	// positions to the driver; draw nothing instead.
	finite :: proc(value: f32) -> bool { return !math.is_nan(value) && !math.is_inf(value) }
	if !(ui.width > 0 && ui.height > 0) || !finite(x) || !finite(y) || !finite(width) || !finite(height) {
		return
	}
	if len(g_ui_batch.vertices) + 4 > UI_BATCH_MAX_VERTICES { ui_flush() }
	offset_x := (x + width * 0.5) / ui.width * 2.0 - 1.0
	offset_y := 1.0 - (y + height * 0.5) / ui.height * 2.0
	scale_x := width / ui.width
	scale_y := height / ui.height

	command := ui_batch_command(kind == .Solid ? 0 : texture)
	base := u32(len(g_ui_batch.vertices))
	params := [4]f32{aspect, r_clip, stroke, f32(kind)}
	corners := [4][2]f32{{-1, -1}, {1, -1}, {1, 1}, {-1, 1}}
	for corner in corners {
		local := [2]f32{(corner.x + 1) * 0.5, (corner.y + 1) * 0.5}
		append(&g_ui_batch.vertices, UI_Vertex{
			position = {corner.x * scale_x + offset_x, corner.y * scale_y + offset_y},
			local    = local,
			uv       = uv[0] + local * uv[1],
			color    = color,
			radii    = radii,
			params   = params,
		})
	}
	append(&g_ui_batch.indices, base, base + 1, base + 2, base, base + 2, base + 3)
	command.count += 6
}

ui_fill_rect :: proc(ui: ^UI, color: shared.Vec4, x, y, width, height: f32) {
	ui_box(ui, .Solid, 0, x, y, width, height, color)
}

// A convex (or center-visible) polygon in screen pixels, drawn as a triangle
// fan with the flat UI color. Used for rotated HUD shapes such as hitmarkers.
UI_POLYGON_MAX :: 64
ui_fill_polygon :: proc(ui: ^UI, color: shared.Vec4, points: []shared.Vec2) {
	if len(points) < 3 || len(points) > UI_POLYGON_MAX || !(ui.width > 0 && ui.height > 0) { return }
	for p in points {
		if math.is_nan(p.x) || math.is_nan(p.y) || math.is_inf(p.x) || math.is_inf(p.y) { return }
	}
	if len(g_ui_batch.vertices) + len(points) > UI_BATCH_MAX_VERTICES { ui_flush() }
	command := ui_batch_command(0)
	base := u32(len(g_ui_batch.vertices))
	for p in points {
		// The centered local coordinate never reaches the rounded-corner path.
		append(&g_ui_batch.vertices, UI_Vertex{
			position = {p.x / ui.width * 2 - 1, 1 - p.y / ui.height * 2},
			local = {0.5, 0.5}, uv = {0.5, 0.5}, color = color, params = {1, 0, 0, f32(UI_Kind.Solid)},
		})
	}
	for i in 1 ..< u32(len(points)) - 1 {
		append(&g_ui_batch.indices, base, base + i, base + i + 1)
	}
	command.count += u32(len(points) - 2) * 3
}

ui_round_rect :: proc(ui: ^UI, color: shared.Vec4, x, y, width, height, radius: f32) {
	ui_box(ui, .Solid, 0, x, y, width, height, color, radius / min(width, height), width / height)
}

// A rectangle with only its top corners rounded (border-radius: r r 0 0).
ui_round_rect_top :: proc(ui: ^UI, color: shared.Vec4, x, y, width, height, radius: f32) {
	r := radius / min(width, height)
	ui_box_radii(ui, .Solid, 0, x, y, width, height, color, {0, 0, r, r}, width / height)
}

ui_fill_rect_rclip :: proc(ui: ^UI, color: shared.Vec4, x, y, width, height, radius, r_clip: f32) {
	ui_box(ui, .Solid, 0, x, y, width, height, color, radius / min(width, height), width / height, r_clip)
}

ui_stroke_round_rect :: proc(ui: ^UI, color: shared.Vec4, x, y, width, height, radius, thickness: f32) {
	ui_box(ui, .Solid, 0, x, y, width, height, color, radius / min(width, height), width / height, 0, thickness / min(width, height))
}

// mirror flips the image horizontally (CSS transform: scaleX(-1)).
ui_draw_image :: proc(ui: ^UI, texture_id: Gpu_Texture, x, y, width, height: f32, color := shared.Vec4{1.0, 1.0, 1.0, 1.0}, mirror := false) {
	texture := texture_id != 0 ? texture_id : gpu_blank_texture()
	uv := mirror ? [2][2]f32{{1, 0}, {-1, 1}} : [2][2]f32{{0, 0}, {1, 1}}
	ui_box(ui, .Textured, texture, x, y, width, height, color, uv = uv)
}

ui_draw_image_rounded :: proc(ui: ^UI, texture_id: Gpu_Texture, x, y, width, height, radius: f32) {
	texture := texture_id != 0 ? texture_id : gpu_blank_texture()
	ui_box(ui, .Textured, texture, x, y, width, height, {1, 1, 1, 1}, radius / min(width, height), width / height)
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
	inv := f32(1) / UI_ATLAS_SIZE

	for c in text {
		glyph := load_glyph_rune(c)

		if glyph == nil {
			continue
		}

		cursor_x += ui_text_kerning(previous, c, size)
		if c != ' ' && glyph.in_atlas {
			// Local y runs up the glyph while atlas rows run down it.
			uv := [2][2]f32{
				{f32(glyph.atlas.x) * inv, (f32(glyph.atlas.y) + glyph.size.y) * inv},
				{glyph.size.x * inv, -glyph.size.y * inv},
			}
			glyph_y := y - glyph.h_bearing.y * size / 100.0
			ui_box(ui, .Glyph, g_glyph_atlas.texture, cursor_x + glyph.h_bearing.x * size / 100.0, glyph_y, glyph.size.x * size / 100.0, glyph.size.y * size / 100.0, color, uv = uv)
		}

		cursor_x += glyph.advance * size / 100.0
		previous = c
	}

	return cursor_x - start_x
}

// Clips later UI elements to `box` (UI pixels, top-left origin) until
// ui_clip_clear. An empty or invalid box clips everything away (glScissor
// rejects negative sizes and NaN converts to INT_MIN).
ui_clip_set :: proc(ui: ^UI, box: clay.BoundingBox) {
	finite :: proc(value: f32) -> f32 { return math.is_nan(value) || math.is_inf(value) ? 0 : value }
	x, y := finite(box.x), finite(ui.height - box.y - box.height)
	width, height := max(finite(box.width), 0), max(finite(box.height), 0)
	g_ui_batch.clip_on = true
	g_ui_batch.clip = {i32(clamp(x, -65536, 65536)), i32(clamp(y, -65536, 65536)), i32(min(width, 65536)), i32(min(height, 65536))}
}

ui_clip_clear :: proc(ui: ^UI) {
	g_ui_batch.clip_on = false
}

// Draws the queued elements and empties the list. The GPU layer calls it
// before its next pass boundary; raw GL code (tests) calls it before reading
// pixels or clearing.
ui_flush :: proc() {
	b := &g_ui_batch
	g_ui_flushes += 1
	defer {
		clear(&b.vertices)
		clear(&b.indices)
		clear(&b.commands)
	}
	if len(b.indices) == 0 { return }
	if g_ui_program == 0 { return }
	// Its own draws are not a boundary.
	busy := g_gpu_deferred.busy
	g_gpu_deferred.busy = true
	defer g_gpu_deferred.busy = busy
	// A known state whatever ran before (world passes, raw GL in tests), then
	// the interface's: blended, no depth test or writes.
	gpu_draw_state_reset()
	if !gpu_transient_bind(.UI, slice.to_bytes(b.vertices[:]), b.indices[:]) { return }
	gpu_program_bind(g_ui_program)
	gpu_draw_state_set({blend = true, depth_test = .Off})
	for command in b.commands {
		if command.count == 0 { continue }
		gpu_bind_color_texture(command.texture)
		gpu_scissor(command.clip_on, command.clip)
		gpu_draw_indexed(i32(command.count), command.first)
		g_draw_calls += 1
	}
	gpu_scissor(false)
}

// ------------------------------------------------------------ recording
//
// A recording keeps the boxes a block of UI code queued (its vertices, indices
// and runs) so a later frame can queue the same boxes again without building
// them: ui_record_begin, the drawing code, ui_record_end; then ui_record_replay.
// A recording is dropped if the list was flushed in between (it is incomplete)
// or the glyph atlas was rebuilt or icons released since (g_ui_record_generation).

g_ui_flushes: u64
g_ui_record_generation: u32

UI_Recording :: struct {
	vertices:   [dynamic]UI_Vertex,
	indices:    [dynamic]u32,
	commands:   [dynamic]UI_Command,
	generation: u32,
	valid:      bool,
	// While recording: where the block started.
	start_vertex, start_index, start_command: int,
	start_flushes: u64,
	start_clip_on: bool,
	start_clip:    [4]i32,
}

// A new run starts at the block (an empty run the block's first box joins), so
// none of its boxes merge into a run queued before it.
@(private = "file")
ui_record_break :: proc() {
	b := &g_ui_batch
	append(&b.commands, UI_Command{clip_on = b.clip_on, clip = b.clip, first = u32(len(b.indices))})
}

ui_record_begin :: proc(r: ^UI_Recording) {
	b := &g_ui_batch
	r.valid = false
	ui_record_break()
	r.start_vertex, r.start_index, r.start_command = len(b.vertices), len(b.indices), len(b.commands) - 1
	r.start_flushes, r.start_clip_on, r.start_clip = g_ui_flushes, b.clip_on, b.clip
}

ui_record_end :: proc(r: ^UI_Recording) {
	b := &g_ui_batch
	clear(&r.vertices); clear(&r.indices); clear(&r.commands)
	if g_ui_flushes != r.start_flushes || b.clip_on != r.start_clip_on || b.clip != r.start_clip { return }
	append(&r.vertices, ..b.vertices[r.start_vertex:])
	base := u32(r.start_vertex)
	for index in b.indices[r.start_index:] { append(&r.indices, index - base) }
	first := u32(r.start_index)
	for command in b.commands[r.start_command:] {
		c := command
		c.first -= first
		append(&r.commands, c)
	}
	r.generation, r.valid = g_ui_record_generation, true
}

ui_record_usable :: proc(r: ^UI_Recording) -> bool {
	b := &g_ui_batch
	return r.valid && r.generation == g_ui_record_generation && len(r.vertices) <= UI_BATCH_MAX_VERTICES &&
		b.clip_on == r.start_clip_on && (!b.clip_on || b.clip == r.start_clip)
}

ui_record_replay :: proc(r: ^UI_Recording) {
	b := &g_ui_batch
	if len(b.vertices) + len(r.vertices) > UI_BATCH_MAX_VERTICES { ui_flush() }
	base_vertex, base_index := u32(len(b.vertices)), u32(len(b.indices))
	append(&b.vertices, ..r.vertices[:])
	old_indices, old_commands := len(b.indices), len(b.commands)
	resize(&b.indices, old_indices + len(r.indices))
	for index, i in r.indices { b.indices[old_indices + i] = index + base_vertex }
	resize(&b.commands, old_commands + len(r.commands))
	for command, i in r.commands {
		c := command
		c.first += base_index
		b.commands[old_commands + i] = c
	}
}

ui_record_free :: proc(r: ^UI_Recording) {
	delete(r.vertices); delete(r.indices); delete(r.commands)
	r^ = {}
}

ui_fini :: proc(ui: ^UI) {
	if ui == nil {
		return
	}
	// Free both fonts' glyphs (the inactive font's file stays loaded).
	ui_glyph_caches_free()
	for slot in Font_Slot { delete(g_glyph_extras[slot]); g_glyph_extras[slot] = nil; g_kern_cacheds[slot] = {} }
	// Elements queued for this UI are dropped with it.
	delete(g_ui_batch.vertices)
	delete(g_ui_batch.indices)
	delete(g_ui_batch.commands)
	g_ui_batch = {}
	gpu_texture_destroy(&g_glyph_atlas.texture)
	g_glyph_atlas = {}
	gpu_texture_destroy(&ui.vignette)
	delete(g_font_data)
	g_font_data = nil
	g_font_loaded = false
	free(ui)
}
