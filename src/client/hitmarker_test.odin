package main

import "base:runtime"
import "core:os"
import "core:strings"
import "core:testing"
import gl "vendor:OpenGL"
import glfw "vendor:glfw"
import stbi "vendor:stb/image"
import menuui "../menu"
import shared "../shared"

when ODIN_TEST {
	@(test)
	hitmarker_settings_default_and_persist :: proc(t: ^testing.T) {
		defaults := client_settings_defaults().hitmarker
		testing.expect(t, defaults.show && defaults.values == [menuui.Hitmarker_Control]f32{.OPACITY=1, .LENGTH=25, .THICKNESS=7, .SPACING=37, .ANIM_SIZE=0.14, .FADE=0.0062}, "defaults must match Krunker's hitm* settings")
		testing.expect(t, defaults.colors[.NORMAL] == 0xffffff && defaults.colors[.KILL] == 0xff0000 && defaults.colors[.HEADSHOT] == 0xffffff, "Krunker colors: white hit, red kill; headshot starts as the hit color")
		testing.expect(t, abs(menuui.hitmarker_duration(defaults)-0.1613) < 0.001, "the default marker lasts about 161 ms")
		path := "bin/client-settings-hitmarker-test.json"
		defer os.remove(path)
		legacy := `{"version":1,"crosshair":{"kind":"PRECISION","values":{"OPACITY":1,"SHADOW":1,"THICKNESS":2,"SIZE":16,"GAP":0},"toggles":{"CUSTOM_OPACITY":false,"ALWAYS_SHOW":false,"DOT":true},"color":16777215,"shadow_color":0}}`
		testing.expect(t, os.write_entire_file(path, transmute([]u8)legacy) == nil)
		testing.expect(t, client_settings_load(path).hitmarker == menuui.DEFAULT_HITMARKER_SETTINGS, "older settings files get Krunker's hitmarker defaults")
		changed := client_settings_defaults()
		changed.hitmarker.show = false
		changed.hitmarker.values[.LENGTH], changed.hitmarker.values[.FADE] = 40, 0.002
		changed.hitmarker.colors[.HEADSHOT] = 0xffd000
		testing.expect(t, client_settings_save(changed, path))
		loaded := client_settings_load(path).hitmarker
		testing.expect(t, loaded == changed.hitmarker, "hitmarker settings must survive a restart")
		bad := menuui.DEFAULT_HITMARKER_SETTINGS
		bad.values[.LENGTH], bad.values[.SPACING], bad.colors[.KILL] = 500, -3, 0xff123456
		bad = menuui.hitmarker_settings_validate(bad)
		testing.expect(t, bad.values[.LENGTH] == 50 && bad.values[.SPACING] == 5 && bad.colors[.KILL] == 0x123456, "values clamp to Krunker's slider ranges")
	}

	@(test)
	hitmarker_settings_draft_save_cancel_and_import :: proc(t: ^testing.T) {
		client := Client{hitmarker_settings = menuui.DEFAULT_HITMARKER_SETTINGS}
		client.menu.page = .SETTINGS
		menuui.prepare_settings(&client.menu, {hitmarker = client.hitmarker_settings})
		menuui.activate(&client.menu, {action = {kind = .HITMARKER_VALUE, index = i32(menuui.Hitmarker_Control.THICKNESS), value = 3}})
		menuui.activate(&client.menu, {action = {kind = .HITMARKER_TOGGLE}})
		menuui.settings_color_begin(&client.menu, menuui.HITMARKER_COLOR_FIELDS[.HEADSHOT])
		client.menu.color_length = copy(client.menu.color_buffer[:], "#00FF00")
		testing.expect(t, menuui.settings_color_commit(&client.menu))
		preview := client_hitmarker_values(&client)
		testing.expect(t, preview.values[.THICKNESS] == 3 && !preview.show && preview.colors[.HEADSHOT] == 0x00ff00, "the draft previews in game while Settings is open")
		testing.expect(t, client.hitmarker_settings == menuui.DEFAULT_HITMARKER_SETTINGS, "editing must not commit before Save")
		menuui.activate(&client.menu, {action = {kind = .SETTINGS_CANCEL}})
		testing.expect(t, client_hitmarker_values(&client) == menuui.DEFAULT_HITMARKER_SETTINGS, "Cancel restores the committed hitmarker")

		values := menuui.Settings_Values{hitmarker = menuui.DEFAULT_HITMARKER_SETTINGS}
		values.hitmarker.colors[.HEADSHOT] = 0x123456
		result, err := menuui.krunker_settings_import(&values, `{"hitm":false,"hitmCol":"#00ff00","hitmKCol":"#0000ff","hitOpac":0.5,"hitmLen":30,"hitmThick":4,"hitmSpac":20,"hitmAnimD":0.2,"hitmFad":0.001}`)
		testing.expect(t, len(err) == 0 && result.imported == 9 && result.ignored == 0, "every Krunker hitmarker key imports")
		h := values.hitmarker
		testing.expect(t, !h.show && h.colors[.NORMAL] == 0x00ff00 && h.colors[.KILL] == 0x0000ff && h.colors[.HEADSHOT] == 0x123456, "imports keep SR Client's own headshot color")
		testing.expect(t, h.values == [menuui.Hitmarker_Control]f32{.OPACITY=0.5, .LENGTH=30, .THICKNESS=4, .SPACING=20, .ANIM_SIZE=0.2, .FADE=0.001})
		exported := menuui.krunker_settings_export(values, context.temp_allocator)
		testing.expect(t, strings.contains(exported, `"hitm":false`) && strings.contains(exported, `"hitmFad":0.001`) && strings.contains(exported, `"hitmKCol":"#0000ff"`), "export writes changed hitmarker keys")
		testing.expect(t, !strings.contains(menuui.krunker_settings_export({hitmarker = menuui.DEFAULT_HITMARKER_SETTINGS}, context.temp_allocator), "hitm"), "defaults are not exported")
	}

	@(test)
	hitmarker_body_headshot_kill_and_expiry :: proc(t: ^testing.T) {
		client: Client
		map_inst: shared.Map
		krunker_presentation_fixture(&client, &map_inst)
		defer krunker_presentation_cleanup(&client)
		client.krunker.connected = false
		client.hitmarker_settings = menuui.DEFAULT_HITMARKER_SETTINGS
		client.hitmarker_settings.colors[.HEADSHOT] = 0xffd000
		client.game.presentation_enabled = true
		victim := shared.player_init(&client.game)
		shared.game_players_add(&client.game, victim)
		shared.player_spawn(victim, 2)
		victim.uid = 9

		// Body shot through the real damage path, consumed like audio.
		testing.expect(t, shared.player_apply_damage(victim, client.me, 20, 0, false))
		client_audio_tick(&client, 0)
		marker := client.hit_marker
		testing.expect(t, marker.active && marker.color == 0xffffff && marker.length == 25 && marker.spacing == 37 && marker.opacity == 1, "body hits use the hit color")
		hit_marker_tick(&client.hit_marker, client.hitmarker_settings, 0.1)
		testing.expect(t, client.hit_marker.active && abs(client.hit_marker.spacing-51) < 0.01 && abs(client.hit_marker.opacity-0.38) < 0.01, "spacing grows 0.14 and opacity fades 0.0062 per ms")
		hit_marker_tick(&client.hit_marker, client.hitmarker_settings, 0.07)
		testing.expect(t, !client.hit_marker.active, "the marker expires once its opacity reaches zero")

		testing.expect(t, shared.player_apply_damage(victim, client.me, 20, 0, true))
		client_audio_tick(&client, 0)
		testing.expect(t, client.hit_marker.active && client.hit_marker.color == 0xffd000 && client.hit_marker.length == 25, "headshots use the headshot color")

		testing.expect(t, shared.player_apply_damage(victim, client.me, 1000, 0, true))
		client_audio_tick(&client, 0)
		testing.expect(t, client.hit_marker.color == 0xff0000 && abs(client.hit_marker.length-30) < 0.001, "kills use the kill color at 1.2x length, over headshot")

		// Damage the local player takes is not a hit.
		client.hit_marker = {}
		shared.player_spawn(victim, 2)
		testing.expect(t, shared.player_apply_damage(client.me, victim, 10, 0, false))
		client_audio_tick(&client, 0)
		testing.expect(t, !client.hit_marker.active, "only the local player's hits show a marker")

		client.hitmarker_settings.show = false
		testing.expect(t, shared.player_apply_damage(victim, client.me, 10, 0, false))
		client_audio_tick(&client, 0)
		testing.expect(t, !client.hit_marker.active, "Show hitmarkers off hides every marker")
		client.hitmarker_settings.show = true

		// Native multiplayer: server impacts on players fired by the local player.
		client_hit_marker_native_impact(&client, {kind = .World, shooter_uid = 7})
		client_hit_marker_native_impact(&client, {kind = .Player, shooter_uid = 9})
		testing.expect(t, !client.hit_marker.active, "world impacts and other shooters are not hits")
		client_hit_marker_native_impact(&client, {kind = .Player, shooter_uid = 7})
		testing.expect(t, client.hit_marker.active && client.hit_marker.color == 0xffffff, "a confirmed native impact shows a body marker")

		// Live: one marker per server DO_DAMAGE revision.
		client.hit_marker = {}
		client.krunker.connected = true
		client.krunker_world.hit_revision, client.krunker_world.hit_headshot = 3, true
		client_hit_marker_tick_live(&client)
		testing.expect(t, client.hit_marker.active && client.hit_marker.color == 0xffd000, "live headshot confirmations use the headshot color")
		client.hit_marker.active = false
		client_hit_marker_tick_live(&client)
		testing.expect(t, !client.hit_marker.active, "a revision shows only once")
		client.krunker.connected = false
	}

	@(test)
	hitmarker_pixels_and_preview :: proc(t: ^testing.T) {
		logger := context.logger
		context = runtime.default_context()
		context.logger = logger
		W :: 600
		H :: 200
		if !testing.expect(t, bool(glfw.Init())) do return
		defer glfw.Terminate()
		glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)
		glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 5)
		window := glfw.CreateWindow(W, H, "Hitmarker", nil, nil)
		if !testing.expect(t, window != nil) do return
		defer glfw.DestroyWindow(window)
		glfw.MakeContextCurrent(window)
		gl.load_up_to(4, 5, glfw.gl_set_proc_address)
		gl.Viewport(0, 0, W, H)
		gl.Enable(gl.BLEND)
		gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
		ui := ui_init()
		defer { ui_fini(ui); resource_cache_fini() }
		ui_update(ui, W, H)
		settings := menuui.DEFAULT_HITMARKER_SETTINGS
		settings.colors[.HEADSHOT] = 0xffd000
		gl.ClearColor(56.0/255, 61.0/255, 69.0/255, 1)
		ui_flush()
		gl.Clear(gl.COLOR_BUFFER_BIT)
		crosshair := menuui.DEFAULT_CROSSHAIR_SETTINGS
		for kind in 0..<3 {
			cx := f32(100 + kind*200)
			marker: Hit_Marker
			hit_marker_show(&marker, settings, kind == 2, kind == 1)
			crosshair_render(ui, crosshair, cx, 100, 1, 1)
			hit_marker_render(ui, marker, settings, cx, 100, 1)
		}
		pixel :: proc(x, y: int) -> (p: [3]u8) {
			ui_flush()
			gl.ReadPixels(i32(x), i32(H-1-y), 1, 1, gl.RGB, gl.UNSIGNED_BYTE, &p[0])
			return
		}
		// Bars are centered 37 px from the middle along each diagonal.
		testing.expect(t, pixel(100+26, 100-26) == [3]u8{255, 255, 255} && pixel(100-26, 100+26) == [3]u8{255, 255, 255}, "body hits draw white diagonal bars")
		testing.expect(t, pixel(300+26, 100+26) == [3]u8{255, 208, 0}, "headshots draw in the headshot color")
		testing.expect(t, pixel(500-26, 100-26) == [3]u8{255, 0, 0}, "kills draw in the kill color")
		testing.expect(t, pixel(100, 100-45) == [3]u8{56, 61, 69}, "bars are diagonal, leaving the vertical axis clear")
		testing.expect(t, pixel(100+12, 100-12) == [3]u8{56, 61, 69}, "spacing leaves the crosshair area clear")
		// Kill bars are 1.2x longer: 37+15 reaches past a body bar's 37+12.5.
		testing.expect(t, pixel(500+36, 100-36) == [3]u8{255, 0, 0} && pixel(100+36, 100-36) != [3]u8{255, 255, 255}, "kill bars are longer")
		os.make_directory("bin/hit_feedback")
		pixels := make([]u8, W*H*3)
		defer delete(pixels)
		gl.PixelStorei(gl.PACK_ALIGNMENT, 1)
		ui_flush()
		gl.ReadPixels(0, 0, W, H, gl.RGB, gl.UNSIGNED_BYTE, raw_data(pixels))
		testing.expect(t, stbi.write_png("bin/hit_feedback/hitmarkers.png", W, H, 3, &pixels[(H-1)*W*3], -W*3) != 0)
		testing.expect(t, gl.GetError() == gl.NO_ERROR)
	}
}
