package menu

import "core:math"
import clay "../third_party/clay"

// Feedback when the local player takes damage, from Krunker's settings list
// (Krunker's client): useDamageOverlay "Use Damage Overlay"
// (Customization,; blood.png drawn at 1 - health/0.8),
// showHitInd "Show Hit Indicators" and hitColor "Hit Indicator Color"
// (Interface,; a marker toward the attacker for 2 s).
// Overlay color and intensity, the flash and the indicator duration are
// SR Client's own; their defaults keep Krunker's look.
Damage_Control :: enum { OVERLAY_INTENSITY, FLASH_DURATION, INDICATOR_DURATION }
Damage_Toggle :: enum { OVERLAY, INDICATORS }
Damage_Color :: enum { OVERLAY, INDICATOR }
Damage_Settings :: struct {
	toggles: [Damage_Toggle]bool,
	values: [Damage_Control]f32,
	colors: [Damage_Color]u32,
}
DEFAULT_DAMAGE_SETTINGS :: Damage_Settings{
	toggles = {.OVERLAY=true, .INDICATORS=true},
	values = {.OVERLAY_INTENSITY=1, .FLASH_DURATION=0.3, .INDICATOR_DURATION=2},
	// 0xC04646 is the center tint of Krunker's blood.png; its edges are darker.
	colors = {.OVERLAY=0xc04646, .INDICATOR=0xff3f3f},
}
DAMAGE_LIMITS := [Damage_Control][2]f32{.OVERLAY_INTENSITY={0,1}, .FLASH_DURATION={0,2}, .INDICATOR_DURATION={0.25,5}}
DAMAGE_STEPS := [Damage_Control]f32{.OVERLAY_INTENSITY=0.05, .FLASH_DURATION=0.05, .INDICATOR_DURATION=0.25}
DAMAGE_LABELS := [Damage_Control]string{.OVERLAY_INTENSITY="Damage overlay intensity", .FLASH_DURATION="Damage flash duration", .INDICATOR_DURATION="Hit indicator duration"}
DAMAGE_IDS := [Damage_Control]string{.OVERLAY_INTENSITY="DamageIntensity", .FLASH_DURATION="DamageFlash", .INDICATOR_DURATION="HitIndicatorDuration"}
DAMAGE_TOGGLE_LABELS := [Damage_Toggle]string{.OVERLAY="Use Damage Overlay", .INDICATORS="Show Hit Indicators"}
DAMAGE_TOGGLE_IDS := [Damage_Toggle]string{.OVERLAY="DamageOverlay", .INDICATORS="HitIndicators"}
DAMAGE_COLOR_LABELS := [Damage_Color]string{.OVERLAY="Damage overlay color", .INDICATOR="Hit Indicator Color"}
// Color edit fields; 1 and 2 are the crosshair's and 3-5 are reserved.
DAMAGE_COLOR_FIELDS := [Damage_Color]i32{.OVERLAY=6, .INDICATOR=7}

damage_settings_validate :: proc(settings: Damage_Settings) -> Damage_Settings {
	// A zero value predates these settings: indicators always last 0.25 s+.
	if settings == (Damage_Settings{}) { return DEFAULT_DAMAGE_SETTINGS }
	result := settings
	defaults := DEFAULT_DAMAGE_SETTINGS
	for control in Damage_Control {
		value := result.values[control]
		if math.is_nan(value) || math.is_inf(value) { value = defaults.values[control] }
		result.values[control] = clamp(value, DAMAGE_LIMITS[control][0], DAMAGE_LIMITS[control][1])
	}
	for &color in result.colors { color &= 0xffffff }
	return result
}

settings_damage :: proc(state: ^State) {
	values := state.settings_draft.damage
	settings_section(state, "Damage")
	settings_toggle_row(state, DAMAGE_TOGGLE_LABELS[.OVERLAY], DAMAGE_TOGGLE_IDS[.OVERLAY], values.toggles[.OVERLAY], {kind=.DAMAGE_TOGGLE, index=i32(Damage_Toggle.OVERLAY)})
	settings_crosshair_color(state, DAMAGE_COLOR_LABELS[.OVERLAY], DAMAGE_COLOR_FIELDS[.OVERLAY])
	for control in ([2]Damage_Control{.OVERLAY_INTENSITY, .FLASH_DURATION}) {
		settings_slider(state, DAMAGE_LABELS[control], DAMAGE_IDS[control], values.values[control], DAMAGE_LIMITS[control][0], DAMAGE_LIMITS[control][1], {kind=.DAMAGE_VALUE, index=i32(control)}, step=DAMAGE_STEPS[control])
	}
	settings_toggle_row(state, DAMAGE_TOGGLE_LABELS[.INDICATORS], DAMAGE_TOGGLE_IDS[.INDICATORS], values.toggles[.INDICATORS], {kind=.DAMAGE_TOGGLE, index=i32(Damage_Toggle.INDICATORS)})
	settings_crosshair_color(state, DAMAGE_COLOR_LABELS[.INDICATOR], DAMAGE_COLOR_FIELDS[.INDICATOR])
	control := Damage_Control.INDICATOR_DURATION
	settings_slider(state, DAMAGE_LABELS[control], DAMAGE_IDS[control], values.values[control], DAMAGE_LIMITS[control][0], DAMAGE_LIMITS[control][1], {kind=.DAMAGE_VALUE, index=i32(control)}, step=DAMAGE_STEPS[control])
	settings_note(state, "As in Krunker, the red border grows once health drops below 80% and hit indicators point toward the attacker. Overlay color, intensity, the flash on each hit (0 s turns it off) and indicator duration are SR Client's own.")
}

Damage_Preview :: struct { settings: Damage_Settings, scale: f32 }
settings_damage_preview :: proc(state: ^State) {
	s := state.scale
	state.damage_preview = {state.settings_draft.damage, s}
	if clay.UI()({layout={sizing={width=clay.SizingGrow()}, layoutDirection=.TopToBottom, padding={left=u16(24*s), right=u16(24*s)}, childGap=u16(8*s)}}) {
		text("Damage preview", 16, s, SETTINGS_MUTED)
		// As the crosshair preview: the background stays on the parent.
		if clay.UI()({layout={sizing={width=clay.SizingGrow(), height=clay.SizingFixed(124*s)}}, backgroundColor={65,75,82,255}, cornerRadius=clay.CornerRadiusAll(4*s)}) {
			if clay.UI(clay.ID("DamagePreview"))({layout={sizing={width=clay.SizingGrow(), height=clay.SizingGrow()}}, custom={customData=&state.damage_preview}}) {}
		}
	}
}
