package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import gl "vendor:OpenGL"
import glfw "vendor:glfw"
import mu "vendor:microui"
import menuui "../menu"

when ODIN_TEST {
	@(test)
	perf_ring_wraps_around :: proc(t: ^testing.T) {
		stats := new(Perf_Stats)
		defer free(stats)
		for i in 0..<PERF_HISTORY+5 { perf_push(stats, f32(i), f32(i)/2) }
		testing.expect(t, stats.count == PERF_HISTORY && stats.head == 5, "the ring keeps a fixed number of samples")
		testing.expect(t, perf_frame_sample(stats, 0) == f32(PERF_HISTORY+4), "age 0 is the newest sample")
		testing.expect(t, perf_frame_sample(stats, PERF_HISTORY-1) == 5, "the oldest kept sample follows the overwritten ones")
		testing.expect(t, stats.cpu_ms[perf_sample_index(stats, 0)] == f32(PERF_HISTORY+4)/2)
		perf_push(stats, -3, -1)
		testing.expect(t, perf_frame_sample(stats, 0) == 0, "negative timer deltas are clamped")
		perf_reset(stats)
		testing.expect(t, stats.count == 0 && perf_summary(stats) == Perf_Summary{}, "a reset ring has no statistics")
	}

	@(test)
	perf_fps_average_and_one_percent_low :: proc(t: ^testing.T) {
		near :: proc(a, b: f32) -> bool { return abs(a-b) < 0.01 }
		stats := new(Perf_Stats)
		defer free(stats)
		for _ in 0..<300 { perf_push(stats, 10, 4) }
		steady := perf_summary(stats)
		testing.expectf(t, near(steady.fps, 100) && near(steady.fps_avg, 100) && near(steady.fps_low, 100), "steady 10 ms frames are 100 FPS: %v", steady)
		testing.expect(t, near(steady.frame_avg, 10) && near(steady.frame_max, 10) && near(steady.cpu_avg, 4))

		// 400 frames (4.12 s, inside the 5 s low window) with four 40 ms hitches.
		perf_reset(stats)
		for i in 0..<400 {
			age := 399 - i
			perf_push(stats, age == 150 || age == 250 || age == 300 || age == 350 ? 40 : 10, 2)
		}
		summary := perf_summary(stats)
		testing.expectf(t, near(summary.fps_avg, 100), "the last second has no hitch, so the average stays 100: %v", summary.fps_avg)
		testing.expectf(t, near(summary.fps_low, 25), "1%% of 400 frames is the four 40 ms hitches, 25 FPS: %v", summary.fps_low)
		testing.expectf(t, near(summary.frame_max, 40), "the age-150 hitch is inside the 2 s frame window: %v", summary.frame_max)
		testing.expect(t, perf_window_frames(stats, PERF_FPS_WINDOW_MS) == 100, "the FPS window spans one second of frames")

		// A single 100 ms frame among 50 FPS frames.
		perf_reset(stats)
		for _ in 0..<99 { perf_push(stats, 20, 1) }
		perf_push(stats, 100, 1)
		summary = perf_summary(stats)
		testing.expect(t, near(summary.fps, 10) && near(summary.fps_low, 10) && near(summary.frame_max, 100), "the newest hitch is current, 1% low and max")
	}

	@(test)
	perf_graph_scaling_and_colors :: proc(t: ^testing.T) {
		stats := new(Perf_Stats)
		defer free(stats)
		for _ in 0..<PERF_GRAPH_FRAMES { perf_push(stats, 4, 1) }
		testing.expect(t, abs(perf_graph_top(stats) - 1000.0/60*1.15) < 0.001, "fast frames keep the 60 FPS line in view")
		perf_push(stats, 50, 1)
		testing.expect(t, abs(perf_graph_top(stats) - 57.5) < 0.001, "a slow frame rescales the graph to fit")
		for _ in 0..<PERF_GRAPH_FRAMES { perf_push(stats, 4, 1) }
		testing.expect(t, abs(perf_graph_top(stats) - 1000.0/60*1.15) < 0.001, "a hitch older than the graph no longer sets the scale")
		testing.expect(t, perf_graph_bar_height(57.5, 57.5, 100) == 100 && perf_graph_bar_height(28.75, 57.5, 100) == 50)
		testing.expect(t, perf_graph_bar_height(0, 57.5, 100) == 0 && perf_graph_bar_height(0.01, 57.5, 100) == 1 && perf_graph_bar_height(500, 57.5, 100) == 100,
			"bars are at least a pixel when non-zero and never leave the graph")
		testing.expect(t, perf_frame_level(4, 4) == .GOOD && perf_frame_level(1000.0/144, 0) == .GOOD)
		testing.expect(t, perf_frame_level(10, 10) == .WARN && perf_frame_level(1000.0/60, 0) == .WARN)
		testing.expect(t, perf_frame_level(20, 20) == .BAD, "below 60 FPS is red")
		testing.expect(t, perf_frame_level(12, 3) == .BAD && perf_frame_level(5, 3) == .WARN, "hitches relative to the average stand out at high frame rates")
		testing.expect(t, perf_level_color(.GOOD) != perf_level_color(.WARN) && perf_level_color(.WARN) != perf_level_color(.BAD))
	}

	@(test)
	perf_overlay_is_developer_only :: proc(t: ^testing.T) {
		// Release and tester builds compile the window out and hide its key bind;
		// developer builds (-define:SR_DEV=true) list it under Interface.
		testing.expect(t, menuui.binding_visible(.DEBUG_OVERLAY) == SR_DEV, "the debug overlay bind is listed only in developer builds")
		testing.expect(t, menuui.SR_DEV == SR_DEV, "client and menu agree on the developer flag")
		for action in menuui.Binding_Action {
			if action != .DEBUG_OVERLAY { testing.expect(t, menuui.binding_visible(action), "every other bind stays listed") }
		}
	}

	@(test)
	perf_overlay_binding_defaults_to_f3_and_persists :: proc(t: ^testing.T) {
		testing.expect(t, menuui.default_bindings()[.DEBUG_OVERLAY] == ([2]i32{glfw.KEY_F3, 0}), "the debug overlay defaults to F3")
		testing.expect(t, menuui.binding_valid(glfw.KEY_F3) && menuui.binding_label(glfw.KEY_F3) == "F3" && menuui.BINDING_NAMES[.DEBUG_OVERLAY] == "Debug overlay")
		path := "bin/client-settings-perf-overlay-test.json"
		defer os.remove(path)
		settings := client_settings_defaults()
		testing.expect(t, !settings.perf_overlay, "the window starts closed")
		settings.bindings[.DEBUG_OVERLAY] = {glfw.KEY_F8, -3}
		settings.perf_overlay = true
		testing.expect(t, client_settings_save(settings, path))
		loaded := client_settings_load(path)
		testing.expect(t, loaded.bindings[.DEBUG_OVERLAY] == ([2]i32{glfw.KEY_F8, -3}) && loaded.perf_overlay, "a rebound key and the open state persist")
		testing.expect(t, os.write_entire_file(path, `{"version":1,"bindings":{"LEADERBOARD":[76,0]}}`) == nil)
		migrated := client_settings_load(path)
		testing.expect(t, migrated.bindings[.DEBUG_OVERLAY] == ([2]i32{glfw.KEY_F3, 0}) && !migrated.perf_overlay, "older preferences get F3 and a closed window")

		client := Client{bindings = menuui.default_bindings()}
		f3 := proc(window: glfw.WindowHandle, code: i32) -> bool { return code == glfw.KEY_F3 }
		f8 := proc(window: glfw.WindowHandle, code: i32) -> bool { return code == glfw.KEY_F8 }
		none := proc(window: glfw.WindowHandle, code: i32) -> bool { return false }
		testing.expect(t, client_perf_overlay_toggle_update(&client, f3) && client.perf_overlay, "F3 opens the window")
		testing.expect(t, !client_perf_overlay_toggle_update(&client, f3) && client.perf_overlay, "holding the key does not toggle again")
		testing.expect(t, !client_perf_overlay_toggle_update(&client, none))
		testing.expect(t, client_perf_overlay_toggle_update(&client, f3) && !client.perf_overlay, "a second press closes it")
		client_perf_overlay_toggle_update(&client, none)
		client.menu.binding_capture = 1
		testing.expect(t, !client_perf_overlay_toggle_update(&client, f3) && !client.perf_overlay, "capturing a new bind never toggles the window")
		client.menu.binding_capture = 0
		testing.expect(t, !client_perf_overlay_toggle_update(&client, f3), "a key still held after capture does not toggle")
		client_perf_overlay_toggle_update(&client, none)
		client.bindings[.DEBUG_OVERLAY] = {glfw.KEY_F8, 0}
		testing.expect(t, !client_perf_overlay_toggle_update(&client, f3) && client_perf_overlay_toggle_update(&client, f8) && client.perf_overlay, "the rebound key replaces F3")
	}

	@(test)
	perf_overlay_off_records_and_draws_nothing :: proc(t: ^testing.T) {
		client := new(Client)
		defer free(client)
		g_draw_calls = 7
		perf_overlay_record(client, 16, 4)
		client_collect_gpu_times(client)
		testing.expect(t, client.perf.count == 0 && client.perf.draw_calls == 0, "nothing is recorded while the window is closed")
		testing.expect(t, client.perf.gpu_frames == 0 && !client.perf.gpu_valid, "no GPU time is kept while closed")
		testing.expect(t, client.debug_ui == nil && debug_ui_render(client) == Debug_UI_Draw_Counts{}, "no microui context or draw while closed")
		perf_overlay_set(client, true)
		perf_overlay_record(client, 16, 4)
		testing.expect(t, client.perf.count == 1 && client.perf.draw_calls == 7, "opening starts recording")
		perf_overlay_set(client, false)
		perf_overlay_set(client, true)
		testing.expect(t, client.perf.count == 0, "reopening starts from a fresh history")
		g_draw_calls = 0
	}

	@(test)
	perf_overlay_splits_frame_time :: proc(t: ^testing.T) {
		client := new(Client)
		defer free(client)
		perf_overlay_set(client, true)
		// 10 ms frame = 2 ms CPU + 5 ms swap + 1 ms events + 2 ms other.
		perf_overlay_record(client, 10, 2, 5, 1)
		summary := perf_summary(&client.perf)
		testing.expect(t, summary.split_ms == ([Perf_Split]f32{.SWAP = 5, .EVENTS = 1, .OTHER = 2}), "the frame splits into swap, events and the remainder")
		// A 40 ms swap stall among fast frames shows as the swap max, not CPU.
		perf_reset(&client.perf)
		for _ in 0 ..< 50 { perf_overlay_record(client, 1, 0.2, 0.5, 0.1) }
		perf_overlay_record(client, 41, 0.2, 40, 0.1)
		for _ in 0 ..< 50 { perf_overlay_record(client, 1, 0.2, 0.5, 0.1) }
		summary = perf_summary(&client.perf)
		testing.expect(t, summary.split_max[.SWAP] == 40 && summary.cpu_max < 1 && summary.split_max[.EVENTS] < 1, "a swap stall is attributed to swap")
		testing.expect(t, perf_frame_level(summary.split_max[.SWAP], 0) == .BAD, "and its max is coloured as a hitch")
		// The remainder never goes negative when parts overlap rounding.
		perf_overlay_record(client, 1, 0.6, 0.5, 0.1)
		testing.expect(t, perf_summary(&client.perf).split_ms[.OTHER] == 0, "other is clamped at zero")
	}

	@(test)
	perf_overlay_shows_batching_stats :: proc(t: ^testing.T) {
		client := new(Client)
		defer free(client)
		perf_overlay_set(client, true)
		// The renderer resets g_draw_stats each frame; the window snapshots it.
		g_draw_calls = 90
		g_draw_stats = {draw_calls = 80, batch_draws = 60, batches_culled = 140, meshes_culled = 12}
		perf_overlay_record(client, 2, 1)
		testing.expect(t, client.perf.shown_valid && client.perf.shown_draw_calls == 90, "the first frame is shown right away")
		testing.expect(t, client.perf.shown_world == (Draw_Stats{draw_calls = 80, batch_draws = 60, batches_culled = 140, meshes_culled = 12}), "batching and culling stats reach the window")
		// Later frames update the snapshot only at the 250 ms refresh.
		g_draw_stats = {draw_calls = 300, batch_draws = 0, batches_culled = 0, meshes_culled = 0}
		perf_overlay_record(client, 2, 1)
		testing.expect(t, client.perf.shown_world.batch_draws == 60, "batching stats refresh with the other numbers")
		for _ in 0..<130 { perf_overlay_record(client, 2, 1) }
		testing.expect(t, client.perf.shown_world.draw_calls == 300, "and update after 250 ms")
		g_draw_calls, g_draw_stats = 0, {}
	}

	// Fixed-width text so the input tests need no GL font.
	perf_test_measure :: proc(ui: ^UI, text: string, size: f32) -> f32 { return f32(len(text)) * size * 0.5 }

	perf_test_debug_ui :: proc() -> (^Client, ^Debug_UI) {
		client := new(Client)
		client.bindings = menuui.default_bindings()
		client.perf_overlay = true
		dbg := debug_ui_create(nil)
		dbg.measure = perf_test_measure
		debug_ui_layout(dbg, 1280, 720)
		client.debug_ui = dbg
		for _ in 0..<60 { perf_push(&client.perf, 8, 3) }
		return client, dbg
	}

	perf_test_frame :: proc(client: ^Client, dbg: ^Debug_UI, input: Debug_UI_Input) -> bool {
		debug_ui_feed(dbg, input)
		return debug_ui_build(client, dbg)
	}

	// Left x of every caption text and right x of the value drawn after it, in draw order.
	perf_test_cell_edges :: proc(dbg: ^Debug_UI) -> (captions: [dynamic]i32, value_rights: [dynamic]i32) {
		captions = make([dynamic]i32, context.temp_allocator)
		value_rights = make([dynamic]i32, context.temp_allocator)
		command: ^mu.Command
		after_caption := false
		for variant in mu.next_command_iterator(&dbg.ctx, &command) {
			text, ok := variant.(^mu.Command_Text)
			if !ok { continue }
			if text.str == "avg" || text.str == "max" || text.str == "1% low" {
				append(&captions, text.pos.x)
				after_caption = true
			} else if after_caption {
				append(&value_rights, text.pos.x + debug_ui_text_width(text.font, text.str))
				after_caption = false
			}
		}
		return
	}

	@(test)
	perf_shown_values_refresh_four_times_a_second :: proc(t: ^testing.T) {
		client := new(Client)
		defer free(client)
		client.perf_overlay = true
		// The first frame is shown right away.
		perf_overlay_record(client, 10, 2)
		testing.expect(t, client.perf.shown_valid && client.perf.shown.frame_ms == 10, "the first frame is shown immediately")
		// Faster frames for less than 250 ms do not change the shown values.
		for _ in 0..<40 { perf_overlay_record(client, 5, 1) } // 200 ms
		testing.expect(t, client.perf.shown.frame_ms == 10 && client.perf.shown.cpu_ms == 2, "values hold until 250 ms of frames pass")
		// Crossing 250 ms refreshes them to the mean over the last 250 ms.
		for _ in 0..<10 { perf_overlay_record(client, 5, 1) } // 250 ms in total
		testing.expect(t, client.perf.shown.frame_ms == 5 && client.perf.shown.fps == 200 && client.perf.shown.cpu_ms == 1, "after 250 ms the shown values are the interval mean")
		// A single slow frame moves the shown current value only at the next refresh.
		perf_overlay_record(client, 40, 1)
		testing.expect(t, client.perf.shown.frame_ms == 5, "one hitch does not flash the number immediately")
		testing.expect(t, perf_frame_sample(&client.perf, 0) == 40, "the graph still sees every frame")
		// Closing the window (no recording) leaves nothing to refresh.
		perf_reset(&client.perf)
		testing.expect(t, !client.perf.shown_valid, "reset clears the snapshot")
	}

	@(test)
	debug_ui_stat_cells_do_not_shift :: proc(t: ^testing.T) {
		client, dbg := perf_test_debug_ui()
		defer { free(dbg); free(client) }
		perf_test_frame(client, dbg, {})
		captions_a, rights_a := perf_test_cell_edges(dbg)
		// The current frame jumps from 8 ms (125 FPS) to 0.5 ms (2000 FPS): the
		// current values gain a digit, but the avg/max/1% low cells must not move.
		for _ in 0..<500 { perf_push(&client.perf, 0.5, 0.1) }
		perf_refresh_shown(&client.perf, true)
		testing.expect(t, client.perf.shown.fps >= 1000, "the shown current FPS gained a digit")
		perf_test_frame(client, dbg, {})
		captions_b, rights_b := perf_test_cell_edges(dbg)
		testing.expect(t, len(captions_a) >= 5 && len(captions_a) == len(captions_b), "every row draws its captions")
		testing.expect(t, len(rights_a) == len(captions_a) && len(rights_b) == len(captions_b), "each caption has a value after it")
		for i in 0..<min(len(captions_a), len(captions_b)) {
			testing.expectf(t, captions_a[i] == captions_b[i], "caption %d moved from %d to %d", i, captions_a[i], captions_b[i])
		}
		for i in 0..<min(len(rights_a), len(rights_b)) {
			testing.expectf(t, rights_a[i] == rights_b[i], "value %d is not right-aligned in a fixed cell (%d vs %d)", i, rights_a[i], rights_b[i])
		}
	}

	@(test)
	debug_ui_is_display_only_while_playing :: proc(t: ^testing.T) {
		client, dbg := perf_test_debug_ui()
		defer { free(dbg); free(client) }
		perf_test_frame(client, dbg, {})
		window := mu.get_container(&dbg.ctx, DEBUG_WINDOW_TITLE).rect
		over := [2]f32{f32(window.x + 30), f32(window.y + 8)}
		perf_test_frame(client, dbg, {pointer = over})
		testing.expect(t, perf_test_frame(client, dbg, {pointer = over, buttons = {.LEFT}}), "in menus the window owns a click over it")
		testing.expect(t, dbg.ctx.mouse_down_bits == {.LEFT})
		// Gameplay grabs the cursor mid-press: microui must let go of everything.
		for _ in 0..<3 {
			captured := perf_test_frame(client, dbg, {locked = true, pointer = over, buttons = {.LEFT, .RIGHT}, scroll = {0, 3}, keys = {.SHIFT}, text = "w"})
			testing.expect(t, !captured, "while playing the window never captures the pointer")
		}
		testing.expect(t, dbg.ctx.mouse_down_bits == {} && dbg.ctx.key_down_bits == {} && dbg.ctx.focus_id == 0 && dbg.ctx.hover_root == nil, "no input reaches microui while playing")
		after := mu.get_container(&dbg.ctx, DEBUG_WINDOW_TITLE).rect
		testing.expect(t, after.x == window.x && after.y == window.y, "the window cannot move while playing")
		// Gameplay bindings are read straight from GLFW and still fire.
		client.mouse_state.locked = true
		fire := proc(window: glfw.WindowHandle, code: i32) -> bool { return code == -1 || code == 'W' }
		testing.expect(t, client_action_down(client, .FIRE, fire) && client_action_down(client, .FORWARD, fire), "gameplay bindings fire with the window open")
	}

	@(test)
	debug_ui_click_does_not_reach_menu :: proc(t: ^testing.T) {
		client, dbg := perf_test_debug_ui()
		defer { free(dbg); free(client) }
		perf_test_frame(client, dbg, {})
		window := mu.get_container(&dbg.ctx, DEBUG_WINDOW_TITLE).rect
		inside := [2]f32{f32(window.x + window.w/2), f32(window.y + window.h/2)}
		testing.expect(t, perf_test_frame(client, dbg, {pointer = inside}), "hovering the window claims the pointer")
		testing.expect(t, perf_test_frame(client, dbg, {pointer = inside, buttons = {.LEFT}, scroll = {0, -2}}), "a click and scroll over the window are claimed")
		testing.expect(t, dbg.ctx.hover_root != nil)
		menu := menuui.Input{pointer = {inside.x, inside.y}, down = true, scroll = {0, -2}, binding_pressed = -1, escape = true}
		debug_ui_block_menu_input(&menu)
		testing.expect(t, !menu.down && menu.scroll == {} && menu.binding_pressed == 0 && menu.pointer.x < 0, "the menu sees no click, scroll or mouse bind")
		testing.expect(t, menu.escape, "keyboard menu input is untouched")
		perf_test_frame(client, dbg, {pointer = inside})
		testing.expect(t, !perf_test_frame(client, dbg, {pointer = {5, f32(dbg.height) - 5}}), "outside the window the menu keeps the pointer")
		testing.expect(t, !perf_test_frame(client, dbg, {pointer = {5, f32(dbg.height) - 5}, buttons = {.LEFT}}), "a click outside reaches the menu")
	}

	@(test)
	debug_ui_dragging_moves_the_window :: proc(t: ^testing.T) {
		client, dbg := perf_test_debug_ui()
		defer { free(dbg); free(client) }
		perf_test_frame(client, dbg, {})
		perf_test_frame(client, dbg, {})
		start := mu.get_container(&dbg.ctx, DEBUG_WINDOW_TITLE).rect
		testing.expect(t, start.x + start.w <= 1280 && start.x > 640 && start.y < 100, "the window opens top-right")
		title := [2]f32{f32(start.x + 40), f32(start.y + 6)}
		// microui needs the pointer resting over a control before a press.
		perf_test_frame(client, dbg, {pointer = title})
		perf_test_frame(client, dbg, {pointer = title})
		perf_test_frame(client, dbg, {pointer = title, buttons = {.LEFT}})
		testing.expect(t, perf_test_frame(client, dbg, {pointer = title + {-300, 120}, buttons = {.LEFT}}), "a drag keeps the pointer even if it outruns the window")
		perf_test_frame(client, dbg, {pointer = title + {-300, 120}})
		moved := mu.get_container(&dbg.ctx, DEBUG_WINDOW_TITLE).rect
		testing.expectf(t, moved.x == start.x - 300 && moved.y == start.y + 120 && moved.w == start.w, "dragging the title moves the window (%v -> %v)", start, moved)
		// Dragging past the edge keeps the window on screen.
		title = {f32(moved.x + 40), f32(moved.y + 6)}
		perf_test_frame(client, dbg, {pointer = title})
		perf_test_frame(client, dbg, {pointer = title})
		perf_test_frame(client, dbg, {pointer = title, buttons = {.LEFT}})
		perf_test_frame(client, dbg, {pointer = title + {-5000, -5000}, buttons = {.LEFT}})
		perf_test_frame(client, dbg, {pointer = title + {-5000, -5000}})
		clamped := mu.get_container(&dbg.ctx, DEBUG_WINDOW_TITLE).rect
		testing.expectf(t, clamped.x == 0 && clamped.y == 0, "the window stays on screen: %v", clamped)
	}

	@(test)
	debug_ui_close_button_turns_overlay_off :: proc(t: ^testing.T) {
		client, dbg := perf_test_debug_ui()
		defer { free(dbg); free(client) }
		perf_test_frame(client, dbg, {})
		window := mu.get_container(&dbg.ctx, DEBUG_WINDOW_TITLE).rect
		close := [2]f32{f32(window.x + window.w - dbg.ctx.style.title_height/2), f32(window.y + dbg.ctx.style.title_height/2)}
		perf_test_frame(client, dbg, {pointer = close})
		perf_test_frame(client, dbg, {pointer = close})
		perf_test_frame(client, dbg, {pointer = close, buttons = {.LEFT}})
		perf_test_frame(client, dbg, {pointer = close})
		testing.expect(t, !debug_ui_window_open(dbg), "the close button closes the window")
		perf_test_frame(client, dbg, {})
		testing.expect(t, debug_ui_window_open(dbg), "the toggle reopens it")
	}

	@(test)
	debug_ui_renders_within_screen :: proc(t: ^testing.T) {
		logger := context.logger
		context = runtime.default_context()
		context.logger = logger
		if !testing.expect(t, bool(glfw.Init())) { return }
		defer glfw.Terminate()
		test_gpu := test_gpu_open(1280, 720, "Debug UI")
		if !testing.expect(t, test_gpu.ok, "no GPU device for the test") do return
		defer test_gpu_close(&test_gpu, t)
		g_test_gpu = &test_gpu
		window := test_gpu.window
		gpu_set_clear_color({0.16, 0.18, 0.20})
		framebuffer: Gpu_Render_Target
		defer test_gpu_target_destroy(&framebuffer)
		client := new(Client)
		defer free(client)
		client.ui, client.window, client.bindings = ui_init(), window, menuui.default_bindings()
		defer { debug_ui_fini(client); ui_fini(client.ui); resource_cache_fini() }
		// A long map name is clipped by the window, exercising clip commands.
		g_map_name = strings.repeat("long-map-name-", 12, context.temp_allocator)
		defer g_map_name = ""
		perf_overlay_set(client, true)
		for i in 0..<300 { perf_push(&client.perf, i % 50 == 0 ? 40 : 7, 3) }
		for size in ([?][2]i32{{1280, 720}, {1920, 1080}, {2560, 1600}}) {
			test_gpu_target_destroy(&framebuffer)
			framebuffer = test_gpu_target(size[0], size[1])
			if !testing.expect(t, framebuffer != 0) { return }
			test_gpu_use_target(framebuffer, size[0], size[1])
			g_active_texture = 0
			client.viewport_width, client.viewport_height = size[0], size[1]
			gpu_set_target(test_gpu_current_target(), size[0], size[1])
			client.mouse_state.locked = true // Display-only: no GLFW input is read.
			counts: Debug_UI_Draw_Counts
			for _ in 0..<3 {
				gpu_clear(color = true, depth = false)
				ui_update(client.ui, f32(size[0]), f32(size[1]))
				testing.expect(t, !debug_ui_update(client), "a locked cursor never feeds the window")
				counts = debug_ui_render(client)
			}
			testing.expectf(t, counts.rects > PERF_GRAPH_FRAMES && counts.texts >= 18 && counts.icons >= 2, "microui commands map to rects, text and icons: %v", counts)
			testing.expectf(t, counts.clips > 0, "the long map name produces clip commands: %v", counts)
			testing.expectf(t, counts.min_x >= 0 && counts.min_y >= 0 && counts.max_x <= size[0] && counts.max_y <= size[1], "the window draws within %v: %v", size, counts)
			when !SR_VULKAN { testing.expect(t, !gl.IsEnabled(gl.SCISSOR_TEST), "scissor is restored after the window") } // GL state
			pixels := make([]u8, int(size[0]*size[1]*3), context.temp_allocator)
			test_read_rgb(0, 0, size[0], size[1], raw_data(pixels))
			window_rect := mu.get_container(&client.debug_ui.ctx, DEBUG_WINDOW_TITLE).rect
			changed, outside := 0, 0
			for y in 0..<int(size[1]) {
				for x in 0..<int(size[0]) {
					offset := ((int(size[1])-1-y)*int(size[0])+x)*3
					differs := pixels[offset] != pixels[0] || pixels[offset+1] != pixels[1] || pixels[offset+2] != pixels[2]
					// microui draws the window border one pixel outside its rect.
					inside := x >= int(window_rect.x)-1 && x <= int(window_rect.x+window_rect.w) && y >= int(window_rect.y)-1 && y <= int(window_rect.y+window_rect.h)
					if differs && inside { changed += 1 }
					if differs && !inside { outside += 1 }
				}
			}
			testing.expectf(t, changed > int(window_rect.w*window_rect.h)/2 && outside == 0, "the window is drawn inside its rect only (inside=%d outside=%d)", changed, outside)
			testing.expect(t, window_rect.x + window_rect.w > size[0]*3/4, "the window sits top-right")
			when #config(DEBUG_UI_PREVIEW, false) {
				file := make([dynamic]u8)
				defer delete(file)
				append(&file, ..transmute([]u8)fmt.tprintf("P6\n%d %d\n255\n", size[0], size[1]))
				for row := int(size[1])-1; row >= 0; row -= 1 { append(&file, ..pixels[row*int(size[0])*3:(row+1)*int(size[0])*3]) }
				testing.expect(t, os.write_entire_file(fmt.tprintf("bin/debug-ui-%dx%d.ppm", size[0], size[1]), file[:]) == nil)
			}
		}
		// Frame GPU times (gpu_frame_begin/end) arrive a few frames later.
		for _ in 0..<12 {
			gpu_frame_begin()
			gpu_clear(color = true, depth = false)
			gpu_frame_end()
			gpu_wait_idle()
			client_collect_gpu_times(client)
		}
		gpu_frames_fini()
		testing.expect(t, client.perf.gpu_frames > 0 && client.perf.gpu_valid && client.perf.gpu_ms >= 0, "frame GPU times reach the window")
		testing.expect(t, test_gpu_no_error())
	}
}
