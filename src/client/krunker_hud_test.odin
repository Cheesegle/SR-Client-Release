package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:testing"
import gl "vendor:OpenGL"
import glfw "vendor:glfw"
import kproto "../krunker"
import menuui "../menu"
import shared "../shared"

when ODIN_TEST {
	// Krunker's scaleBase(): (2 - scaleUI) times a 1700x900 page, fitted to the window.
	@(test)
	krunker_ui_scale_matches_krunker :: proc(t: ^testing.T) {
		settings: menuui.HUD_Settings
		testing.expect(t, abs(menuui.krunker_ui_factor(settings, 1920, 1080) - min(1920.0/(1700*1.3), 1080.0/(900*1.3))) < 1e-5, "default UI Scale is Krunker's 0.7")
		settings.ui_scale = 0.5
		testing.expect(t, abs(menuui.krunker_ui_factor(settings, 1920, 1080) - min(1920.0/2550, 1080.0/1350)) < 1e-5)
		settings.ui_scale = 5 // clamped to Krunker's 0.1..1
		testing.expect(t, abs(menuui.krunker_ui_factor(settings, 1920, 1080) - min(1920.0/1700, 1080.0/900)) < 1e-5)
		settings.ui_scaling_off = true
		testing.expect_value(t, menuui.krunker_ui_factor(settings, 1920, 1080), 1)
		testing.expect_value(t, menuui.menu_ui_zoom({}), 1)
	}

	// Renders the whole in-game HUD into bin/krunker-hud-<w>x<h>.ppm with
	// -define:HUD_PREVIEW=true, to compare with Krunker screenshots.
	@(test)
	krunker_hud_preview :: proc(t: ^testing.T) {
		when !#config(HUD_PREVIEW, false) { return }
		logger := context.logger
		context = runtime.default_context()
		context.logger = logger
		if !testing.expect(t, bool(glfw.Init())) { return }
		defer glfw.Terminate()
		glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)
		glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 5)
		window := glfw.CreateWindow(640, 360, "HUD preview", nil, nil)
		if !testing.expect(t, window != nil) { return }
		defer glfw.DestroyWindow(window)
		glfw.MakeContextCurrent(window)
		gl.load_up_to(4, 5, glfw.gl_set_proc_address)
		gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
		gl.ClearColor(67.0/255, 45.0/255, 29.0/255, 1) // the brown wall behind glorp's HUD
		framebuffer, color_texture: u32
		gl.GenFramebuffers(1, &framebuffer)
		gl.GenTextures(1, &color_texture)
		defer gl.DeleteFramebuffers(1, &framebuffer)
		defer gl.DeleteTextures(1, &color_texture)
		gl.BindFramebuffer(gl.FRAMEBUFFER, framebuffer)

		config := shared.config_load_gameplay("assets/config/game.toml")
		defer shared.config_destroy_gameplay(config)
		client := Client{ui = ui_init()}
		defer { overlay_fini(); ui_fini(client.ui); resource_cache_fini() }
		shared.game_configure(&client.game, &config.game, nil, nil, config.weapons, config.classes)
		defer shared.game_destroy(&client.game)
		g_map_name = "Lumber"
		defer g_map_name = ""
		client.krunker_world.mode_index = 2
		mode := shared.Game_Mode{objective = true}
		mode.config.teams = true
		client.game.mode = &mode
		defer client.game.mode = nil // not game_destroy's to free
		client.krunker.connected = true
		client.krunker_world.local_sid = 1
		client.krunker_world.rounds_total = 5
		client.bindings = menuui.default_bindings()
		names := [?]string{"Player [SR]", "PlayerTwo", "PlayerThree", "PlayerFour", "PlayerFive"}
		for name, i in names {
			append(&client.krunker_world.players, kproto.Krunker_World_Player{sid = i32(i+1), name = name, team = i%2 == 0 ? 1 : 2, score = u32(500 - i*100), kills = u32(5-i), active = true})
		}
		defer delete(client.krunker_world.players)
		me := shared.player_init(&client.game)
		me.is_you, me.team = true, 1
		shared.player_spawn(me, 0)
		me.health = 72
		client.me = me
		defer client.me = nil
		client.game.match = {phase = .LIVE, round_current = 2, time_remaining = 134, objective = {active_zone = -1, rotation_remaining = 42}, team_scores = {0, 180, 240}, round_wins = {0, 1, 0}}
		client.in_game, client.mouse_state.locked, client.show_fps = true, true, true
		client.fps_value = 1109
		client.krunker_world.ping, client.krunker_world.has_ping = 22, true
		kill_chat_clear()
		defer kill_chat_clear()
		killer := kill_feed_name("PlayerTwo", false, 2, 1)
		victim := kill_feed_name("Player [SR]", true, 1, 1)
		kill_chat_add({killer = killer, victim = victim, has_killer = true, weapon_id = 1, headshot = true})
		chat_receive(&client, []kproto.Krunker_Msgpack_Value{"ch", i64(0), "PlayerTwo", "gg nice try, rotate to the next point", i64(0), nil, "#eb5656", i64(2)})

		for size in ([?][2]i32{{1920, 1080}, {1280, 720}}) {
			for scale in ([?]f32{0.7, 0.9}) {
				gl.BindTexture(gl.TEXTURE_2D, color_texture)
				gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGB8, size[0], size[1], 0, gl.RGB, gl.UNSIGNED_BYTE, nil)
				gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, color_texture, 0)
				gl.BindTexture(gl.TEXTURE_2D, 0)
				g_active_texture = 0
				client.viewport_width, client.viewport_height = size[0], size[1]
				gl.Viewport(0, 0, size[0], size[1])
				client.hud_settings.ui_scale = scale
				pixels := make([]u8, int(size[0]*size[1]*3))
				defer delete(pixels)
				match_hud_snapshot(&client, pixels)
				file := make([dynamic]u8)
				defer delete(file)
				append(&file, ..transmute([]u8)fmt.tprintf("P6\n%d %d\n255\n", size[0], size[1]))
				for row := int(size[1])-1; row >= 0; row -= 1 { append(&file, ..pixels[row*int(size[0])*3:(row+1)*int(size[0])*3]) }
				testing.expect(t, os.write_entire_file(fmt.tprintf("bin/krunker-hud-%dx%d-%.1f.ppm", size[0], size[1], scale), file[:]) == nil)
			}
		}
		testing.expect(t, gl.GetError() == gl.NO_ERROR)
	}
}
