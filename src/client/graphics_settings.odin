package main

import "core:math"
import menuui "../menu"
import shared "../shared"

// These affect only scene materials; UI colors and font sampling stay unchanged.
g_visual_settings := menuui.DEFAULT_VISUAL_SETTINGS

client_graphics_init :: proc(client: ^Client) {
	client.max_anisotropy = gpu_max_anisotropy()
	// Always Sharp (nearest, nearest mip): Krunker's pixelated look.
	client.graphics_sampler = gpu_sampler_create(GPU_SAMPLER_WORLD)
}

client_graphics_fini :: proc(client: ^Client) {
	gpu_sampler_destroy(&client.graphics_sampler)
}

client_graphics_values :: proc(client: ^Client) -> (visuals: menuui.Visual_Settings, quality: menuui.Quality_Settings) {
	visuals, quality = client.visual_settings, client.quality_settings
	if client.menu.settings_active && (client.menu.page == .SETTINGS || client.menu.page == .CONTROLS) {
		visuals, quality = client.menu.settings_draft.visuals, client.menu.settings_draft.quality
	}
	return
}

client_supported_quality :: proc(settings: menuui.Quality_Settings, max_anisotropy: f32) -> menuui.Quality_Settings {
	result := menuui.quality_settings_validate(settings)
	requested := result.anisotropy
	result.anisotropy = 0
	for level in ([4]i32{2, 4, 8, 16}) {
		if level <= requested && f32(level) <= max_anisotropy { result.anisotropy = level }
	}
	return result
}

// Keep background correction in step with basic.frag; HUD is drawn afterwards.
visual_adjust_color :: proc(color: shared.Vec3, visuals: menuui.Visual_Settings) -> shared.Vec3 {
	rgb := (color * visuals.values[.BRIGHTNESS] - shared.Vec3{0.5,0.5,0.5}) * visuals.values[.CONTRAST] + shared.Vec3{0.5,0.5,0.5}
	luma := rgb.x*0.2126 + rgb.y*0.7152 + rgb.z*0.0722
	rgb = shared.Vec3{luma,luma,luma} + (rgb - shared.Vec3{luma,luma,luma}) * visuals.values[.SATURATION]
	for &value in rgb { value = math.pow(clamp(value, 0, 1), 1 / visuals.values[.GAMMA]) }
	return rgb
}

client_update_graphics :: proc(client: ^Client) {
	visuals, quality := client_graphics_values(client)
	g_visual_settings = menuui.visual_settings_validate(visuals)
	client_update_map_details(client, g_visual_settings)
	base := shared.DEFAULT_LIGHTING_CONFIG
	if client.game.map_inst != nil { base = client.game.map_inst.lighting }
	g_lighting_config = base
	// Night mode rewrites only this per-frame copy; off, it is never called.
	if night_active(g_visual_settings) { g_lighting_config = night_lighting(base, g_visual_settings.night_strength) }
	g_night_low_tint, g_night_unlit_tint = night_tints(g_visual_settings)
	sky := visual_adjust_color(g_lighting_config.sky_color, g_visual_settings)
	gpu_set_clear_color(sky.xyz)
	if client.graphics_sampler == 0 { return }
	quality = menuui.quality_settings_validate(quality)
	if client.graphics_sampler_ready && client.graphics_quality == quality { return }
	client.graphics_quality, client.graphics_sampler_ready = quality, true
	gpu_sampler_set_filter(client.graphics_sampler, quality.smooth_textures ? .Linear : .Nearest)
	gpu_sampler_set_anisotropy(client.graphics_sampler, f32(quality.anisotropy))
}
