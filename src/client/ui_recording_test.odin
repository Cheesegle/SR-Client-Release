package main

import "core:testing"

@(test)
ui_recording_replays_the_same_boxes :: proc(t: ^testing.T) {
	ui := UI{width = 800, height = 600, scale = 1}
	saved := g_ui_batch
	g_ui_batch = {}
	defer {
		delete(g_ui_batch.vertices); delete(g_ui_batch.indices); delete(g_ui_batch.commands)
		g_ui_batch = saved
	}
	draw :: proc(ui: ^UI) {
		ui_fill_rect(ui, {1, 0, 0, 1}, 10, 10, 50, 20)
		ui_draw_image(ui, 7, 100, 100, 30, 30)
		ui_fill_rect(ui, {0, 1, 0, 1}, 200, 10, 5, 5)
	}
	// Something queued before the block (with a texture the block's solid box could join).
	ui_draw_image(&ui, 3, 0, 0, 4, 4)
	recording: UI_Recording
	defer ui_record_free(&recording)
	ui_record_begin(&recording)
	draw(&ui)
	ui_record_end(&recording)
	testing.expect(t, ui_record_usable(&recording), "a block without a flush is usable")
	built_vertices := len(g_ui_batch.vertices) - 4
	testing.expect_value(t, len(recording.vertices), built_vertices)

	// Queue the block again, built and replayed, after the same lead-in: identical lists.
	built: [3]int
	for pass in 0..<2 {
		delete(g_ui_batch.vertices); delete(g_ui_batch.indices); delete(g_ui_batch.commands)
		g_ui_batch = {}
		ui_draw_image(&ui, 3, 0, 0, 4, 4)
		if pass == 0 {
			scratch: UI_Recording
			ui_record_begin(&scratch)
			draw(&ui)
			ui_record_free(&scratch)
			built = {len(g_ui_batch.vertices), len(g_ui_batch.indices), len(g_ui_batch.commands)}
			continue
		}
		ui_record_replay(&recording)
		testing.expect_value(t, len(g_ui_batch.vertices), built[0])
		testing.expect_value(t, len(g_ui_batch.indices), built[1])
		testing.expect_value(t, len(g_ui_batch.commands), built[2])
		testing.expect_value(t, g_ui_batch.indices[len(g_ui_batch.indices) - 1], u32(len(g_ui_batch.vertices) - 1))
		total: u32 = 0
		for command in g_ui_batch.commands { total += command.count }
		testing.expect_value(t, total, u32(len(g_ui_batch.indices)))
		last := g_ui_batch.commands[len(g_ui_batch.commands) - 1]
		testing.expect_value(t, int(last.first + last.count), len(g_ui_batch.indices))
	}

	// A flush inside the block drops the recording.
	ui_record_begin(&recording)
	draw(&ui)
	g_ui_flushes += 1
	ui_record_end(&recording)
	testing.expect(t, !ui_record_usable(&recording), "a flushed block is not usable")
}
