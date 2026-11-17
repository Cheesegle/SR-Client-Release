package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:testing"
import menuui "../menu"
import shared "../shared"

when ODIN_TEST {
	@(test)
	night_mode_settings_default_and_persist :: proc(t: ^testing.T) {
		defaults := client_settings_defaults()
		testing.expect(t, !defaults.visuals.night_mode && defaults.visuals.night_strength == menuui.DEFAULT_NIGHT_STRENGTH && menuui.DEFAULT_NIGHT_STRENGTH == 0.7,
			"Night mode must default off, with strength 0.7")
		invalid := menuui.DEFAULT_VISUAL_SETTINGS
		invalid.night_strength = math.nan_f32()
		testing.expect(t, menuui.visual_settings_validate(invalid).night_strength == menuui.DEFAULT_NIGHT_STRENGTH, "a NaN night strength must fall back to the default")
		invalid.night_strength = 4
		testing.expect(t, menuui.visual_settings_validate(invalid).night_strength == 1, "night strength must stay within 0..1")
		invalid.night_strength = -1
		testing.expect(t, menuui.visual_settings_validate(invalid).night_strength == 0, "night strength must stay within 0..1")

		path := "bin/client-settings-night-test.json"
		defer os.remove(path)
		// Files written before Night mode existed load with it off.
		testing.expect(t, os.write_entire_file(path, `{"version":1,"visuals":{"hide_cats":true}}`) == nil)
		older := client_settings_load(path)
		testing.expect(t, !older.visuals.night_mode && older.visuals.night_strength == menuui.DEFAULT_NIGHT_STRENGTH && older.visuals.hide_cats,
			fmt.tprintf("older visuals must load with Night mode off and keep their other choices: %v", older.visuals))
		testing.expect(t, os.write_entire_file(path, `{"version":1}`) == nil)
		testing.expect(t, client_settings_load(path).visuals == menuui.DEFAULT_VISUAL_SETTINGS, "files without visuals must use the defaults")

		settings := client_settings_defaults()
		settings.visuals.night_mode, settings.visuals.night_strength = true, 0.35
		testing.expect(t, client_settings_save(settings, path))
		loaded := client_settings_load(path)
		testing.expect(t, loaded.visuals.night_mode && abs(loaded.visuals.night_strength - 0.35) < 1e-6, "Night mode and its strength must survive a restart")

		// The menu stages the toggle and slider (live preview); Cancel restores,
		// Save commits; Reset visuals turns night off.
		client := Client{visual_settings = menuui.DEFAULT_VISUAL_SETTINGS, quality_settings = menuui.DEFAULT_QUALITY_SETTINGS}
		view := menuui.View{visuals = client.visual_settings, quality = client.quality_settings}
		client.menu.page = .SETTINGS
		menuui.prepare_settings(&client.menu, view)
		menuui.activate(&client.menu, {action = {kind = .VISUAL_TOGGLE, index = 2}})
		menuui.activate(&client.menu, {action = {kind = .NIGHT_STRENGTH, value = 0.4}})
		preview, _ := client_graphics_values(&client)
		testing.expect(t, preview.night_mode && abs(preview.night_strength - 0.4) < 1e-6 && client.visual_settings == menuui.DEFAULT_VISUAL_SETTINGS,
			"Night mode must preview from the draft without changing saved settings")
		testing.expect(t, menuui.settings_slider_value(&client.menu, view, {kind = .NIGHT_STRENGTH}) == preview.night_strength, "the slider must show the staged strength")
		menuui.activate(&client.menu, {action = {kind = .NIGHT_STRENGTH, value = 3}})
		testing.expect(t, client.menu.settings_draft.visuals.night_strength == 1, "the night strength slider must clamp to 0..1")
		menuui.activate(&client.menu, {action = {kind = .SETTINGS_CANCEL}})
		reverted, _ := client_graphics_values(&client)
		testing.expect(t, reverted == menuui.DEFAULT_VISUAL_SETTINGS, "Cancel must restore night off")

		client.menu.page = .SETTINGS
		menuui.prepare_settings(&client.menu, view)
		menuui.activate(&client.menu, {action = {kind = .VISUAL_TOGGLE, index = 2}})
		menuui.activate(&client.menu, {action = {kind = .NIGHT_STRENGTH, value = 0.4}})
		menu_apply_action(&client, {kind = .SETTINGS_SAVE})
		testing.expect(t, client.visual_settings.night_mode && abs(client.visual_settings.night_strength - 0.4) < 1e-6 && client_settings_snapshot(&client).visuals == client.visual_settings,
			"Save must commit and persist Night mode")
		client.menu.page = .SETTINGS
		menuui.prepare_settings(&client.menu, menuui.View{visuals = client.visual_settings})
		menuui.activate(&client.menu, {action = {kind = .VISUAL_RESET}})
		testing.expect(t, !client.menu.settings_draft.visuals.night_mode && client.menu.settings_draft.visuals.night_strength == menuui.DEFAULT_NIGHT_STRENGTH, "Reset visuals must turn Night mode off")
	}

	@(test)
	night_lighting_transforms_the_map_environment :: proc(t: ^testing.T) {
		day := shared.DEFAULT_LIGHTING_CONFIG
		day.sun_angle_x, day.sun_angle_y, day.light_distance, day.shadow_distance = 70, 20, 800, 900
		testing.expect(t, night_lighting(day, 0) == day && night_lighting(day, -1) == day, "strength 0 must leave the map's lighting untouched")
		off := menuui.DEFAULT_VISUAL_SETTINGS
		low, unlit := night_tints(off)
		testing.expect(t, !night_active(off) && low == {1, 1, 1} && unlit == {1, 1, 1}, "night off must leave the shader tints white")
		zero := off
		zero.night_mode, zero.night_strength = true, 0
		low, unlit = night_tints(zero)
		testing.expect(t, !night_active(zero) && low == {1, 1, 1} && unlit == {1, 1, 1}, "strength 0 must leave the shader tints white")

		luma :: proc(c: shared.Vec3) -> f32 { return c.x*0.2126 + c.y*0.7152 + c.z*0.0722 }
		previous := day
		for strength in ([3]f32{0.3, 0.7, 1}) {
			night := night_lighting(day, strength)
			label := fmt.tprintf("strength %.1f", strength)
			testing.expect(t, night.sun_angle_x == day.sun_angle_x && night.sun_angle_y == day.sun_angle_y && night.light_distance == day.light_distance &&
				night.shadow_distance == day.shadow_distance && night.shadow_resolution == day.shadow_resolution && night.fog_distance == day.fog_distance,
				fmt.tprintf("%s: the moon must keep the sun's direction and shadow camera", label))
			testing.expect(t, luma(night.sky_color) < luma(previous.sky_color) && night.sky_color.z > night.sky_color.x, fmt.tprintf("%s: the sky must get darker and bluer", label))
			testing.expect(t, luma(night.fog_color) < luma(previous.fog_color) && night.fog_color.z > night.fog_color.x, fmt.tprintf("%s: the fog must get darker and bluer", label))
			testing.expect(t, luma(night.ambient_color) * night.ambient_intensity < luma(previous.ambient_color) * previous.ambient_intensity && night.ambient_color.z > night.ambient_color.x,
				fmt.tprintf("%s: ambient light must be lower and cooler", label))
			testing.expect(t, night.light_intensity < previous.light_intensity && night.light_intensity > 0 && night.light_color.z > night.light_color.x,
				fmt.tprintf("%s: the sun must become a dim, cool moon", label))
			previous = night
		}
		full := night_lighting(day, 1)
		testing.expect(t, full.sky_color.z < 0.25 && luma(full.sky_color) < 0.12, fmt.tprintf("full night must have a dark blue sky: %v", full.sky_color))
		testing.expect(t, sun_casts_light(full), "the moon must still cast shadows")
		// A map that is already dark keeps a floor of ambient light.
		dark := day
		dark.ambient_color, dark.ambient_intensity = {0.4, 0.4, 0.4}, 0.5
		dark_night := night_lighting(dark, 1)
		testing.expect(t, abs(luma(dark.ambient_color) * dark_night.ambient_intensity - NIGHT_AMBIENT_FLOOR) < 1e-4, "dark maps must keep the ambient floor")
		black := day
		black.light_color = {}
		testing.expect(t, night_lighting(black, 1).light_color == {}, "a map without sunlight must not gain a moon")
		on := off
		on.night_mode, on.night_strength = true, 1
		low, unlit = night_tints(on)
		testing.expect(t, abs(luma(low - NIGHT_LOW_TINT)) < 1e-5 && abs(luma(unlit - NIGHT_UNLIT_TINT)) < 1e-5 && low.z > low.x && luma(unlit) > luma(low),
			"Lighting Low must dim and cool lit materials, and emissive ones less")
	}
}
