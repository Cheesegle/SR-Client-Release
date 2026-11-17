package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:testing"
import gl "vendor:OpenGL"
import glfw "vendor:glfw"
import shared "../shared"

when ODIN_TEST {
	match_hud_snapshot :: proc(client: ^Client, pixels: []u8) {
		gpu_clear(color = true, depth = true)
		ui_update(client.ui, f32(client.viewport_width), f32(client.viewport_height))
		overlay_render(client, 0)
		test_read_rgb(0, 0, client.viewport_width, client.viewport_height, raw_data(pixels))
	}
	// Regions are in Krunker CSS pixels (the HUD's UI Scale factor).
	match_hud_region_delta :: proc(client: ^Client, before, after: []u8, x1, y1, x2, y2: f32) -> int {
		changes := 0
		k := krunker_hud_scale(client)
		for y in max(0, int(y1*k))..<min(int(client.viewport_height), int(y2*k)) {
			for x in max(0, int(x1*k))..<min(int(client.viewport_width), int(x2*k)) {
				offset := ((int(client.viewport_height)-1-y)*int(client.viewport_width)+x)*3
				if before[offset] != after[offset] || before[offset+1] != after[offset+1] || before[offset+2] != after[offset+2] { changes += 1 }
			}
		}
		return changes
	}

	@(test)
	match_hud_separates_round_wins_from_objective_points :: proc(t: ^testing.T) {
		logger := context.logger
		context = runtime.default_context()
		context.logger = logger
		if !testing.expect(t, bool(glfw.Init())) { return }
		defer glfw.Terminate()
		test_gpu := test_gpu_open(1280, 720, "Match HUD")
		if !testing.expect(t, test_gpu.ok, "no GPU device for the test") do return
		defer test_gpu_close(&test_gpu, t)
		g_test_gpu = &test_gpu
		window := test_gpu.window
		gpu_set_clear_color({0.16, 0.18, 0.20})
		// Render independently of the hidden window's desktop-backed buffer size.
		framebuffer: Gpu_Render_Target
		defer test_gpu_target_destroy(&framebuffer)
		mode := shared.Game_Mode{objective=true}
		mode.config.teams = true
		client := Client{ui=ui_init(), krunker={connected=true}, game={mode=&mode}}
		defer { overlay_fini(); ui_fini(client.ui); resource_cache_fini() }
		client.krunker_world.rounds_total = 3
		for size in ([?][2]i32{{1280,720},{1920,1080},{2560,1600}}) {
			test_gpu_target_destroy(&framebuffer)
			framebuffer = test_gpu_target(size[0], size[1])
			if !testing.expect(t, framebuffer != 0) { return }
			test_gpu_use_target(framebuffer, size[0], size[1])
			g_active_texture = 0
			client.viewport_width, client.viewport_height = size[0], size[1]
			gpu_set_target(test_gpu_current_target(), size[0], size[1])
			client.hud_settings = {}
			client.game.match = {phase=.LIVE, round_current=1, time_remaining=180, objective={active_zone=-1, rotation_remaining=42}, team_scores={0,80,620}}
			before := make([]u8, int(size[0]*size[1]*3))
			after := make([]u8, len(before))
			defer delete(before)
			defer delete(after)
			match_hud_snapshot(&client, before)
			k := krunker_hud_scale(&client)
			center := client.ui.width/k*0.5
			client.game.match.team_scores = {0,190,450}
			match_hud_snapshot(&client, after)
			left_delta := match_hud_region_delta(&client, before, after, 0, 0, 300, 400)
			center_delta := match_hud_region_delta(&client, before, after, 300, 0, center*2, 400)
			testing.expectf(t, left_delta > 0 && center_delta == 0, "objective point changes must only update the team scores under the timer (left=%d center=%d)", left_delta, center_delta)
			copy(before, after)
			client.game.match.round_wins = {0,1,2}
			match_hud_snapshot(&client, after)
			left_delta = match_hud_region_delta(&client, before, after, 0, 0, 300, 400)
			center_delta = match_hud_region_delta(&client, before, after, center-250, 0, center+250, 160)
			testing.expectf(t, left_delta == 0 && center_delta > 0, "round wins must update the center board independently of objective points (left=%d center=%d)", left_delta, center_delta)
			copy(before, after)
			for option in 0..<3 {
				client.hud_settings = {hide_timer = option == 0, hide_round_score = option == 1, hide_game_score = option == 2}
				match_hud_snapshot(&client, after)
				timer_delta := match_hud_region_delta(&client, before, after, 0, 0, 250, 100)
				points_delta := match_hud_region_delta(&client, before, after, 0, 150, 250, 300)
				wins_delta := match_hud_region_delta(&client, before, after, center-250, 0, center+250, 100)
				switch option {
				case 0: testing.expectf(t, timer_delta > 0, "hiding the timer must remove it (timer=%d)", timer_delta)
				case 1: testing.expectf(t, points_delta > 0 && timer_delta == 0 && wins_delta == 0, "hiding team scores must only remove them (timer=%d points=%d wins=%d)", timer_delta, points_delta, wins_delta)
				case 2: testing.expectf(t, wins_delta > 0 && timer_delta == 0 && points_delta == 0, "hiding the round board must only remove it (timer=%d points=%d wins=%d)", timer_delta, points_delta, wins_delta)
				}
			}
			client.hud_settings = {}
			// Krunker stacks the ping line under FPS beside the timer.
			client.in_game, client.mouse_state.locked, client.show_fps = true, true, true
			client.krunker_world.ping, client.krunker_world.has_ping = 72, true
			client.hud_settings.hide_ping = true
			match_hud_snapshot(&client, before)
			client.hud_settings.hide_ping = false
			match_hud_snapshot(&client, after)
			fps_line := match_hud_region_delta(&client, before, after, 200, 0, center-250, 41)
			ping_line := match_hud_region_delta(&client, before, after, 200, 41, center-250, 80)
			testing.expectf(t, fps_line == 0 && ping_line > 0, "Show Ping must add only the line under FPS (fps=%d ping=%d)", fps_line, ping_line)
			client.in_game, client.mouse_state.locked, client.show_fps = false, false, false
			when #config(HUD_PREVIEW, false) {
				file := make([dynamic]u8)
				defer delete(file)
				append(&file, ..transmute([]u8)fmt.tprintf("P6\n%d %d\n255\n", size[0], size[1]))
				for row := int(size[1])-1; row >= 0; row -= 1 { append(&file, ..after[row*int(size[0])*3:(row+1)*int(size[0])*3]) }
				testing.expect(t, os.write_entire_file(fmt.tprintf("bin/match-hud-%dx%d.ppm", size[0],size[1]), file[:]) == nil)
			}
		}
		testing.expect(t, test_gpu_no_error())
	}
}
