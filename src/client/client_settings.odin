package main

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import menuui "../menu"

CLIENT_SETTINGS_PATH :: "client-settings.json"
Client_Settings :: struct {
	version: i32,
	display_mode, resolution_index, monitor_index: i32,
	fullscreen_width, fullscreen_height: i32, // 0 = the monitor's largest mode.
	sensitivity, mouse_dpi: f32,
	ads_sensitivity: f32,
	advanced_sensitivity, invert_mouse: bool,
	fov: f32,
	show_fps, vsync: bool,
	// Graphics API: false (the default, and files from before the option) is
	// Vulkan, true OpenGL. Read at startup only.
	opengl: bool,
	menu_fps_limit: i32, // menuui.MENU_FPS_LIMITS; 0 (the default) is the monitor's refresh rate.
	perf_overlay: bool, // The debug performance window (F3).
	bindings: menuui.Bindings,
	hud: menuui.HUD_Settings,
	visuals: menuui.Visual_Settings,
	quality: menuui.Quality_Settings,
	viewmodel: menuui.Viewmodel_Settings,
	trails: menuui.Trail_Settings,
	crosshair: menuui.Crosshair_Settings,
	hitmarker: menuui.Hitmarker_Settings,
	damage: menuui.Damage_Settings,
	// 0.24: Hide cats and Hide extra props became default on (comp players hide
	// them). Files saved before that lack this flag and get both turned on once.
	map_details_hidden_default: bool,
}

client_settings_defaults :: proc() -> Client_Settings {
	return {version = 1, map_details_hidden_default = true, fov = menuui.DEFAULT_FOV, sensitivity = 1, ads_sensitivity = 1, mouse_dpi = menuui.DEFAULT_MOUSE_DPI, bindings = menuui.default_bindings(), visuals = menuui.DEFAULT_VISUAL_SETTINGS, quality = menuui.DEFAULT_QUALITY_SETTINGS, viewmodel = menuui.DEFAULT_VIEWMODEL_SETTINGS, crosshair = menuui.DEFAULT_CROSSHAIR_SETTINGS, hitmarker = menuui.DEFAULT_HITMARKER_SETTINGS, damage = menuui.DEFAULT_DAMAGE_SETTINGS}
}

// The menu draft for a missing settings file, which Settings > Reset restores:
// the loader's defaults (client_settings_defaults through
// client_settings_validate) plus the audio defaults, shaped like menu_view.
client_settings_default_values :: proc(fullscreen_sizes: []Display_Resolution = nil, max_anisotropy: f32 = 16) -> menuui.Settings_Values {
	d := client_settings_validate(client_settings_defaults())
	audio := audio_settings_clamp(DEFAULT_AUDIO_SETTINGS)
	return {display_mode = d.display_mode, resolution_index = d.resolution_index, monitor_index = d.monitor_index,
		fullscreen_index = client_fullscreen_index(fullscreen_sizes, {d.fullscreen_width, d.fullscreen_height}),
		fov = d.fov, sensitivity = d.sensitivity, mouse_dpi = d.mouse_dpi, ads_sensitivity = d.ads_sensitivity,
		advanced_sensitivity = d.advanced_sensitivity, invert_mouse = d.invert_mouse,
		audio_volumes = {audio.master, audio.effects, audio.footsteps, audio.ui},
		show_fps = d.show_fps, vsync = d.vsync, vulkan = !d.opengl, menu_fps_limit = d.menu_fps_limit, bindings = d.bindings, hud = d.hud,
		visuals = d.visuals, quality = client_supported_quality(d.quality, max_anisotropy), viewmodel = d.viewmodel, trails = d.trails, crosshair = d.crosshair, hitmarker = d.hitmarker, damage = d.damage}
}

client_settings_validate :: proc(settings: Client_Settings) -> Client_Settings {
	result := settings
	result.fov = menuui.fov_validate(result.fov)
	result.mouse_dpi = menuui.mouse_dpi_validate(result.mouse_dpi)
	result.sensitivity = menuui.sensitivity_validate(result.sensitivity, result.mouse_dpi)
	result.ads_sensitivity = menuui.ads_sensitivity_validate(result.ads_sensitivity, result.sensitivity, result.mouse_dpi)
	result.display_mode = clamp(result.display_mode, 0, 2)
	result.resolution_index = clamp(result.resolution_index, 0, i32(len(DISPLAY_RESOLUTIONS))-1)
	result.monitor_index = max(0, result.monitor_index)
	if result.fullscreen_width <= 0 || result.fullscreen_height <= 0 { result.fullscreen_width, result.fullscreen_height = 0, 0 }
	result.visuals = menuui.visual_settings_validate(result.visuals)
	result.quality = menuui.quality_settings_validate(result.quality)
	result.menu_fps_limit = menuui.menu_fps_limit_validate(result.menu_fps_limit)
	result.viewmodel = menuui.viewmodel_settings_validate(result.viewmodel)
	result.crosshair = menuui.crosshair_settings_validate(result.crosshair)
	result.hitmarker = menuui.hitmarker_settings_validate(result.hitmarker)
	result.damage = menuui.damage_settings_validate(result.damage)
	defaults := menuui.default_bindings()
	for action in menuui.Binding_Action {
		for code, slot in result.bindings[action] {
			if !menuui.binding_valid(code) { result.bindings[action][slot] = defaults[action][slot] }
		}
		if result.bindings[action][0] == result.bindings[action][1] { result.bindings[action][1] = 0 }
	}
	return result
}

client_settings_load :: proc(path: string = CLIENT_SETTINGS_PATH) -> Client_Settings {
	settings := client_settings_defaults()
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil { return settings }
	defer delete(data)
	settings.map_details_hidden_default = false
	if json.unmarshal(data, &settings) != nil || settings.version != 1 {
		fmt.eprintln("[Settings] Invalid client preferences; using defaults.")
		return client_settings_defaults()
	}
	if !settings.map_details_hidden_default {
		settings.visuals.hide_cats, settings.visuals.hide_extra_props = true, true
		settings.map_details_hidden_default = true
	}
	return client_settings_validate(settings)
}

client_settings_snapshot :: proc(client: ^Client) -> Client_Settings {
	return {version = 1, map_details_hidden_default = true, display_mode = i32(client.display_mode), resolution_index = client.resolution_index, monitor_index = client.monitor_index,
		fullscreen_width = client.fullscreen_resolution.width, fullscreen_height = client.fullscreen_resolution.height,
		fov = client.camera.fov * 180 / math.PI, sensitivity = client.sensitivity, mouse_dpi = client.mouse_dpi, show_fps = client.show_fps, perf_overlay = client.perf_overlay, vsync = client.vsync, opengl = client.opengl, menu_fps_limit = client.menu_fps_limit, bindings = client.bindings, hud = client.hud_settings,
		ads_sensitivity = client.ads_sensitivity, advanced_sensitivity = client.advanced_sensitivity, invert_mouse = client.invert_mouse,
		visuals = client.visual_settings, quality = client.quality_settings, viewmodel = client.viewmodel_settings, trails = client.trail_settings, crosshair = client.crosshair_settings, hitmarker = client.hitmarker_settings, damage = client.damage_settings}
}

client_settings_save :: proc(settings: Client_Settings, path: string = CLIENT_SETTINGS_PATH) -> bool {
	data, err := json.marshal(client_settings_validate(settings))
	if err != nil { return false }
	defer delete(data)
	if os.write_entire_file(path, data) != nil { fmt.eprintln("[Settings] Could not save client preferences."); return false }
	return true
}
