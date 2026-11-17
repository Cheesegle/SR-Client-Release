package main

import "base:runtime"
import "core:math"
import "core:os"
import "core:strings"
import "core:testing"
import gl "vendor:OpenGL"
import glfw "vendor:glfw"
import stbi "vendor:stb/image"
import menuui "../menu"
import shared "../shared"
import kproto "../krunker"

when ODIN_TEST {
	@(test)
	damage_settings_default_and_persist :: proc(t: ^testing.T) {
		defaults := client_settings_defaults().damage
		testing.expect(t, defaults.toggles[.OVERLAY] && defaults.toggles[.INDICATORS], "Krunker turns on Use Damage Overlay and Show Hit Indicators by default")
		testing.expect(t, defaults.colors[.INDICATOR] == 0xff3f3f && defaults.colors[.OVERLAY] == 0xc04646, "Krunker's hitColor #FF3F3F and blood.png's tint")
		testing.expect(t, defaults.values == [menuui.Damage_Control]f32{.OVERLAY_INTENSITY=1, .FLASH_DURATION=0.3, .INDICATOR_DURATION=2}, "full intensity and Krunker's 2 s indicators")
		path := "bin/client-settings-damage-test.json"
		defer os.remove(path)
		legacy := `{"version":1,"hud":{"hide_timer":true}}`
		testing.expect(t, os.write_entire_file(path, transmute([]u8)legacy) == nil)
		testing.expect(t, client_settings_load(path).damage == menuui.DEFAULT_DAMAGE_SETTINGS, "older settings files get the defaults")
		changed := client_settings_defaults()
		changed.damage.toggles[.INDICATORS] = false
		changed.damage.values[.OVERLAY_INTENSITY], changed.damage.values[.FLASH_DURATION] = 0.5, 0
		changed.damage.colors[.OVERLAY] = 0x3366ff
		testing.expect(t, client_settings_save(changed, path))
		testing.expect(t, client_settings_load(path).damage == changed.damage, "damage settings must survive a restart")
		bad := menuui.DEFAULT_DAMAGE_SETTINGS
		bad.values[.INDICATOR_DURATION], bad.values[.OVERLAY_INTENSITY], bad.values[.FLASH_DURATION] = 0, 4, math.nan_f32()
		bad = menuui.damage_settings_validate(bad)
		testing.expect(t, bad.values == [menuui.Damage_Control]f32{.OVERLAY_INTENSITY=1, .FLASH_DURATION=0.3, .INDICATOR_DURATION=0.25}, "values clamp to their ranges")
	}

	@(test)
	damage_settings_draft_cancel_and_import :: proc(t: ^testing.T) {
		client := Client{damage_settings = menuui.DEFAULT_DAMAGE_SETTINGS}
		client.menu.page = .SETTINGS
		menuui.prepare_settings(&client.menu, {damage = client.damage_settings})
		menuui.activate(&client.menu, {action = {kind = .DAMAGE_TOGGLE, index = i32(menuui.Damage_Toggle.OVERLAY)}})
		menuui.activate(&client.menu, {action = {kind = .DAMAGE_VALUE, index = i32(menuui.Damage_Control.INDICATOR_DURATION), value = 1}})
		menuui.settings_color_begin(&client.menu, menuui.DAMAGE_COLOR_FIELDS[.INDICATOR])
		client.menu.color_length = copy(client.menu.color_buffer[:], "#00FF00")
		testing.expect(t, menuui.settings_color_commit(&client.menu))
		preview := client_damage_values(&client)
		testing.expect(t, !preview.toggles[.OVERLAY] && preview.values[.INDICATOR_DURATION] == 1 && preview.colors[.INDICATOR] == 0x00ff00, "the draft previews in game")
		testing.expect(t, client.damage_settings == menuui.DEFAULT_DAMAGE_SETTINGS, "editing must not commit before Save")
		menuui.activate(&client.menu, {action = {kind = .SETTINGS_CANCEL}})
		testing.expect(t, client_damage_values(&client) == menuui.DEFAULT_DAMAGE_SETTINGS, "Cancel restores the committed settings")

		values := menuui.Settings_Values{damage = menuui.DEFAULT_DAMAGE_SETTINGS}
		values.damage.values[.OVERLAY_INTENSITY] = 0.4
		result, err := menuui.krunker_settings_import(&values, `{"showHitInd":false,"hitColor":"#00ff00","useDamageOverlay":false}`)
		testing.expect(t, len(err) == 0 && result.imported == 3 && result.ignored == 0, "Krunker's three damage keys import")
		d := values.damage
		testing.expect(t, !d.toggles[.INDICATORS] && !d.toggles[.OVERLAY] && d.colors[.INDICATOR] == 0x00ff00 && d.values[.OVERLAY_INTENSITY] == 0.4, "imports keep SR Client's own values")
		exported := menuui.krunker_settings_export(values, context.temp_allocator)
		testing.expect(t, strings.contains(exported, `"showHitInd":false`) && strings.contains(exported, `"hitColor":"#00ff00"`) && strings.contains(exported, `"useDamageOverlay":false`), "export writes changed damage keys")
		exported = menuui.krunker_settings_export({damage = menuui.DEFAULT_DAMAGE_SETTINGS}, context.temp_allocator)
		testing.expect(t, !strings.contains(exported, "HitInd") && !strings.contains(exported, "Damage"), "defaults are not exported")
	}

	@(test)
	damage_overlay_alpha_follows_health_and_flash :: proc(t: ^testing.T) {
		settings := menuui.DEFAULT_DAMAGE_SETTINGS
		testing.expect(t, damage_overlay_alpha(settings, 100, 100, true, 0) == 0 && damage_overlay_alpha(settings, 80, 100, true, 0) == 0, "Krunker shows nothing at 80% health or more")
		testing.expect(t, abs(damage_overlay_alpha(settings, 40, 100, true, 0)-0.5) < 0.0001 && damage_overlay_alpha(settings, 0, 100, true, 0) == 1, "opacity is 1 - health/0.8")
		testing.expect(t, damage_overlay_alpha(settings, 10, 100, false, 0) == 0, "the overlay clears on death")
		testing.expect(t, abs(damage_overlay_alpha(settings, 100, 100, true, 0.3)-DAMAGE_FLASH_PEAK) < 0.0001 && abs(damage_overlay_alpha(settings, 100, 100, true, 0.15)-DAMAGE_FLASH_PEAK*0.5) < 0.0001, "the flash fades over its duration")
		testing.expect(t, abs(damage_overlay_alpha(settings, 40, 100, true, 0.3)-DAMAGE_FLASH_PEAK) < 0.0001, "the stronger of health and flash wins")
		settings.values[.OVERLAY_INTENSITY] = 0.5
		testing.expect(t, abs(damage_overlay_alpha(settings, 40, 100, true, 0)-0.25) < 0.0001, "intensity scales the overlay")
		settings.values[.FLASH_DURATION] = 0
		testing.expect(t, damage_overlay_alpha(settings, 100, 100, true, 0.2) == 0, "a zero flash duration turns the flash off")
		settings.toggles[.OVERLAY] = false
		testing.expect(t, damage_overlay_alpha(settings, 0, 100, true, 0) == 0, "Use Damage Overlay off hides it")

		pixels := damage_vignette_pixels(context.temp_allocator)
		at :: proc(pixels: []u8, x, y: int) -> [4]u8 { i := (y*DAMAGE_VIGNETTE_SIZE+x)*4; return {pixels[i], pixels[i+1], pixels[i+2], pixels[i+3]} }
		edge, center := at(pixels, 0, 128), at(pixels, 128, 128)
		testing.expect(t, edge[3] >= 205 && edge[3] <= 220 && center[3] == 30, "alpha follows blood.png: about 215 at the edge, 30 in the middle")
		testing.expect(t, center[0] == 255 && edge[0] >= 105 && edge[0] <= 120, "edges are darker than the center")
		testing.expect(t, at(pixels, 4, 4)[3] > edge[3], "corners are strongest")
	}

	@(test)
	damage_indicators_offline_live_and_direction :: proc(t: ^testing.T) {
		up, ok := damage_indicator_direction({0, 0, 0}, 0, {0, -50})
		testing.expect(t, ok && abs(up.x) < 0.0001 && abs(up.y+1) < 0.0001, "an attacker straight ahead points up")
		right, _ := damage_indicator_direction({0, 0, 0}, 0, {50, 0})
		testing.expect(t, abs(right.x-1) < 0.0001 && abs(right.y) < 0.0001, "an attacker to the right points right")
		behind, _ := damage_indicator_direction({10, 0, 10}, math.PI/2, {60, 10})
		testing.expect(t, abs(behind.x) < 0.0001 && abs(behind.y-1) < 0.0001, "facing -x, an attacker at +x is behind")
		_, same := damage_indicator_direction({1, 2, 3}, 0, {1, 3})
		testing.expect(t, !same, "no direction when the attacker shares the position")

		client: Client
		map_inst: shared.Map
		krunker_presentation_fixture(&client, &map_inst)
		defer krunker_presentation_cleanup(&client)
		client.damage_settings = menuui.DEFAULT_DAMAGE_SETTINGS
		client.game.presentation_enabled = true
		attacker := shared.player_init(&client.game)
		shared.game_players_add(&client.game, attacker)
		shared.player_spawn(attacker, 2)
		attacker.uid, attacker.position = 9, {30, 0, -40}

		// Hitting someone else is not damage taken.
		testing.expect(t, shared.player_apply_damage(attacker, client.me, 10, 0, false))
		client_audio_tick(&client, 0)
		testing.expect(t, client.damage_feedback.flash == 0 && client.damage_feedback.indicators[0].life == 0, "the local player's own hits do not flash")

		testing.expect(t, shared.player_apply_damage(client.me, attacker, 30, 0, false))
		client_audio_tick(&client, 0)
		feedback := client.damage_feedback
		testing.expect(t, feedback.flash == 0.3, "damage starts the flash")
		testing.expect(t, feedback.indicators[0].life == 2 && feedback.indicators[0].source == [2]f32{30, -40}, "the indicator records the attacker's x/z")
		damage_feedback_tick(&client.damage_feedback, 1.5)
		testing.expect(t, client.damage_feedback.flash == 0 && client.damage_feedback.indicators[0].life == 0.5, "flash and indicator expire independently")
		damage_feedback_tick(&client.damage_feedback, 0.6)
		testing.expect(t, client.damage_feedback.indicators[0].life == 0, "indicators expire after their duration")

		client.damage_settings.toggles[.INDICATORS] = false
		testing.expect(t, shared.player_apply_damage(client.me, attacker, 10, 0, false))
		client_audio_tick(&client, 0)
		for indicator in client.damage_feedback.indicators { testing.expect(t, indicator.life == 0, "Show Hit Indicators off adds none") }
		client.damage_settings.toggles[.INDICATORS] = true

		// Live: CHANGE_HEALTH(health, sid, x, z, silent, reset max).
		client.damage_feedback = {}
		client.krunker.connected = true
		world := &client.krunker_world
		testing.expect(t, kproto.krunker_world_apply_packet(world, []kproto.Krunker_Msgpack_Value{"h", f64(100)}))
		testing.expect(t, kproto.krunker_world_apply_packet(world, []kproto.Krunker_Msgpack_Value{"h", f64(70), kproto.Krunker_Msgpack_Nil{}, f64(5), f64(-80)}))
		testing.expect(t, world.damage_revision == 1 && world.damage_source == [2]f32{5, -80}, "a local drop with a position is a hit indicator")
		kproto.krunker_world_apply_packet(world, []kproto.Krunker_Msgpack_Value{"h", f64(60), kproto.Krunker_Msgpack_Nil{}, f64(5), f64(-80), true})
		kproto.krunker_world_apply_packet(world, []kproto.Krunker_Msgpack_Value{"h", f64(50)})
		kproto.krunker_world_apply_packet(world, []kproto.Krunker_Msgpack_Value{"h", f64(90), kproto.Krunker_Msgpack_Nil{}, f64(5), f64(-80)})
		kproto.krunker_world_apply_packet(world, []kproto.Krunker_Msgpack_Value{"h", f64(10), i64(99), f64(5), f64(-80)})
		testing.expect(t, world.damage_revision == 1, "silent drops, drops without a position, heals and other players add none")
		client_audio_tick(&client, 0)
		testing.expect(t, client.damage_feedback.indicators[0].source == [2]f32{5, -80} && client.damage_feedback.flash > 0, "the live drop flashes and adds its indicator")
		client.damage_feedback.indicators[0].life = 0
		client_audio_tick(&client, 0)
		testing.expect(t, client.damage_feedback.indicators[0].life == 0, "a revision shows only once")
		client.krunker.connected = false
	}

	@(test)
	damage_overlay_pixels_and_preview :: proc(t: ^testing.T) {
		logger := context.logger
		context = runtime.default_context()
		context.logger = logger
		W :: 1280
		H :: 360
		if !testing.expect(t, bool(glfw.Init())) do return
		defer glfw.Terminate()
		glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)
		glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 5)
		window := glfw.CreateWindow(W, H, "Damage borders", nil, nil)
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
		testing.expect(t, ui.vignette != 0, "the overlay texture is created with the UI")
		gl.ClearColor(120.0/255, 140.0/255, 160.0/255, 1)
		gl.Clear(gl.COLOR_BUFFER_BIT)
		// Left: Krunker defaults at 40% health, hit from the front right.
		// Right: SR Client custom colors mid-flash, hit from behind.
		custom := menuui.DEFAULT_DAMAGE_SETTINGS
		custom.colors = {.OVERLAY = 0x7a2cff, .INDICATOR = 0x30c0ff}
		custom.values[.OVERLAY_INTENSITY] = 0.8
		panels := [2]menuui.Damage_Settings{menuui.DEFAULT_DAMAGE_SETTINGS, custom}
		radius := f32(H)*0.25 - 83*0.5
		for settings, i in panels {
			x := f32(i*W/2)
			alpha := i == 0 ? damage_overlay_alpha(settings, 40, 100, true, 0) : damage_overlay_alpha(settings, 100, 100, true, 0.2)
			damage_overlay_render(ui, settings.colors[.OVERLAY], alpha, x, 0, W/2, H)
			direction := i == 0 ? shared.Vec2{math.SQRT_TWO*0.5, -math.SQRT_TWO*0.5} : shared.Vec2{0, 1}
			damage_indicator_render(ui, settings.colors[.INDICATOR], i == 0 ? 1 : 0.7, x+W/4, H/2, radius, 0.5, direction)
		}
		pixel :: proc(x, y: int) -> (p: [3]u8) {
			gl.ReadPixels(i32(x), i32(H-1-y), 1, 1, gl.RGB, gl.UNSIGNED_BYTE, &p[0])
			return
		}
		edge, middle := pixel(2, H/2), pixel(W/4, H/2+40)
		// The background is (120, 140, 160): blue leads red by 40.
		testing.expect(t, int(edge[2])-int(edge[0]) < 15 && edge[2] < 125, "the screen edge darkens toward red")
		testing.expect(t, middle[2] >= 140 && middle[0] <= 135, "the middle stays mostly clear")
		tip := shared.Vec2{f32(W/4), f32(H/2)} + shared.Vec2{math.SQRT_TWO*0.5, -math.SQRT_TWO*0.5}*(radius - 20*0.5)
		hit := pixel(int(tip.x), int(tip.y))
		testing.expect(t, hit[0] == 255 && hit[1] < 80 && hit[2] < 80, "the indicator points toward the attacker in hitColor")
		opposite := shared.Vec2{f32(W/4), f32(H/2)} - shared.Vec2{math.SQRT_TWO*0.5, -math.SQRT_TWO*0.5}*(radius - 20*0.5)
		testing.expect(t, pixel(int(opposite.x), int(opposite.y))[0] < 200, "nothing is drawn away from the attacker")
		below := pixel(3*W/4, H/2+int(radius-10))
		testing.expect(t, below[2] > below[0], "custom indicator color, below for an attacker behind")
		os.make_directory("bin/hit_feedback")
		pixels := make([]u8, W*H*3)
		defer delete(pixels)
		gl.PixelStorei(gl.PACK_ALIGNMENT, 1)
		gl.ReadPixels(0, 0, W, H, gl.RGB, gl.UNSIGNED_BYTE, raw_data(pixels))
		testing.expect(t, stbi.write_png("bin/hit_feedback/damage_borders.png", W, H, 3, &pixels[(H-1)*W*3], -W*3) != 0)
		testing.expect(t, gl.GetError() == gl.NO_ERROR)
	}
}
