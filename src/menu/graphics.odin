package menu

import "core:math"
import "core:fmt"
import clay "../third_party/clay"

// Keep the final legacy entry for existing settings files; it is never editable.
Visual_Control :: enum { BRIGHTNESS, GAMMA, CONTRAST, SATURATION, AMBIENT, SUNLIGHT, FOG_DISTANCE }
Visual_Color :: enum { AMBIENT, SUNLIGHT, FOG, SKY }
Visual_Settings :: struct {
	values: [Visual_Control]f32,
	// Legacy settings are decoded for compatibility, then reset and ignored.
	color_override: [Visual_Color]bool,
	colors: [Visual_Color][3]f32,
	hide_cats, hide_extra_props: bool,
	// SR Client's night mode (not in Krunker): a moonlit transform of each map's
	// own lighting. night_strength 0..1 scales it; 0 or off renders as before.
	night_mode:     bool,
	night_strength: f32,
}
DEFAULT_NIGHT_STRENGTH :: 0.7
// Krunker's Settings > Video quality options (Krunker's client settings
// list): "Shadows" (shadows, default on), its advanced "Soft Shadows"
// (softShad), "High-Res Shadows" (highResShad) and "Dynamic Shadows"
// (shadowsDynamic), all default off, and "Lighting" (lighting): 0 Low,
// 1 Normal (default), 2 High, 3 Physical.
Quality_Settings :: struct {
	smooth_textures: bool,
	anisotropy:      i32, // 0 = off; otherwise 2, 4, 8 or 16.
	shadows, soft_shadows, high_res_shadows, dynamic_shadows: bool,
	lighting:        i32,
	// SR Client additions, beyond Krunker parity.
	shadow_quality:  i32,  // Shadow_Quality: 0 Krunker (whole-map map), 1 Sharp (cascades).
	self_shadow:     bool, // Your own body casts a shadow (default on).
	// MSAA sample count for the world and viewmodel (the interface is never
	// multisampled): 0 = off, else 2, 4 or 8. Applies immediately.
	msaa:            i32,
}
Shadow_Quality :: enum i32 { KRUNKER, SHARP }
SHADOW_QUALITY_LABELS := [Shadow_Quality]string{.KRUNKER = "Krunker", .SHARP = "Sharp"}
Lighting_Quality :: enum i32 { LOW, NORMAL, HIGH, PHYSICAL }
DEFAULT_QUALITY_SETTINGS :: Quality_Settings{shadows = true, lighting = i32(Lighting_Quality.NORMAL), shadow_quality = i32(Shadow_Quality.KRUNKER), self_shadow = true}
LIGHTING_LABELS := [Lighting_Quality]string{.LOW = "Low", .NORMAL = "Normal", .HIGH = "High", .PHYSICAL = "Physical"}
Quality_Toggle :: enum { SHADOWS, SOFT_SHADOWS, HIGH_RES_SHADOWS, DYNAMIC_SHADOWS, SELF_SHADOW }

DEFAULT_VISUAL_SETTINGS :: Visual_Settings{values = {.BRIGHTNESS=1, .GAMMA=1, .CONTRAST=1, .SATURATION=1, .AMBIENT=1, .SUNLIGHT=1, .FOG_DISTANCE=1}, colors = {.AMBIENT={1,1,1}, .SUNLIGHT={1,1,1}, .FOG={1,1,1}, .SKY={1,1,1}}, hide_cats = true, hide_extra_props = true, night_strength = DEFAULT_NIGHT_STRENGTH}
VISUAL_LABELS := #partial [Visual_Control]string{.BRIGHTNESS="Brightness", .GAMMA="Gamma", .CONTRAST="Contrast", .SATURATION="Saturation", .AMBIENT="Ambient strength", .SUNLIGHT="Sunlight strength"}
VISUAL_LIMITS := [Visual_Control][2]f32{.BRIGHTNESS={0.5,1.5}, .GAMMA={0.5,2}, .CONTRAST={0.5,1.5}, .SATURATION={0,2}, .AMBIENT={0,2}, .SUNLIGHT={0,2}, .FOG_DISTANCE={1,1}}
ANISOTROPY_LEVELS := [5]i32{0, 2, 4, 8, 16}
MSAA_LEVELS := [4]i32{0, 2, 4, 8}
MSAA_LABELS := [4]string{"Off", "2x", "4x", "8x"}
msaa_index :: proc(samples: i32) -> i32 {
	for value, i in MSAA_LEVELS { if value == samples { return i32(i) } }
	return 0
}
// Frame cap while the cursor is free (menus, loading, end screen); gameplay is
// never capped. Stored as frames per second: 0 is the monitor's refresh rate,
// so settings files without the key keep the default, and -1 is unlimited.
MENU_FPS_LIMIT_MONITOR :: 0
MENU_FPS_LIMIT_UNLIMITED :: -1
MENU_FPS_LIMITS := [7]i32{MENU_FPS_LIMIT_MONITOR, 30, 60, 120, 144, 240, MENU_FPS_LIMIT_UNLIMITED}
MENU_FPS_LIMIT_LABELS := [7]string{"Monitor refresh", "30", "60", "120", "144", "240", "Unlimited"}

visual_settings_validate :: proc(settings: Visual_Settings) -> Visual_Settings {
	result := settings
	for control in Visual_Control {
		value := result.values[control]
		if math.is_nan(value) || math.is_inf(value) { value = 1 }
		result.values[control] = clamp(value, VISUAL_LIMITS[control][0], VISUAL_LIMITS[control][1])
	}
	result.values[.FOG_DISTANCE] = 1
	result.color_override = {}
	result.colors = DEFAULT_VISUAL_SETTINGS.colors
	if math.is_nan(result.night_strength) || math.is_inf(result.night_strength) { result.night_strength = DEFAULT_NIGHT_STRENGTH }
	result.night_strength = clamp(result.night_strength, 0, 1)
	return result
}

// In-game frame cap (Krunker's Frame Cap). 0 is unlimited, the default.
GAME_FPS_LIMITS := [10]i32{0, 60, 120, 144, 165, 240, 300, 360, 500, 1000}
GAME_FPS_LIMIT_LABELS := [10]string{"Unlimited", "60", "120", "144", "165", "240", "300", "360", "500", "1000"}
game_fps_limit_index :: proc(limit: i32) -> i32 {
	for value, i in GAME_FPS_LIMITS { if value == limit { return i32(i) } }
	return 0
}
game_fps_limit_validate :: proc(limit: i32) -> i32 { return GAME_FPS_LIMITS[game_fps_limit_index(limit)] }

settings_game_fps_limit_row :: proc(state: ^State) {
	if !settings_search_show(state, "FPS limit") { return }
	if clay.UI(clay.ID("GameFpsLimitRow"))(settings_row(state)) {
		settings_label("FPS limit", state.scale)
		spacer()
		settings_dropdown_field(state, GAME_FPS_LIMIT_LABELS[game_fps_limit_index(state.settings_draft.hud.fps_limit)], "GameFpsLimit", .GAME_FPS_LIMIT)
	}
}

menu_fps_limit_index :: proc(limit: i32) -> i32 {
	for value, i in MENU_FPS_LIMITS { if value == limit { return i32(i) } }
	return 0
}

// Unknown values fall back to the monitor's refresh rate.
menu_fps_limit_validate :: proc(limit: i32) -> i32 { return MENU_FPS_LIMITS[menu_fps_limit_index(limit)] }

// V-Sync with VRR: frames are held 3-5 FPS under the refresh rate so the
// display keeps refreshing on each frame (client vrr.odin).
VRR_CAP_LABELS := [3]string{"Auto", "Always", "Off"}

settings_vrr_cap_row :: proc(state: ^State, view: View) {
	if !settings_search_show(state, "VRR cap") { return }
	if clay.UI(clay.ID("VrrCapRow"))(settings_row(state)) {
		settings_label("VRR cap", state.scale)
		spacer()
		settings_dropdown_field(state, VRR_CAP_LABELS[clamp(state.settings_draft.hud.vrr_cap, 0, len(VRR_CAP_LABELS) - 1)], "VrrCap", .VRR_CAP)
	}
	if len(view.vrr_status) > 0 { settings_note(state, view.vrr_status) }
}

settings_menu_fps_limit_row :: proc(state: ^State) {
	if !settings_search_show(state, "Menu FPS limit") { return }
	if clay.UI(clay.ID("MenuFpsLimitRow"))(settings_row(state)) {
		settings_label("Menu FPS limit", state.scale)
		spacer()
		settings_dropdown_field(state, MENU_FPS_LIMIT_LABELS[menu_fps_limit_index(state.settings_draft.menu_fps_limit)], "MenuFpsLimit", .MENU_FPS_LIMIT)
	}
}

quality_settings_validate :: proc(settings: Quality_Settings) -> Quality_Settings {
	result := settings
	switch result.anisotropy { case 0, 2, 4, 8, 16: case: result.anisotropy = 0 }
	result.msaa = MSAA_LEVELS[msaa_index(result.msaa)]
	if result.lighting < i32(Lighting_Quality.LOW) || result.lighting > i32(Lighting_Quality.PHYSICAL) { result.lighting = DEFAULT_QUALITY_SETTINGS.lighting }
	if result.shadow_quality < 0 || result.shadow_quality > i32(Shadow_Quality.SHARP) { result.shadow_quality = DEFAULT_QUALITY_SETTINGS.shadow_quality }
	return result
}

settings_visuals :: proc(state: ^State) {
	settings_note(state, "Graphics preview live. Save keeps your changes; Cancel restores them.")
	settings_section(state, "Image")
	for control in Visual_Control {
		if control == .FOG_DISTANCE { continue }
		if control == .AMBIENT { settings_section(state, "Lighting") }
		settings_slider(state, VISUAL_LABELS[control], fmt.tprintf("Visual%d", int(control)), state.settings_draft.visuals.values[control],
			VISUAL_LIMITS[control][0], VISUAL_LIMITS[control][1], {kind = .VISUAL_VALUE, index = i32(control)})
	}
	settings_note(state, "Lighting strength multiplies each map's original values. 1.00 preserves the map defaults.")
	settings_section(state, "Map details")
	settings_toggle_row(state, "Hide cats", "HideCats", state.settings_draft.visuals.hide_cats, {kind=.VISUAL_TOGGLE, index=0})
	settings_toggle_row(state, "Hide extra props", "HideExtraProps", state.settings_draft.visuals.hide_extra_props, {kind=.VISUAL_TOGGLE, index=1})
	settings_note(state, "Hide extra props removes loose rubble, planks, fabric and grass. Cats have their own toggle.")
	settings_note(state, "Reset restores the original appearance of every map.")
	if settings_search_show(state, "Reset visuals") { settings_button(state, "Reset visuals", "ResetVisuals", {kind = .VISUAL_RESET}) }
}

// SR Client's night mode (Settings > Experimental).
settings_night :: proc(state: ^State) {
	settings_section(state, "Night")
	settings_toggle_row(state, "Night mode", "NightMode", state.settings_draft.visuals.night_mode, {kind=.VISUAL_TOGGLE, index=2})
	settings_slider(state, "Night strength", "NightStrength", state.settings_draft.visuals.night_strength, 0, 1, {kind = .NIGHT_STRENGTH})
	settings_note(state, "Night mode turns every map into a moonlit night: a dark blue sky and fog, and dim, cool light. Map lights still glow. Night strength sets how dark it gets.")
}

settings_quality :: proc(state: ^State, view: View) {
	settings_section(state, "Quality")
	if settings_search_show(state, "Texture filtering") {
		if clay.UI(clay.ID("TextureFilteringRow"))(settings_row(state)) {
			settings_label("Texture filtering", state.scale)
			spacer()
			settings_dropdown_field(state, state.settings_draft.quality.smooth_textures ? "Smooth" : "Sharp", "TextureFiltering", .TEXTURE_FILTER)
		}
	}
	if settings_search_show(state, "Anisotropic filtering") {
		if clay.UI(clay.ID("AnisotropyRow"))(settings_row(state)) {
			settings_label("Anisotropic filtering", state.scale)
			spacer()
			label := view.max_anisotropy < 2 ? "Unavailable" : state.settings_draft.quality.anisotropy < 2 ? "Off" : fmt.tprintf("%dx", state.settings_draft.quality.anisotropy)
			settings_dropdown_field(state, label, "Anisotropy", .ANISOTROPY, view.max_anisotropy >= 2)
		}
	}
	settings_note(state, "Sharp keeps the pixelated texture style. Smooth blends texels. Anisotropic filtering improves textures viewed at an angle.")
	if settings_search_show(state, "Anti-aliasing") {
		if clay.UI(clay.ID("MsaaRow"))(settings_row(state)) {
			settings_label("Anti-aliasing (MSAA)", state.scale)
			spacer()
			label := view.max_msaa < 2 ? "Unavailable" : MSAA_LABELS[msaa_index(state.settings_draft.quality.msaa)]
			settings_dropdown_field(state, label, "Msaa", .MSAA, view.max_msaa >= 2)
		}
	}
	settings_note(state, "Anti-aliasing smooths the edges of the world and your weapon; the HUD and menus stay sharp. Higher levels cost more FPS.")
	quality := state.settings_draft.quality
	settings_toggle_row(state, "Shadows", "QualityShadows", quality.shadows, {kind=.QUALITY_TOGGLE, index=i32(Quality_Toggle.SHADOWS)})
	settings_toggle_row(state, "Soft Shadows", "QualitySoftShadows", quality.soft_shadows, {kind=.QUALITY_TOGGLE, index=i32(Quality_Toggle.SOFT_SHADOWS)})
	settings_toggle_row(state, "High-Res Shadows", "QualityHighResShadows", quality.high_res_shadows, {kind=.QUALITY_TOGGLE, index=i32(Quality_Toggle.HIGH_RES_SHADOWS)})
	settings_toggle_row(state, "Dynamic Shadows", "QualityDynamicShadows", quality.dynamic_shadows, {kind=.QUALITY_TOGGLE, index=i32(Quality_Toggle.DYNAMIC_SHADOWS)})
	settings_toggle_row(state, "Self shadow", "QualitySelfShadow", quality.self_shadow, {kind=.QUALITY_TOGGLE, index=i32(Quality_Toggle.SELF_SHADOW)})
	if settings_search_show(state, "Shadow quality") {
		if clay.UI(clay.ID("ShadowQualityRow"))(settings_row(state)) {
			settings_label("Shadow quality", state.scale)
			spacer()
			settings_dropdown_field(state, SHADOW_QUALITY_LABELS[Shadow_Quality(clamp(quality.shadow_quality, 0, 1))], "ShadowQuality", .SHADOW_QUALITY)
		}
	}
	settings_note(state, "Self shadow shows your own shadow. Shadow quality Krunker draws one shadow map over the whole map, like Krunker; Sharp uses cascades around you for crisper shadows nearby.")
	settings_note(state, "Shadows renders shadows from players and objects. Soft Shadows gives them a softer appearance, High-Res Shadows improves their quality, and Dynamic Shadows updates them in real time.")
	if settings_search_show(state, "Lighting") {
		if clay.UI(clay.ID("LightingRow"))(settings_row(state)) {
			settings_label("Lighting", state.scale)
			spacer()
			settings_dropdown_field(state, LIGHTING_LABELS[Lighting_Quality(clamp(quality.lighting, 0, 3))], "Lighting", .LIGHTING)
		}
	}
	settings_note(state, "Lighting sets the render quality of game lighting. Low is unlit, Normal is the default, High adds specular highlights and map lights, and Physical uses physically based shading.")
}

settings_slider_value :: proc(state: ^State, view: View, action: Action) -> f32 {
	if value, ok := host_slider_value(state, action); ok { return value }
	values := state.settings_draft
	if !state.settings_active {
		values.sensitivity, values.audio_volumes, values.visuals = view.sensitivity, view.audio_volumes, view.visuals
		values.fov = fov_validate(view.fov)
		values.viewmodel = viewmodel_settings_validate(view.viewmodel)
		values.crosshair = crosshair_settings_validate(view.crosshair)
		values.hitmarker = hitmarker_settings_validate(view.hitmarker)
		values.damage = damage_settings_validate(view.damage)
	}
	#partial switch action.kind {
	case .AUDIO_VOLUME: return values.audio_volumes[action.index]
	case .FOV: return values.fov
	case .VIEWMODEL_VALUE: return values.viewmodel.values[Viewmodel_Control(action.index)]
	case .CROSSHAIR_VALUE: return values.crosshair.values[Crosshair_Control(action.index)]
	case .HITMARKER_VALUE: return values.hitmarker.values[Hitmarker_Control(action.index)]
	case .DAMAGE_VALUE: return values.damage.values[Damage_Control(action.index)]
	case .VISUAL_VALUE: return values.visuals.values[Visual_Control(action.index)]
	case .NIGHT_STRENGTH: return values.visuals.night_strength
	case .KILL_FEED_LIMIT: return f32(kill_feed_limit(state.settings_active ? values.hud : view.hud))
	case .HUD_SCALE: return ui_scale(state.settings_active ? values.hud : view.hud)
	case .FPS_UPDATE_RATE: return f32(fps_update_ms(state.settings_active ? values.hud : view.hud))
	case .OBJECTIVE_OPACITY:
		hud := state.settings_active ? values.hud : view.hud
		return action.index == 0 ? objective_opacity(hud) : ads_objective_opacity(hud)
	case .SCOPE_VALUE:
		return scope_value(state.settings_active ? values.hud : view.hud, int(action.index))
	}
	return values.sensitivity
}
