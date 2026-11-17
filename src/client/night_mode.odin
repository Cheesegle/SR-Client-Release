package main

import menuui "../menu"
import shared "../shared"

// Night mode (a SR Client visual setting, not Krunker parity): a moonlit night
// computed from each map's own environment, so it works on every map. It only
// rewrites the per-frame copy of the lighting (g_lighting_config) and one
// Lighting Low tint; gameplay, collision and the network never see it. Off, or
// at strength 0, nothing is touched and frames match the day renderer exactly.

// Night sky and fog: a dark blue, plus a little of the map's own brightness so
// bright and dull maps still differ. Sky and fog take the same transform, so
// maps whose fog matches their sky keep a seamless horizon.
NIGHT_SKY :: shared.Vec3{0.03, 0.05, 0.11}
NIGHT_SKY_KEEP :: shared.Vec3{0.05, 0.06, 0.09}
// Ambient light: the map's ambient brightness, desaturated and cooled, at
// NIGHT_AMBIENT_SCALE of its intensity. Dark maps keep at least
// NIGHT_AMBIENT_FLOOR (the map's ambient luminance times intensity, before the
// cool tint) so their interiors never go black; maps already darker than that
// only change colour.
NIGHT_AMBIENT_TINT :: shared.Vec3{0.62, 0.74, 1.0}
NIGHT_AMBIENT_SCALE :: 0.5
NIGHT_AMBIENT_FLOOR :: 0.16
// The sun becomes a dim, cool moon. It keeps the sun's direction, so the
// shadow maps become moon shadows.
NIGHT_MOON_TINT :: shared.Vec3{0.7, 0.8, 1.0}
NIGHT_MOON_SCALE :: 0.32
// Lighting Low is unlit (MeshBasicMaterial): there is no light to dim, so lit
// materials take this tint instead.
NIGHT_LOW_TINT :: shared.Vec3{0.36, 0.42, 0.6}
// Emissive (unlit) materials, such as flat-shaded foliage, trails and glowing
// props, dim less than lit ones, so they still read as glowing.
NIGHT_UNLIT_TINT :: shared.Vec3{0.6, 0.66, 0.8}

// Shader tints (basic.frag uNightLowTint, uNightUnlitTint); white unless night
// is on, which leaves every pixel unchanged.
g_night_low_tint := shared.Vec3{1, 1, 1}
g_night_unlit_tint := shared.Vec3{1, 1, 1}

night_active :: proc(visuals: menuui.Visual_Settings) -> bool {
	return visuals.night_mode && visuals.night_strength > 0
}

@(private = "file")
night_luma :: proc(c: shared.Vec3) -> f32 { return c.x*0.2126 + c.y*0.7152 + c.z*0.0722 }

@(private = "file")
night_mix :: proc(a, b: shared.Vec3, t: f32) -> shared.Vec3 { return a + (b - a) * t }

night_sky_color :: proc(color: shared.Vec3, strength: f32) -> shared.Vec3 {
	return night_mix(color, NIGHT_SKY + NIGHT_SKY_KEEP * night_luma(color), strength)
}

// The map's lighting at night. strength 0 returns config unchanged.
night_lighting :: proc(config: shared.Lighting_Config, strength: f32) -> shared.Lighting_Config {
	s := clamp(strength, 0, 1)
	if s <= 0 { return config }
	result := config
	result.sky_color = night_sky_color(config.sky_color, s)
	result.fog_color = night_sky_color(config.fog_color, s)
	for &color in result.sky_dome_colors { color = night_sky_color(color, s) }
	ambient_luma := night_luma(config.ambient_color)
	result.ambient_color = night_mix(config.ambient_color, NIGHT_AMBIENT_TINT * ambient_luma, s)
	ambient := ambient_luma * config.ambient_intensity
	if ambient > 0 {
		night_ambient := max(ambient * (1 - s*(1 - NIGHT_AMBIENT_SCALE)), ambient + (min(ambient, NIGHT_AMBIENT_FLOOR) - ambient) * s)
		result.ambient_intensity = config.ambient_intensity * (night_ambient / ambient)
	}
	result.light_color = night_mix(config.light_color, NIGHT_MOON_TINT * night_luma(config.light_color), s)
	result.light_intensity = config.light_intensity * (1 - s*(1 - NIGHT_MOON_SCALE))
	return result
}

// The shader tints for these settings: (low, unlit).
night_tints :: proc(visuals: menuui.Visual_Settings) -> (low, unlit: shared.Vec3) {
	if !night_active(visuals) { return {1, 1, 1}, {1, 1, 1} }
	s := clamp(visuals.night_strength, 0, 1)
	return night_mix({1, 1, 1}, NIGHT_LOW_TINT, s), night_mix({1, 1, 1}, NIGHT_UNLIT_TINT, s)
}
