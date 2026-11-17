package main

import "core:encoding/json"
import "core:fmt"
import "core:math"
import gl "vendor:OpenGL"
import glfw "vendor:glfw"
import mu "vendor:microui"
import menuui "../menu"
import clay "../third_party/clay"
import shared "../shared"

// The "Debug" window: a vendor:microui context drawn with the HUD's own
// rect and Rajdhani text helpers. It is built before the menu (so it can claim
// clicks over it) and drawn after everything else. While gameplay owns the
// cursor it receives no input at all and is display-only.

DEBUG_WINDOW_TITLE :: "Debug"
DEBUG_UI_OFFSCREEN :: -100_000

// microui passes Font through its commands untouched; ours carries the size.
Debug_Font :: struct {
	dbg: ^Debug_UI,
	size: f32,
}

Debug_UI :: struct {
	ctx: mu.Context,
	ui: ^UI,
	// Text measurement, ui_measure_text by default (tests replace it).
	measure: proc(ui: ^UI, text: string, size: f32) -> f32,
	font, small_font: Debug_Font,
	scale: f32,
	width, height: f32, // Framebuffer size of the current frame.
	buttons: mu.Mouse_Set,
	keys: mu.Key_Set,
	pointer_captured: bool,
	window_screen_w: i32, // Screen width the window position belongs to.
}

// One frame of input, in framebuffer pixels. A locked cursor means gameplay.
Debug_UI_Input :: struct {
	locked: bool,
	pointer: [2]f32,
	buttons: mu.Mouse_Set,
	scroll: [2]f32, // GLFW scroll offsets (positive y scrolls up).
	keys: mu.Key_Set,
	text: string,
}

Debug_UI_Draw_Counts :: struct {
	rects, texts, icons, clips: int,
	min_x, min_y, max_x, max_y: i32, // Bounds of everything drawn.
}

debug_ui_text_width :: proc(font: mu.Font, str: string) -> i32 {
	f := cast(^Debug_Font)font
	return i32(math.ceil(f.dbg.measure(f.dbg.ui, str, f.size)))
}

debug_ui_text_height :: proc(font: mu.Font) -> i32 {
	return i32(math.ceil((cast(^Debug_Font)font).size))
}

debug_ui_create :: proc(ui: ^UI) -> ^Debug_UI {
	dbg := new(Debug_UI)
	mu.init(&dbg.ctx)
	dbg.ctx.text_width, dbg.ctx.text_height = debug_ui_text_width, debug_ui_text_height
	dbg.ui, dbg.measure = ui, ui_measure_text
	dbg.font.dbg, dbg.small_font.dbg = dbg, dbg
	debug_ui_layout(dbg, 1280, 720)
	return dbg
}

debug_ui_fini :: proc(client: ^Client) {
	perf_gpu_fini(&client.perf)
	free(client.debug_ui)
	client.debug_ui = nil
}

// Sizes follow the framebuffer: 1.0 up to 1080p, larger on bigger screens.
debug_ui_layout :: proc(dbg: ^Debug_UI, width, height: f32) {
	dbg.width, dbg.height = width, height
	dbg.scale = max(1, min(width/1920, height/1080))
	s := dbg.scale
	dbg.font.size = math.round(19*s)
	dbg.small_font.size = math.round(14*s)
	style := &dbg.ctx._style
	style^ = mu.default_style
	style.font = mu.Font(&dbg.font)
	style.padding, style.spacing, style.indent = i32(5*s), i32(3*s), i32(18*s)
	style.size = {i32(68*s), i32(dbg.font.size) - style.padding}
	style.title_height = i32(dbg.font.size + 10*s)
	style.colors[.TEXT] = {225, 228, 235, 255}
	style.colors[.BORDER] = {70, 74, 84, 200}
	style.colors[.WINDOW_BG] = {16, 18, 22, 215}
	style.colors[.TITLE_BG] = {8, 9, 12, 240}
	style.colors[.BUTTON] = {34, 38, 46, 230}
	style.colors[.BUTTON_HOVER] = {46, 52, 62, 240}
	style.colors[.BUTTON_FOCUS] = {58, 64, 76, 250}
}

// Feeds one frame of input. Gameplay (a locked cursor) feeds nothing: held
// buttons and keys are released and the pointer is parked off-screen so the
// window neither hovers nor drags, and every gameplay input stays untouched.
debug_ui_feed :: proc(dbg: ^Debug_UI, input: Debug_UI_Input) {
	ctx := &dbg.ctx
	if input.locked {
		for button in dbg.buttons { mu.input_mouse_up(ctx, DEBUG_UI_OFFSCREEN, DEBUG_UI_OFFSCREEN, button) }
		for key in dbg.keys { mu.input_key_up(ctx, key) }
		dbg.buttons, dbg.keys = {}, {}
		mu.input_mouse_move(ctx, DEBUG_UI_OFFSCREEN, DEBUG_UI_OFFSCREEN)
		return
	}
	x, y := i32(input.pointer.x), i32(input.pointer.y)
	mu.input_mouse_move(ctx, x, y)
	for button in mu.Mouse {
		if button in input.buttons && button not_in dbg.buttons { mu.input_mouse_down(ctx, x, y, button) }
		if button not_in input.buttons && button in dbg.buttons { mu.input_mouse_up(ctx, x, y, button) }
	}
	dbg.buttons = input.buttons
	if input.scroll != {} { mu.input_scroll(ctx, i32(-input.scroll.x*30*dbg.scale), i32(-input.scroll.y*30*dbg.scale)) }
	for key in mu.Key {
		if key in input.keys && key not_in dbg.keys { mu.input_key_down(ctx, key) }
		if key not_in input.keys && key in dbg.keys { mu.input_key_up(ctx, key) }
	}
	dbg.keys = input.keys
	if len(input.text) > 0 { mu.input_text(ctx, input.text) }
}

debug_ui_read_input :: proc(client: ^Client) -> (input: Debug_UI_Input) {
	input.locked = client.mouse_state.locked
	if input.locked { return }
	width, height := glfw.GetWindowSize(client.window)
	x, y := glfw.GetCursorPos(client.window)
	input.pointer = {f32(x) * client.ui.width / f32(max(width, 1)), f32(y) * client.ui.height / f32(max(height, 1))}
	button_codes := [mu.Mouse]i32{.LEFT = glfw.MOUSE_BUTTON_LEFT, .RIGHT = glfw.MOUSE_BUTTON_RIGHT, .MIDDLE = glfw.MOUSE_BUTTON_MIDDLE}
	for code, button in button_codes { if glfw.GetMouseButton(client.window, code) == glfw.PRESS { input.buttons += {button} } }
	input.scroll = {client.menu_scroll.x, client.menu_scroll.y}
	key_codes := [mu.Key][2]i32{
		.SHIFT = {glfw.KEY_LEFT_SHIFT, glfw.KEY_RIGHT_SHIFT}, .CTRL = {glfw.KEY_LEFT_CONTROL, glfw.KEY_RIGHT_CONTROL}, .ALT = {glfw.KEY_LEFT_ALT, glfw.KEY_RIGHT_ALT},
		.BACKSPACE = {glfw.KEY_BACKSPACE, 0}, .DELETE = {glfw.KEY_DELETE, 0}, .RETURN = {glfw.KEY_ENTER, glfw.KEY_KP_ENTER},
		.LEFT = {glfw.KEY_LEFT, 0}, .RIGHT = {glfw.KEY_RIGHT, 0}, .HOME = {glfw.KEY_HOME, 0}, .END = {glfw.KEY_END, 0},
		.A = {glfw.KEY_A, 0}, .X = {glfw.KEY_X, 0}, .C = {glfw.KEY_C, 0}, .V = {glfw.KEY_V, 0},
	}
	for codes, key in key_codes {
		for code in codes { if code != 0 && glfw.GetKey(client.window, code) == glfw.PRESS { input.keys += {key} } }
	}
	input.text = string(client.menu_text[:client.menu_text_length])
	return
}

// Builds the window for this frame. Returns true while the pointer is over a
// microui window (or dragging one): the menu must then ignore it.
debug_ui_build :: proc(client: ^Client, dbg: ^Debug_UI) -> bool {
	ctx := &dbg.ctx
	mu.begin(ctx)
	debug_ui_window(client, dbg)
	mu.end(ctx)
	// next_hover_root is the window under this frame's pointer (it becomes
	// ctx.hover_root on the next begin); focus with a held button is a drag.
	dbg.pointer_captured = ctx.next_hover_root != nil || ctx.focus_id != 0 && ctx.mouse_down_bits != {}
	return dbg.pointer_captured
}

debug_ui_window_open :: proc(dbg: ^Debug_UI) -> bool {
	cnt := mu.get_container(&dbg.ctx, DEBUG_WINDOW_TITLE)
	return cnt != nil && bool(cnt.open)
}

// Input, layout and window build for this frame (the window is drawn later by
// debug_ui_render). Returns whether the menu must ignore the pointer.
debug_ui_update :: proc(client: ^Client) -> bool {
	if client.debug_ui == nil { client.debug_ui = debug_ui_create(client.ui) }
	dbg := client.debug_ui
	dbg.ui = client.ui
	debug_ui_layout(dbg, client.ui.width, client.ui.height)
	debug_ui_feed(dbg, debug_ui_read_input(client))
	captured := debug_ui_build(client, dbg)
	// The title bar's close button turns the overlay off like the key bind.
	if !debug_ui_window_open(dbg) {
		perf_overlay_set(client, false)
		client.settings_dirty = true
	}
	return captured
}

// Clicks, scroll and mouse binds over the debug window stay out of the menu.
debug_ui_block_menu_input :: proc(input: ^menuui.Input) {
	input.pointer = {DEBUG_UI_OFFSCREEN, DEBUG_UI_OFFSCREEN}
	input.down, input.right_down = false, false
	input.scroll = {}
	if input.binding_pressed < 0 { input.binding_pressed = 0 }
}

debug_ui_map_name :: proc(client: ^Client) -> string {
	if client.game.map_inst != nil {
		if root, ok := client.game.map_inst.raw_data.(json.Object); ok {
			if name, valid := root["name"].(json.String); valid { return string(name) }
		}
	}
	if len(g_map_name) > 0 { return g_map_name }
	return "-"
}

debug_ui_value :: proc(ctx: ^mu.Context, text: string, color: mu.Color) {
	r := mu.layout_next(ctx)
	font := ctx.style.font
	mu.draw_text(ctx, font, text, {r.x + ctx.style.padding, r.y + (r.h - ctx.text_height(font))/2}, color)
}

// One fixed-width stat cell: an optional caption ("avg", "max") pinned to the
// left and the number right-aligned, so changing digits never shift other cells.
debug_ui_cell :: proc(ctx: ^mu.Context, caption, value: string, color, caption_color: mu.Color) {
	r := mu.layout_next(ctx)
	font := ctx.style.font
	y := r.y + (r.h - ctx.text_height(font))/2
	if len(caption) > 0 { mu.draw_text(ctx, font, caption, {r.x + ctx.style.padding, y}, caption_color) }
	mu.draw_text(ctx, font, value, {r.x + r.w - ctx.style.padding - ctx.text_width(font, value), y}, color)
}

// Label column plus three equal value columns spanning the window body.
debug_ui_stat_columns :: proc(ctx: ^mu.Context, label_width: i32) {
	body := mu.get_current_container(ctx).body
	available := body.w - label_width - ctx.style.padding*2 - ctx.style.spacing*3
	column := max(available/3, 1)
	mu.layout_row(ctx, {label_width, column, column, -1})
}

debug_ui_window :: proc(client: ^Client, dbg: ^Debug_UI) {
	ctx := &dbg.ctx
	s := dbg.scale
	width, margin := i32(340*s), i32(12*s)
	screen_w, screen_h := i32(dbg.width), i32(dbg.height)
	cnt := mu.get_container(ctx, DEBUG_WINDOW_TITLE)
	cnt.open = true // The overlay toggle is the source of truth.
	// Keep the distance to the right edge across resolution changes so the
	// window stays top-right (or wherever it was dragged, relative to it).
	if dbg.window_screen_w != 0 && dbg.window_screen_w != screen_w { cnt.rect.x += screen_w - dbg.window_screen_w }
	dbg.window_screen_w = screen_w
	if cnt.rect.w != width { // First open or a new screen scale: top-right.
		cnt.rect = {screen_w - width - margin, margin, width, i32(420*s)}
	}
	cnt.rect.x = clamp(cnt.rect.x, 0, max(0, screen_w - cnt.rect.w))
	cnt.rect.y = clamp(cnt.rect.y, 0, max(0, screen_h - cnt.rect.h))
	if !mu.begin_window(ctx, DEBUG_WINDOW_TITLE, cnt.rect, {.NO_RESIZE, .NO_SCROLL}) { return }
	debug_ui_performance(client, dbg)
	debug_ui_rendering(client, dbg)
	mu.end_window(ctx)
	// Fit the height to this frame's content (collapsing the section shrinks
	// it); the width stays fixed. microui's AUTO_SIZE would also shrink width.
	cnt.rect.h = cnt.content_size.y + (cnt.rect.h - cnt.body.h) + ctx.style.padding*2
}

debug_ui_performance :: proc(client: ^Client, dbg: ^Debug_UI) {
	ctx := &dbg.ctx
	s := dbg.scale
	stats := &client.perf
	// The numbers come from the snapshot refreshed every PERF_TEXT_REFRESH_MS;
	// only the graph below reads every frame.
	if !stats.shown_valid { perf_refresh_shown(stats, true) }
	summary := stats.shown
	if .ACTIVE not_in mu.header(ctx, "Performance", {.EXPANDED}) { return }
	muted := mu.Color{150, 156, 168, 255}
	white := ctx.style.colors[.TEXT]
	level_color :: proc(level: Perf_Level) -> mu.Color { c := perf_level_color(level); return {c[0], c[1], c[2], c[3]} }
	label_width := i32(92*s)
	// Numbers sit in fixed columns: current | avg | max/1% low. Each value is
	// right-aligned in its own cell, so frequently changing digits never push
	// the averages around.
	debug_ui_stat_columns(ctx, label_width)
	mu.label(ctx, "FPS")
	if summary.frames == 0 {
		debug_ui_cell(ctx, "", "--", muted, muted)
		debug_ui_cell(ctx, "", "", muted, muted)
		debug_ui_cell(ctx, "", "", muted, muted)
	} else {
		fps_color := level_color(perf_frame_level(summary.frame_avg, 0))
		debug_ui_cell(ctx, "", fmt.tprintf("%.0f", summary.fps), fps_color, muted)
		debug_ui_cell(ctx, "avg", fmt.tprintf("%.0f", summary.fps_avg), fps_color, muted)
		debug_ui_cell(ctx, "1% low", fmt.tprintf("%.0f", summary.fps_low), fps_color, muted)
	}
	mu.label(ctx, "Frame ms")
	debug_ui_cell(ctx, "", fmt.tprintf("%.2f", summary.frame_ms), white, muted)
	debug_ui_cell(ctx, "avg", fmt.tprintf("%.2f", summary.frame_avg), white, muted)
	debug_ui_cell(ctx, "max", fmt.tprintf("%.2f", summary.frame_max), white, muted)
	mu.label(ctx, "CPU ms")
	debug_ui_cell(ctx, "", fmt.tprintf("%.2f", summary.cpu_ms), white, muted)
	debug_ui_cell(ctx, "avg", fmt.tprintf("%.2f", summary.cpu_avg), white, muted)
	debug_ui_cell(ctx, "max", fmt.tprintf("%.2f", summary.cpu_max), level_color(perf_frame_level(summary.cpu_max, 0)), muted)
	mu.label(ctx, "GPU ms")
	debug_ui_cell(ctx, "", stats.shown_gpu_valid ? fmt.tprintf("%.2f", stats.shown_gpu_ms) : "--", stats.shown_gpu_valid ? white : muted, muted)
	debug_ui_cell(ctx, "", "", white, muted)
	debug_ui_cell(ctx, "", "", white, muted)
	// Where the GPU time goes (gpu_pass_mark sections, smoothed).
	pass_labels := [Gpu_Pass]string{.Shadows = "  shadows", .World = "  world", .Viewmodel = "  viewmodel", .Resolve = "  MSAA resolve", .Interface = "  interface", .Present = "  present"}
	for ms, pass in stats.pass_ms {
		if ms <= 0 { continue }
		mu.label(ctx, pass_labels[pass])
		debug_ui_cell(ctx, "", fmt.tprintf("%.2f", ms), white, muted)
		debug_ui_cell(ctx, "", "", white, muted)
		debug_ui_cell(ctx, "", "", white, muted)
	}
	// The rest of each frame, outside CPU time: SwapBuffers (driver/compositor
	// present), event polling (window messages, raw mouse), and the remainder.
	// The max column is coloured so a spike points at its source.
	split_labels := [Perf_Split]string{.SWAP = "Swap ms", .EVENTS = "Events ms", .OTHER = "Other ms"}
	for part in Perf_Split {
		mu.label(ctx, split_labels[part])
		debug_ui_cell(ctx, "", fmt.tprintf("%.2f", summary.split_ms[part]), white, muted)
		debug_ui_cell(ctx, "avg", fmt.tprintf("%.2f", summary.split_avg[part]), white, muted)
		debug_ui_cell(ctx, "max", fmt.tprintf("%.2f", summary.split_max[part]), level_color(perf_frame_level(summary.split_max[part], 0)), muted)
	}
	// Total draws this frame (world, view model, HUD and menus), then the
	// world/view-model share and how map batching and culling handled it.
	world := stats.shown_world
	mu.label(ctx, "Draw calls")
	debug_ui_cell(ctx, "", fmt.tprintf("%d", stats.shown_draw_calls), white, muted)
	debug_ui_cell(ctx, "world", fmt.tprintf("%d", world.draw_calls), white, muted)
	debug_ui_cell(ctx, "", "", white, muted)
	mu.label(ctx, "Batches")
	if client.render_batching {
		debug_ui_cell(ctx, "", fmt.tprintf("%d", world.batch_draws), white, muted)
		debug_ui_cell(ctx, "culled", fmt.tprintf("%d", world.batches_culled), white, muted)
	} else {
		debug_ui_cell(ctx, "", "off", muted, muted)
		debug_ui_cell(ctx, "", "", white, muted)
	}
	debug_ui_cell(ctx, "", "", white, muted)
	mu.label(ctx, "Culled objs")
	debug_ui_cell(ctx, "", fmt.tprintf("%d", world.meshes_culled), white, muted)
	debug_ui_cell(ctx, "", "", white, muted)
	debug_ui_cell(ctx, "", "", white, muted)

	mu.layout_row(ctx, {label_width, -1})
	mu.label(ctx, "Ping")
	ping, ping_received, ping_available := client_ping(client)
	if ping_available {
		ping_rgba := ping_color(ping)
		debug_ui_value(ctx, fmt.tprintf("%s ms", ping_label(ping, ping_received)), {u8(ping_rgba.x*255), u8(ping_rgba.y*255), u8(ping_rgba.z*255), 255})
	} else {
		debug_ui_value(ctx, "offline", muted)
	}
	mu.label(ctx, "Map")
	debug_ui_value(ctx, debug_ui_map_name(client), white)
	mu.label(ctx, "Resolution")
	debug_ui_value(ctx, fmt.tprintf("%dx%d", i32(dbg.width), i32(dbg.height)), white)

	mu.layout_row(ctx, {-1}, i32(96*s))
	debug_ui_graph(dbg, stats, mu.layout_next(ctx), summary.frame_avg)
}

// Debug drawing toggles (debug_hitboxes.odin). All start off and are not saved.
// The section starts collapsed so the window keeps its size until it is used.
debug_ui_rendering :: proc(client: ^Client, dbg: ^Debug_UI) {
	ctx := &dbg.ctx
	if .ACTIVE not_in mu.header(ctx, "Rendering") { return }
	dr := &client.debug_render
	muted := mu.Color{150, 156, 168, 255}
	mu.layout_row(ctx, {-1})
	mu.checkbox(ctx, "Player hitboxes", &dr.player_hitboxes)
	mu.checkbox(ctx, "Map collision (150u)", &dr.map_collision)
	mu.checkbox(ctx, "Shot rays", &dr.shot_rays)
	mu.checkbox(ctx, "X-ray (offline only)", &dr.xray)
	// What the player boxes are: whose rules decide hits, and which pose.
	if dr.player_hitboxes {
		if debug_hitbox_model(client) == .KRUNKER {
			debug_ui_value(ctx, "Krunker server hurtboxes", muted)
			debug_ui_value(ctx, "at interpolated poses", muted)
		} else {
			debug_ui_value(ctx, debug_hitbox_kind(client) == .MELEE ? "SR Client melee boxes" : "SR Client shot boxes", muted)
			debug_ui_value(ctx, client.net.connected ? "displayed; server re-tests" : "at simulation positions", muted)
		}
	}
}

// The last PERF_GRAPH_FRAMES frame times as bars (newest at the right),
// scaled to perf_graph_top, with 60/144/240 FPS reference lines.
debug_ui_graph :: proc(dbg: ^Debug_UI, stats: ^Perf_Stats, r: mu.Rect, average_ms: f32) {
	ctx := &dbg.ctx
	mu.draw_rect(ctx, r, {6, 7, 9, 235})
	top := perf_graph_top(stats)
	frames := min(stats.count, PERF_GRAPH_FRAMES)
	for age in 0..<frames {
		slot := PERF_GRAPH_FRAMES - 1 - age
		x0 := r.x + i32(slot * int(r.w) / PERF_GRAPH_FRAMES)
		x1 := r.x + i32((slot + 1) * int(r.w) / PERF_GRAPH_FRAMES)
		frame_ms := perf_frame_sample(stats, age)
		height := perf_graph_bar_height(frame_ms, top, r.h)
		c := perf_level_color(perf_frame_level(frame_ms, average_ms))
		mu.draw_rect(ctx, {x0, r.y + r.h - height, max(1, x1 - x0), height}, {c[0], c[1], c[2], c[3]})
	}
	font := mu.Font(&dbg.small_font)
	text_h := ctx.text_height(font)
	// 60, 144 and 240 FPS run top to bottom; a label that would overlap the
	// one above it is skipped (the line is still drawn).
	next_free := r.y
	for fps in PERF_REFERENCE_FPS {
		y := r.y + r.h - perf_graph_bar_height(1000/fps, top, r.h)
		mu.draw_rect(ctx, {r.x, y, r.w, max(1, i32(dbg.scale))}, {255, 255, 255, 80})
		label := fmt.tprintf("%.0f", fps)
		label_y := max(r.y, y - text_h)
		if label_y < next_free { continue }
		mu.draw_text(ctx, font, label, {r.x + r.w - ctx.text_width(font, label) - i32(3*dbg.scale), label_y}, {220, 220, 225, 200})
		next_free = label_y + text_h
	}
	mu.draw_text(ctx, font, fmt.tprintf("%.1f ms", top), {r.x + i32(3*dbg.scale), r.y}, {200, 200, 210, 200})
}

debug_ui_color :: proc(color: mu.Color) -> shared.Vec4 {
	return {f32(color.r)/255, f32(color.g)/255, f32(color.b)/255, f32(color.a)/255}
}

// Records the visible part (inside the active clip) of something drawn.
@(private="file")
debug_ui_track :: proc(counts: ^Debug_UI_Draw_Counts, clip: mu.Rect, x, y, w, h: i32) {
	visible := mu.intersect_rects({x, y, w, h}, clip)
	x, y, w, h := visible.x, visible.y, visible.w, visible.h
	if w <= 0 || h <= 0 { return }
	if counts.min_x == counts.max_x {
		counts.min_x, counts.min_y, counts.max_x, counts.max_y = x, y, x + w, y + h
		return
	}
	counts.min_x, counts.min_y = min(counts.min_x, x), min(counts.min_y, y)
	counts.max_x, counts.max_y = max(counts.max_x, x + w), max(counts.max_y, y + h)
}

@(private="file")
debug_ui_text :: proc(dbg: ^Debug_UI, font: ^Debug_Font, color: mu.Color, text: string, x, y: f32) {
	ascent, descent, gap: i32
	stb_font_metrics(&ascent, &descent, &gap)
	baseline := y + font.size * f32(ascent) / f32(max(1, ascent - descent))
	ui_fill_text(dbg.ui, debug_ui_color(color), text, x, baseline, font.size)
}

// Draws the microui command list built this frame: rects and text through the
// HUD helpers, clip commands as GL scissor. Scissor is off again afterwards.
debug_ui_render :: proc(client: ^Client) -> (counts: Debug_UI_Draw_Counts) {
	dbg := client.debug_ui
	if dbg == nil { return }
	ui := client.ui
	command: ^mu.Command
	clip := mu.unclipped_rect
	for variant in mu.next_command_iterator(&dbg.ctx, &command) {
		switch c in variant {
		case ^mu.Command_Rect:
			counts.rects += 1
			debug_ui_track(&counts, clip, c.rect.x, c.rect.y, c.rect.w, c.rect.h)
			ui_fill_rect(ui, debug_ui_color(c.color), f32(c.rect.x), f32(c.rect.y), f32(c.rect.w), f32(c.rect.h))
		case ^mu.Command_Text:
			counts.texts += 1
			font := cast(^Debug_Font)c.font
			debug_ui_track(&counts, clip, c.pos.x, c.pos.y, debug_ui_text_width(c.font, c.str), debug_ui_text_height(c.font))
			debug_ui_text(dbg, font, c.color, c.str, f32(c.pos.x), f32(c.pos.y))
		case ^mu.Command_Icon:
			counts.icons += 1
			debug_ui_track(&counts, clip, c.rect.x, c.rect.y, c.rect.w, c.rect.h)
			debug_ui_icon(dbg, c)
		case ^mu.Command_Clip:
			counts.clips += 1
			clip = c.rect
			if c.rect.w >= mu.unclipped_rect.w {
				ui_clip_clear(ui)
			} else {
				ui_clip_set(ui, clay.BoundingBox{f32(c.rect.x), f32(c.rect.y), f32(c.rect.w), f32(c.rect.h)})
			}
		case ^mu.Command_Jump:
		}
	}
	ui_clip_clear(ui)
	return
}

// microui's icons as glyphs of the HUD font (or a filled box for the check).
@(private="file")
debug_ui_icon :: proc(dbg: ^Debug_UI, c: ^mu.Command_Icon) {
	glyph: string
	switch c.id {
	case .CLOSE: glyph = "x"
	case .COLLAPSED: glyph = "+"
	case .EXPANDED: glyph = "-"
	case .CHECK:
		inset := f32(c.rect.w) * 0.3
		ui_fill_rect(dbg.ui, debug_ui_color(c.color), f32(c.rect.x) + inset, f32(c.rect.y) + inset, f32(c.rect.w) - inset*2, f32(c.rect.h) - inset*2)
		return
	case .RESIZE, .NONE: return
	}
	font := &dbg.font
	w := dbg.measure(dbg.ui, glyph, font.size)
	debug_ui_text(dbg, font, c.color, glyph, f32(c.rect.x) + (f32(c.rect.w) - w)/2, f32(c.rect.y) + (f32(c.rect.h) - font.size)/2)
}
