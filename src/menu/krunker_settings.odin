package menu

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem/virtual"
import "core:strconv"
import "core:strings"

// Krunker's Settings > Export/Import text (Krunker's client: settings
// `this["export"]`/`this['import']`, controls `this["export"]`
//). It is plain JSON: every settings-list key whose value
// differs from its default, plus "controls" (changed key binds, JS keyCodes)
// and "customize" (loadouts, images). Import resets list keys missing from the
// text to their defaults; binds missing from "controls" stay unchanged.

Krunker_Key :: enum {
	SHOW_TRAILS, YOUR_TRAILS, SHOW_KILLS, SHOW_FPS,
	CROSSHAIR_TYPE, CROSSHAIR_OPACITY, CROSSHAIR_USE_OPACITY, CROSSHAIR_ALWAYS, CROSSHAIR_COLOR, CROSSHAIR_SHADOW,
	CROSSHAIR_SHADOW_THICKNESS, CROSSHAIR_THICKNESS, CROSSHAIR_LENGTH, CROSSHAIR_GAP, CROSSHAIR_DOT,
	HITMARKER_SHOW, HITMARKER_COLOR, HITMARKER_KILL_COLOR, HITMARKER_OPACITY, HITMARKER_LENGTH, HITMARKER_THICKNESS, HITMARKER_SPACING, HITMARKER_ANIM_SIZE, HITMARKER_FADE,
	SENSITIVITY_X, SENSITIVITY_Y, AIM_SENSITIVITY_X, AIM_SENSITIVITY_Y, INVERT_Y,
	SOUND, PLAYER_VOLUME, UI_VOLUME,
	FOV, WEAPON_FOV, WEAPON_BOB, WEAPON_LEAN, WEAPON_ROT, WEAPON_OFF_X, WEAPON_OFF_Y, WEAPON_OFF_Z, WEAPON_ADS_OFF_Y, WEAPON_SWAP_Y, WEAPON_RELOAD_Y, ADS_FOV_MULT,
	TOGGLE_ADS, AIM_ANIM, HIDE_ADS, SHOW_HANDS, SHOW_WEAPON, SHOW_WEAPON_SEC, SHOW_WEAPON_MEL, LEFT_HAND,
	SATURATION, FEED_LIMIT, SCALE_UI, UI_SCALING,
	SHOW_HIT_INDICATORS, HIT_INDICATOR_COLOR, USE_DAMAGE_OVERLAY,
	SHADOWS, SOFT_SHADOWS, HIGH_RES_SHADOWS, DYNAMIC_SHADOWS, LIGHTING,
	IMPACT_HOLES, NAMETAG_STYLE, HIDE_NAMES, SHOW_PING, SHOW_UI, SHOW_KILL_COUNTER, SHOW_DEATH_COUNTER,
}
Krunker_Value_Kind :: enum { NUMBER, SWITCH, COLOR }
Krunker_Setting :: struct { key: string, kind: Krunker_Value_Kind, default, min, max: f64 }

// Names, desktop defaults and ranges from Krunker's settings list (Krunker's client
// `this["list"] = {`), in its declaration (export) order.
KRUNKER_SETTINGS := [Krunker_Key]Krunker_Setting{
	.SHOW_TRAILS = {"showTrails", .SWITCH, 1, 0, 0},
	.YOUR_TRAILS = {"yourTrails", .SWITCH, 1, 0, 0},
	.SHOW_KILLS = {"showKills", .SWITCH, 1, 0, 0},
	.SHOW_FPS = {"showFPS", .SWITCH, 0, 0, 0},
	.CROSSHAIR_TYPE = {"crosshairSho", .NUMBER, 1, 0, 5}, // 1 Dynamic ... 5 Precision.
	.CROSSHAIR_OPACITY = {"crosshairOpacity", .NUMBER, 1, 0, 1},
	.CROSSHAIR_USE_OPACITY = {"crosshairUseOpacity", .SWITCH, 0, 0, 0},
	.CROSSHAIR_ALWAYS = {"crosshairAlways", .SWITCH, 0, 0, 0},
	.CROSSHAIR_COLOR = {"crosshairColor", .COLOR, 0xffffff, 0, 0},
	.CROSSHAIR_SHADOW = {"crosshairShadow", .COLOR, 0x000000, 0, 0},
	.CROSSHAIR_SHADOW_THICKNESS = {"crosshairShadowThickess", .NUMBER, 1, 0, 3}, // Krunker's spelling.
	.CROSSHAIR_THICKNESS = {"crosshairThick", .NUMBER, 2, 0, 100},
	.CROSSHAIR_LENGTH = {"crosshairLen", .NUMBER, 16, 0, 100},
	.CROSSHAIR_GAP = {"crosshairGap", .NUMBER, 0, -100, 100},
	.CROSSHAIR_DOT = {"crosshairDot", .SWITCH, 1, 0, 0},
	// Hitmarker category (Krunker's client).
	.HITMARKER_SHOW = {"hitm", .SWITCH, 1, 0, 0},
	.HITMARKER_COLOR = {"hitmCol", .COLOR, 0xffffff, 0, 0},
	.HITMARKER_KILL_COLOR = {"hitmKCol", .COLOR, 0xff0000, 0, 0},
	.HITMARKER_OPACITY = {"hitOpac", .NUMBER, 1, 0, 1},
	.HITMARKER_LENGTH = {"hitmLen", .NUMBER, 25, 1, 50},
	.HITMARKER_THICKNESS = {"hitmThick", .NUMBER, 7, 1, 20},
	.HITMARKER_SPACING = {"hitmSpac", .NUMBER, 37, 5, 60},
	.HITMARKER_ANIM_SIZE = {"hitmAnimD", .NUMBER, 0.14, 0.1, 0.5},
	.HITMARKER_FADE = {"hitmFad", .NUMBER, 0.0062, 0.0001, 0.01},
	.SENSITIVITY_X = {"sensitivityX", .NUMBER, 1, 0.1, 15},
	.SENSITIVITY_Y = {"sensitivityY", .NUMBER, 1, 0.1, 15},
	.AIM_SENSITIVITY_X = {"aimSensitivityX", .NUMBER, 1, 0.1, 15},
	.AIM_SENSITIVITY_Y = {"aimSensitivityY", .NUMBER, 1, 0.1, 15},
	.INVERT_Y = {"invertY", .SWITCH, 0, 0, 0},
	.SOUND = {"sound", .NUMBER, 0.8, 0, 1},
	.PLAYER_VOLUME = {"playerVolume", .NUMBER, 1, 0, 1},
	.UI_VOLUME = {"uiVolume", .NUMBER, 1, 0, 1},
	.FOV = {"fov", .NUMBER, 100, 60, 150},
	.WEAPON_FOV = {"fpsFOV", .NUMBER, 95, 60, 150},
	.WEAPON_BOB = {"weaponBob", .NUMBER, 0.7, 0, 3},
	.WEAPON_LEAN = {"weaponLean", .NUMBER, 0.6, 0, 6},
	.WEAPON_ROT = {"weaponRot", .NUMBER, 0, -2, 2},
	.WEAPON_OFF_X = {"weaponOffX", .NUMBER, 1, 0, 4},
	.WEAPON_OFF_Y = {"weaponOffY", .NUMBER, 1.3, 0, 4},
	.WEAPON_OFF_Z = {"weaponOffZ", .NUMBER, 1, 0, 4},
	.WEAPON_ADS_OFF_Y = {"weaponADSOffY", .NUMBER, 1, 0, 2},
	.WEAPON_SWAP_Y = {"weapSwapY", .NUMBER, 1, -2, 2},
	.WEAPON_RELOAD_Y = {"weapReloadY", .NUMBER, 1, 0, 1},
	.ADS_FOV_MULT = {"adsFovMlt", .NUMBER, 1, 0, 1},
	.TOGGLE_ADS = {"toggleADS", .SWITCH, 0, 0, 0},
	.AIM_ANIM = {"aimAnim", .SWITCH, 1, 0, 0},
	.HIDE_ADS = {"hideADS", .SWITCH, 0, 0, 0},
	.SHOW_HANDS = {"showHands", .SWITCH, 1, 0, 0},
	.SHOW_WEAPON = {"showWeapon", .SWITCH, 1, 0, 0},
	.SHOW_WEAPON_SEC = {"showWeaponSec", .SWITCH, 1, 0, 0},
	.SHOW_WEAPON_MEL = {"showWeaponMel", .SWITCH, 1, 0, 0},
	.LEFT_HAND = {"leftHand", .SWITCH, 0, 0, 0},
	.SATURATION = {"saturationn", .NUMBER, 1, 0, 3}, // Krunker's spelling.
	.FEED_LIMIT = {"feedLimit", .NUMBER, KILL_FEED_DEFAULT_LIMIT, 1, KILL_FEED_MAX_LIMIT},
	.SCALE_UI = {"scaleUI", .NUMBER, UI_SCALE_DEFAULT, UI_SCALE_MIN, UI_SCALE_MAX},
	.UI_SCALING = {"uiScaling", .SWITCH, 1, 0, 0},
	// Damage feedback (Krunker's client).
	.SHOW_HIT_INDICATORS = {"showHitInd", .SWITCH, 1, 0, 0},
	.HIT_INDICATOR_COLOR = {"hitColor", .COLOR, 0xff3f3f, 0, 0},
	.USE_DAMAGE_OVERLAY = {"useDamageOverlay", .SWITCH, 1, 0, 0},
	// Video quality (Krunker's client settings list; see Quality_Settings).
	.SHADOWS = {"shadows", .SWITCH, 1, 0, 0},
	.SOFT_SHADOWS = {"softShad", .SWITCH, 0, 0, 0},
	.HIGH_RES_SHADOWS = {"highResShad", .SWITCH, 0, 0, 0},
	.DYNAMIC_SHADOWS = {"shadowsDynamic", .SWITCH, 0, 0, 0},
	.LIGHTING = {"lighting", .NUMBER, 1, 0, 3}, // 0 Low, 1 Normal, 2 High, 3 Physical.
	// Read from Krunker's own settings window (advanced view, November 2026).
	.IMPACT_HOLES = {"impactHoles", .SWITCH, 1, 0, 0},       // Show Bullet Impact Holes
	.NAMETAG_STYLE = {"nametagStyle", .NUMBER, 0, 0, 4},     // 0 Default, 1 Name Only, 2 Name & Level, 3 Health Only, 4 Simple
	.HIDE_NAMES = {"hideNames", .NUMBER, 0, 0, 3},           // Nametag Display: 0 Everyone, 1 Team, 2 Enemy, 3 Off
	.SHOW_PING = {"showPing", .SWITCH, 1, 0, 0},
	.SHOW_UI = {"showUI", .SWITCH, 1, 0, 0},
	.SHOW_KILL_COUNTER = {"showKillC", .SWITCH, 0, 0, 0},
	.SHOW_DEATH_COUNTER = {"showDeaths", .SWITCH, 0, 0, 0},
}
KRUNKER_SENSITIVITY_KEYS :: bit_set[Krunker_Key]{.SENSITIVITY_X, .SENSITIVITY_Y, .AIM_SENSITIVITY_X, .AIM_SENSITIVITY_Y}
KRUNKER_SOUND_KEYS :: bit_set[Krunker_Key]{.SOUND, .PLAYER_VOLUME, .UI_VOLUME}
// Effects SR Client never draws (it has no particles, muzzle flash, casings,
// screen shake, damage numbers, medals or death markers). When the imported
// value turns them off, SR already looks the same, so they count as applied.
Krunker_Absent_Effect :: struct { key: string, matches: string }
KRUNKER_ABSENT_EFFECTS := [?]Krunker_Absent_Effect{
	{"particles", "false"}, {"muzzleFlash", "false"}, {"bulletCasings", "false"}, {"textureAnim", "false"},
	{"objectAnim", "false"}, {"screenShake", "false"}, {"killFx", "false"}, {"showExplo", "false"},
	{"sniperFlap", "false"}, {"sniperFlapAnim", "false"}, {"bulletTracers", "false"}, {"showDMG", "false"},
	{"showMedals", "false"}, {"deathMarkers", "3"}, {"mouseAccel", "false"}, {"rawMouse", "true"}, {"autoLoadLast", "true"},
}
KRUNKER_CROSSHAIR_PRECISION :: 5
// Krunker's custom-image crosshair style; the image itself is "crosshairImage".
KRUNKER_CROSSHAIR_IMAGE :: 4
// SR Client also reads these Krunker keys, but only when the text contains
// them: an absent key keeps the current SR value instead of a guessed default.
KRUNKER_EXTRA_KEYS :: [?]string{"crosshairImage", "crosshairImageW", "crosshairImageH", "gunsVolume", "healthColT", "healthColE", "hudHealthHigh", "hudHealthLow", "fpsRate", "defaultRegion"}
KRUNKER_VIEWMODEL := [Viewmodel_Control]Krunker_Key{
	.WEAPON_FOV = .WEAPON_FOV, .BOBBING = .WEAPON_BOB, .LEANING = .WEAPON_LEAN, .ROTATION = .WEAPON_ROT,
	.OFFSET_X = .WEAPON_OFF_X, .OFFSET_Y = .WEAPON_OFF_Y, .OFFSET_Z = .WEAPON_OFF_Z, .ADS_OFFSET_Y = .WEAPON_ADS_OFF_Y,
	.SWAP_Y = .WEAPON_SWAP_Y, .RELOAD_Y = .WEAPON_RELOAD_Y, .ADS_FOV_POWER = .ADS_FOV_MULT,
}
KRUNKER_VIEWMODEL_TOGGLES := [Viewmodel_Toggle]Krunker_Key{
	.TOGGLE_ADS = .TOGGLE_ADS, .AIM_ANIMATION = .AIM_ANIM, .HIDE_ON_ADS = .HIDE_ADS, .SHOW_HANDS = .SHOW_HANDS,
	.SHOW_PRIMARY = .SHOW_WEAPON, .SHOW_SECONDARY = .SHOW_WEAPON_SEC, .SHOW_MELEE = .SHOW_WEAPON_MEL, .LEFT_HANDED = .LEFT_HAND,
}

// Krunker binds (Krunker's client `this['binds'] = {}`): name,
// default and alternate default. Movement is the "moveKeys" array (W, S, A, D).
Krunker_Bind :: struct { name: string, default, alt_default: i64 }
KRUNKER_BINDS := #partial [Binding_Action]Krunker_Bind{
	.JUMP = {"jumpKey", 32, -1}, .CROUCH = {"crouchKey", 16, -1},
	.AIM = {"aim1Key", 10003, 221}, .FIRE = {"shoot1Key", 10001, 220},
	.RELOAD = {"reloadKey", 82, -1}, .INSPECT = {"inspKey", 88, -1},
	.SECONDARY = {"swapKey", 69, -1}, .MELEE = {"meleeKey", 81, -1},
}
KRUNKER_MOVE_ACTIONS := [4]Binding_Action{.FORWARD, .BACKWARD, .LEFT, .RIGHT}
KRUNKER_MOVE_DEFAULTS := [4]i64{87, 83, 65, 68}

// imported: applied; ignored: Krunker settings SR Client doesn't have yet;
// not_applicable: settings for things SR never has on PC (controllers, voice
// chat, mobile, spectating) or colours of effects the file switches off.
Krunker_Import_Result :: struct { imported, ignored, not_applicable: int }
@(private="file")
krunker_not_applicable :: proc(name: string, object: json.Object) -> bool {
	if strings.has_suffix(name, "Cntrl") || strings.has_suffix(name, "Mbl") || strings.has_prefix(name, "vibration") { return true }
	switch name {
	case "micQuality", "micVolume", "voiceVolume", "voiceChatType", "voiceDistance", "muteSpec", "audioInput": return true
	case "dmgColor", "critColor", "dmgScale", "dmgType": return krunker_key_off(object, "showDMG")
	case "bulletTracerCol", "tracerOffset": return krunker_key_off(object, "bulletTracers")
	}
	return false
}
@(private="file")
krunker_key_off :: proc(object: json.Object, name: string) -> bool {
	value, found := object[name]
	if !found { return false }
	flag, ok := value.(json.Boolean)
	return ok && !bool(flag)
}
@(private="file")
krunker_bind_not_applicable :: proc(name: string) -> bool {
	switch name {
	case "voiceKey", "voiceKey_alt", "specFocusKey", "specFocusKey_alt", "sprayWheelKey", "sprayWheelKey_alt", "markPositionKey", "markPositionKey_alt", "toggleSets": return true
	}
	return false
}

// Krunker stores JS keyCodes. Mouse buttons are 10000+event.which and the
// wheel is 20000; -1 is unbound.
krunker_key_to_binding :: proc(js: i64) -> (code: i32, ok: bool) {
	switch {
	case js == -1: return 0, true
	case js == 20000: return BINDING_SCROLL, true // Krunker's wheel bind (wr(): 20000 -> "SCROLL").
	case js >= 10001 && js <= 10008:
		which := i32(js-10000)
		button := which == 2 ? 2 : which == 3 ? 1 : which-1 // which: 1 left, 2 middle, 3 right.
		return -button-1, true
	case js >= 'A' && js <= 'Z' || js >= '0' && js <= '9': code = i32(js)
	case js >= 96 && js <= 105: code = 320 + i32(js-96)
	case js >= 112 && js <= 135: code = 290 + i32(js-112)
	case:
		switch js {
		case 8: code = 259
		case 9: code = 258
		case 13: code = 257
		case 16: code = 340
		case 17: code = 341
		case 18: code = 342
		case 19: code = 284
		case 20: code = 280
		case 32: code = 32
		case 33: code = 266
		case 34: code = 267
		case 35: code = 269
		case 36: code = 268
		case 37: code = 263
		case 38: code = 265
		case 39: code = 262
		case 40: code = 264
		case 44: code = 283
		case 45: code = 260
		case 46: code = 261
		case 59, 186: code = 59
		case 61, 187: code = 61
		case 91: code = 343
		case 92: code = 347
		case 93: code = 348
		case 106: code = 332
		case 107: code = 334
		case 109: code = 333
		case 110: code = 330
		case 111: code = 331
		case 144: code = 282
		case 145: code = 281
		case 173, 189: code = 45
		case 188: code = 44
		case 190: code = 46
		case 191: code = 47
		case 219: code = 91
		case 220: code = 92
		case 221: code = 93
		case 222: code = 39
		}
	}
	// Escape and backtick are reserved by SR Client's menu and map rotation.
	return code, code != 0 && code != 256 && code != 96 && binding_valid(code)
}

binding_to_krunker_key :: proc(code: i32) -> (js: i64, ok: bool) {
	switch code {
	case 0: return -1, true
	case BINDING_SCROLL: return 20000, true
	case 344: return 16, true // Browsers report both shifts, controls and alts alike.
	case 345: return 17, true
	case 346: return 18, true
	}
	if code < 0 && code >= -8 {
		button := -code-1
		which := button == 1 ? 3 : button == 2 ? 2 : button+1
		return 10000 + i64(which), true
	}
	// Descending order prefers Chromium's punctuation codes (186, 187, 189).
	for candidate := i64(255); candidate >= 0; candidate -= 1 {
		if mapped, valid := krunker_key_to_binding(candidate); valid && mapped == code { return candidate, true }
	}
	return 0, false
}

@(private="file")
krunker_number :: proc(value: json.Value) -> (number: f64, ok: bool) {
	#partial switch v in value {
	case json.Float: number, ok = f64(v), true
	case json.Integer: number, ok = f64(v), true
	case json.Boolean: number, ok = v ? 1 : 0, true // JS Number(true) is 1.
	case json.String:
		trimmed := strings.trim_space(string(v))
		if len(trimmed) == 0 { return }
		number, ok = strconv.parse_f64(trimmed)
	}
	return number, ok && !math.is_nan(number) && !math.is_inf(number)
}

@(private="file")
krunker_switch :: proc(value: json.Value) -> (flag: bool, ok: bool) {
	// Krunker's set() turns "true"/"false" into booleans, then applies `!!value`.
	#partial switch v in value {
	case json.Boolean: return bool(v), true
	case json.Float: return v != 0 && !math.is_nan(f64(v)), true
	case json.Integer: return v != 0, true
	case json.String: return v != "false" && len(v) > 0, true
	}
	return false, false
}

@(private="file")
krunker_color :: proc(value: json.Value) -> (color: u32, ok: bool) {
	text, is_string := value.(json.String)
	if !is_string { return }
	hex := strings.trim_space(string(text))
	if len(hex) == 4 && hex[0] == '#' {
		long := [6]u8{hex[1], hex[1], hex[2], hex[2], hex[3], hex[3]}
		return crosshair_parse_color(string(long[:]))
	}
	if len(hex) == 0 || hex[0] != '#' { return }
	return crosshair_parse_color(hex)
}

@(private="file")
krunker_bind_value :: proc(value: json.Value) -> (code: i32, ok: bool) {
	number, valid := krunker_number(value)
	if !valid { return }
	return krunker_key_to_binding(i64(number)) // Krunker uses parseInt.
}

// Applies Krunker settings text to `values` only when the whole text parses as
// a JSON object; otherwise `values` is untouched and `error` explains why.
krunker_settings_import :: proc(values: ^Settings_Values, text: string, parts := IMPORT_ALL_PARTS) -> (result: Krunker_Import_Result, error: string) {
	trimmed := strings.trim_space(text)
	if len(trimmed) == 0 { return {}, "Paste your Krunker settings text first." }
	// An arena also frees partial values left behind by a failed parse.
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil { return {}, "Not enough memory to import settings." }
	defer virtual.arena_destroy(&arena)
	parser := json.make_parser_from_string(trimmed, .JSON, false, virtual.arena_allocator(&arena))
	root, err := json.parse_value(&parser)
	object, is_object := root.(json.Object)
	if err != nil || parser.curr_token.kind != .EOF || !is_object {
		return {}, "Invalid settings text. Copy it from Krunker's Settings > Export."
	}

	draft := values^
	numbers: [Krunker_Key]f64
	switches: [Krunker_Key]bool
	colors: [Krunker_Key]u32
	present: [Krunker_Key]bool
	skipped: bit_set[Krunker_Key]
	if .SENSITIVITY not_in parts { skipped += KRUNKER_SENSITIVITY_KEYS }
	if .SOUND not_in parts { skipped += KRUNKER_SOUND_KEYS }
	for setting, key in KRUNKER_SETTINGS {
		numbers[key], switches[key], colors[key] = setting.default, setting.default != 0, u32(setting.default)
		if key in skipped { continue }
		value, found := object[setting.key]
		if !found { continue }
		if _, is_null := value.(json.Null); is_null { continue } // `null != value` fails in Krunker.
		ok: bool
		switch setting.kind {
		case .NUMBER:
			number: f64
			number, ok = krunker_number(value)
			if ok { numbers[key] = clamp(number, setting.min, setting.max) }
		case .SWITCH: switches[key], ok = krunker_switch(value)
		case .COLOR:
			color: u32
			color, ok = krunker_color(value)
			if ok { colors[key] = color }
		}
		present[key] = ok
		if !ok { result.ignored += 1 }
	}
	// SR Client has one sensitivity for both axes, and ADS that scales with zoom
	// exactly like Krunker only when ADS equals hipfire.
	sensitivity := numbers[.SENSITIVITY_X]
	if .SENSITIVITY in parts do for key in ([3]Krunker_Key{.SENSITIVITY_Y, .AIM_SENSITIVITY_X, .AIM_SENSITIVITY_Y}) {
		if present[key] && abs(numbers[key]-sensitivity) > 0.0005 { present[key] = false; result.ignored += 1 }
	}
	// Image crosshair (crosshairSho 4 + crosshairImage) or Precision (5).
	current_crosshair := crosshair_settings_validate(values.crosshair)
	image_url := current_crosshair.image_url
	if value, found := object["crosshairImage"]; found {
		if text, is_text := value.(json.String); is_text && len(text) <= CROSSHAIR_IMAGE_URL_MAX { image_url = strings.clone(strings.trim_space(string(text))); result.imported += 1 } else { result.ignored += 1 }
	}
	image_size := [2]f32{current_crosshair.values[.IMAGE_WIDTH], current_crosshair.values[.IMAGE_HEIGHT]}
	for name, i in ([2]string{"crosshairImageW", "crosshairImageH"}) {
		value, found := object[name]
		if !found { continue }
		if number, ok := krunker_number(value); ok && number > 0 { image_size[i] = f32(clamp(number, 1, 512)); result.imported += 1 } else { result.ignored += 1 }
	}
	crosshair_kind := Crosshair_Type.PRECISION
	if present[.CROSSHAIR_TYPE] && numbers[.CROSSHAIR_TYPE] == KRUNKER_CROSSHAIR_IMAGE && len(image_url) > 0 { crosshair_kind = .IMAGE }
	else if present[.CROSSHAIR_TYPE] && numbers[.CROSSHAIR_TYPE] != KRUNKER_CROSSHAIR_PRECISION { present[.CROSSHAIR_TYPE] = false; result.ignored += 1 }
	for key in Krunker_Key { if present[key] { result.imported += 1 } }

	if .SENSITIVITY in parts {
		draft.sensitivity = sensitivity_validate(f32(sensitivity), draft.mouse_dpi)
		draft.advanced_sensitivity = false
	}
	draft.invert_mouse = switches[.INVERT_Y]
	draft.fov = fov_validate(f32(numbers[.FOV]))
	draft.show_fps = switches[.SHOW_FPS]
	draft.trails = {hide_others = !switches[.SHOW_TRAILS], hide_yours = !switches[.YOUR_TRAILS]}
	draft.hud.hide_kill_feed = !switches[.SHOW_KILLS]
	draft.hud.kill_feed_limit = i32(clamp(math.round(numbers[.FEED_LIMIT]), 1, KILL_FEED_MAX_LIMIT))
	draft.hud.ui_scale = f32(clamp(numbers[.SCALE_UI], UI_SCALE_MIN, UI_SCALE_MAX))
	draft.hud.ui_scaling_off = !switches[.UI_SCALING]
	if .SOUND in parts {
		draft.audio_volumes[0] = f32(numbers[.SOUND])
		draft.audio_volumes[2] = f32(numbers[.PLAYER_VOLUME])
		draft.audio_volumes[3] = f32(numbers[.UI_VOLUME])
	}
	draft.hud.hide_bullet_holes = !switches[.IMPACT_HOLES]
	draft.hud.hide_ping = !switches[.SHOW_PING]
	draft.hud.hide_hud = !switches[.SHOW_UI]
	draft.hud.hide_kill_counter, draft.hud.hide_death_counter = !switches[.SHOW_KILL_COUNTER], !switches[.SHOW_DEATH_COUNTER]
	// Nametag Style: Name Only / Name & Level hide the bars, Health Only hides
	// the names; Nametag Display "Off" hides both. Team-only and enemy-only
	// display have no SR equivalent and show everyone.
	style := i32(math.round(numbers[.NAMETAG_STYLE]))
	draft.hud.hide_healthbars = style == 1 || style == 2
	draft.hud.hide_nametags = style == 3
	if i32(math.round(numbers[.HIDE_NAMES])) == 3 { draft.hud.hide_nametags, draft.hud.hide_healthbars = true, true }
	// Colours and the FPS counter rate apply only when the text has them, so
	// SR Client's own look stays otherwise.
	for name, i in ([4]string{"healthColT", "healthColE", "hudHealthHigh", "hudHealthLow"}) {
		value, found := object[name]
		if !found { continue }
		color, ok := krunker_color(value)
		if !ok { result.ignored += 1; continue }
		if color == 0 { color = 0x000001 } // 0 means SR's own colour.
		switch i {
		case 0: draft.hud.health_color_team = color
		case 1: draft.hud.health_color_enemy = color
		case 2: draft.hud.hud_health_high = color
		case 3: draft.hud.hud_health_low = color
		}
		result.imported += 1
	}
	if value, found := object["defaultRegion"]; found {
		region, is_text := value.(json.String)
		matched := false
		if is_text { for candidate, i in KRUNKER_REGIONS { if candidate.id == string(region) { draft.hud.default_region, matched = i32(i) + 1, true } } }
		if matched { result.imported += 1 } else { result.ignored += 1 }
	}
	if value, found := object["fpsRate"]; found {
		if number, ok := krunker_number(value); ok { draft.hud.fps_update_ms = i32(clamp(math.round(number), FPS_UPDATE_MIN_MS, FPS_UPDATE_MAX_MS)); result.imported += 1 } else { result.ignored += 1 }
	}
	draft.visuals.values[.SATURATION] = f32(numbers[.SATURATION])
	draft.visuals = visual_settings_validate(draft.visuals)
	for key, control in KRUNKER_VIEWMODEL { draft.viewmodel.values[control] = f32(numbers[key]) }
	for key, toggle in KRUNKER_VIEWMODEL_TOGGLES { draft.viewmodel.toggles[toggle] = switches[key] }
	draft.viewmodel = viewmodel_settings_validate(draft.viewmodel)
	draft.crosshair = Crosshair_Settings{
		kind = crosshair_kind,
		values = {.OPACITY = f32(numbers[.CROSSHAIR_OPACITY]), .SHADOW = f32(numbers[.CROSSHAIR_SHADOW_THICKNESS]), .THICKNESS = f32(numbers[.CROSSHAIR_THICKNESS]), .SIZE = f32(numbers[.CROSSHAIR_LENGTH]), .GAP = f32(numbers[.CROSSHAIR_GAP]), .IMAGE_WIDTH = image_size[0], .IMAGE_HEIGHT = image_size[1]},
		toggles = {.CUSTOM_OPACITY = switches[.CROSSHAIR_USE_OPACITY], .ALWAYS_SHOW = switches[.CROSSHAIR_ALWAYS], .DOT = switches[.CROSSHAIR_DOT]},
		color = colors[.CROSSHAIR_COLOR], shadow_color = colors[.CROSSHAIR_SHADOW],
		image_url = image_url,
	}
	draft.quality.shadows, draft.quality.soft_shadows = switches[.SHADOWS], switches[.SOFT_SHADOWS]
	draft.quality.high_res_shadows, draft.quality.dynamic_shadows = switches[.HIGH_RES_SHADOWS], switches[.DYNAMIC_SHADOWS]
	draft.quality.lighting = i32(clamp(math.round(numbers[.LIGHTING]), 0, 3))
	draft.quality = quality_settings_validate(draft.quality)
	// Gun volume has no documented default here, so it applies only when present.
	if value, found := object["gunsVolume"]; found && .SOUND in parts {
		if number, ok := krunker_number(value); ok { draft.audio_volumes[1] = f32(clamp(number, 0, 1)); result.imported += 1 } else { result.ignored += 1 }
	}
	draft.crosshair = crosshair_settings_validate(draft.crosshair)
	// Headshot color is SR Client's own, so an import keeps it.
	draft.hitmarker = hitmarker_settings_validate(Hitmarker_Settings{
		show = switches[.HITMARKER_SHOW],
		values = {.OPACITY = f32(numbers[.HITMARKER_OPACITY]), .LENGTH = f32(numbers[.HITMARKER_LENGTH]), .THICKNESS = f32(numbers[.HITMARKER_THICKNESS]), .SPACING = f32(numbers[.HITMARKER_SPACING]), .ANIM_SIZE = f32(numbers[.HITMARKER_ANIM_SIZE]), .FADE = f32(numbers[.HITMARKER_FADE])},
		colors = {.NORMAL = colors[.HITMARKER_COLOR], .KILL = colors[.HITMARKER_KILL_COLOR], .HEADSHOT = hitmarker_settings_validate(values.hitmarker).colors[.HEADSHOT]},
	})
	// SR Client's own damage values are kept; Krunker's three keys are applied.
	draft.damage = damage_settings_validate(draft.damage)
	draft.damage.toggles[.OVERLAY], draft.damage.toggles[.INDICATORS] = switches[.USE_DAMAGE_OVERLAY], switches[.SHOW_HIT_INDICATORS]
	draft.damage.colors[.INDICATOR] = colors[.HIT_INDICATOR_COLOR]

	known := make(map[string]bool, allocator = context.temp_allocator)
	for setting in KRUNKER_SETTINGS { known[setting.key] = true }
	for name in KRUNKER_EXTRA_KEYS { known[name] = true }
	// Left-out parts are neither imported nor counted as unsupported.
	if .SOUND not_in parts { for name in ([?]string{"sound", "playerVolume", "uiVolume", "gunsVolume", "ambientVolume", "dialogueVolume", "skinVolume", "assetVolume", "voiceVolume", "micVolume", "micQuality"}) { known[name] = true } }
	if .SENSITIVITY not_in parts { for name in ([?]string{"sensitivityXCntrl", "sensitivityYCntrl", "aimSensitivityXCntrl", "aimSensitivityYCntrl"}) { known[name] = true } }
	absent: for name, value in object {
		if name == "controls" {
			if .KEYBINDS not_in parts { continue }
			controls, ok := value.(json.Object)
			if !ok { result.ignored += 1; continue }
			krunker_import_controls(&draft.bindings, controls, &result)
		} else if !known[name] {
			for effect in KRUNKER_ABSENT_EFFECTS {
				if effect.key != name { continue }
				text: string
				#partial switch v in value {
				case json.Boolean: text = v ? "true" : "false"
				case json.String: text = string(v)
				case json.Integer: text = fmt.tprintf("%d", v)
				}
				if text == effect.matches { result.imported += 1; continue absent }
			}
			if krunker_not_applicable(name, object) { result.not_applicable += 1; continue absent }
			result.ignored += 1 // Unsupported, per-weapon ("_N") and "customize" entries.
		}
	}
	for action in Binding_Action {
		if draft.bindings[action][0] == draft.bindings[action][1] { draft.bindings[action][1] = 0 }
	}
	values^ = draft
	return result, ""
}

@(private="file")
krunker_import_controls :: proc(bindings: ^Bindings, controls: json.Object, result: ^Krunker_Import_Result) {
	outer: for name, value in controls {
		if name == "moveKeys" || name == "moveKeys_alt" {
			slot := name == "moveKeys" ? 0 : 1
			keys, ok := value.(json.Array)
			if !ok { result.ignored += 1; continue }
			for entry, i in keys {
				if _, is_null := entry.(json.Null); is_null { continue } // Sparse: keep the current bind.
				code, valid := krunker_bind_value(entry)
				if i >= len(KRUNKER_MOVE_ACTIONS) || !valid { result.ignored += 1; continue }
				bindings[KRUNKER_MOVE_ACTIONS[i]][slot] = code
				result.imported += 1
			}
			continue
		}
		for bind, action in KRUNKER_BINDS {
			if len(bind.name) == 0 { continue }
			slot := -1
			if name == bind.name { slot = 0 }
			if len(name) == len(bind.name)+4 && strings.has_prefix(name, bind.name) && strings.has_suffix(name, "_alt") { slot = 1 }
			if slot < 0 { continue }
			if code, valid := krunker_bind_value(value); valid {
				bindings[action][slot] = code
				result.imported += 1
			} else { result.ignored += 1 }
			continue outer
		}
		if krunker_bind_not_applicable(name) { result.not_applicable += 1; continue }
		result.ignored += 1 // Spray, chat, toggles and other unsupported binds.
	}
}

@(private="file")
krunker_write_number :: proc(builder: ^strings.Builder, value: f64) {
	text := fmt.tprintf("%.6f", value)
	text = strings.trim_right(text, "0")
	text = strings.trim_suffix(text, ".")
	if text == "-0" { text = "0" }
	strings.write_string(builder, text)
}

// Builds the same JSON Krunker's Export produces: only values that differ
// from Krunker's defaults, then changed binds under "controls".
krunker_settings_export :: proc(values: Settings_Values, allocator := context.allocator) -> string {
	numbers: [Krunker_Key]f64
	switches: [Krunker_Key]bool
	colors: [Krunker_Key]u32
	sensitivity := clamp(f64(sensitivity_validate(values.sensitivity, values.mouse_dpi)), 0.1, 15)
	for key in ([4]Krunker_Key{.SENSITIVITY_X, .SENSITIVITY_Y, .AIM_SENSITIVITY_X, .AIM_SENSITIVITY_Y}) { numbers[key] = sensitivity }
	numbers[.CROSSHAIR_TYPE] = values.crosshair.kind == .IMAGE && len(values.crosshair.image_url) > 0 ? KRUNKER_CROSSHAIR_IMAGE : KRUNKER_CROSSHAIR_PRECISION
	numbers[.SOUND], numbers[.PLAYER_VOLUME], numbers[.UI_VOLUME] = f64(values.audio_volumes[0]), f64(values.audio_volumes[2]), f64(values.audio_volumes[3])
	numbers[.FOV] = f64(fov_validate(values.fov))
	numbers[.SATURATION] = f64(visual_settings_validate(values.visuals).values[.SATURATION])
	viewmodel := viewmodel_settings_validate(values.viewmodel)
	for key, control in KRUNKER_VIEWMODEL { numbers[key] = f64(viewmodel.values[control]) }
	for key, toggle in KRUNKER_VIEWMODEL_TOGGLES { switches[key] = viewmodel.toggles[toggle] }
	crosshair := crosshair_settings_validate(values.crosshair)
	numbers[.CROSSHAIR_OPACITY], numbers[.CROSSHAIR_SHADOW_THICKNESS] = f64(crosshair.values[.OPACITY]), f64(crosshair.values[.SHADOW])
	numbers[.CROSSHAIR_THICKNESS], numbers[.CROSSHAIR_LENGTH], numbers[.CROSSHAIR_GAP] = f64(crosshair.values[.THICKNESS]), f64(crosshair.values[.SIZE]), f64(crosshair.values[.GAP])
	switches[.CROSSHAIR_USE_OPACITY], switches[.CROSSHAIR_ALWAYS], switches[.CROSSHAIR_DOT] = crosshair.toggles[.CUSTOM_OPACITY], crosshair.toggles[.ALWAYS_SHOW], crosshair.toggles[.DOT]
	colors[.CROSSHAIR_COLOR], colors[.CROSSHAIR_SHADOW] = crosshair.color, crosshair.shadow_color
	hitmarker := hitmarker_settings_validate(values.hitmarker)
	switches[.HITMARKER_SHOW] = hitmarker.show
	colors[.HITMARKER_COLOR], colors[.HITMARKER_KILL_COLOR] = hitmarker.colors[.NORMAL], hitmarker.colors[.KILL]
	numbers[.HITMARKER_OPACITY], numbers[.HITMARKER_LENGTH], numbers[.HITMARKER_THICKNESS] = f64(hitmarker.values[.OPACITY]), f64(hitmarker.values[.LENGTH]), f64(hitmarker.values[.THICKNESS])
	numbers[.HITMARKER_SPACING], numbers[.HITMARKER_ANIM_SIZE], numbers[.HITMARKER_FADE] = f64(hitmarker.values[.SPACING]), f64(hitmarker.values[.ANIM_SIZE]), f64(hitmarker.values[.FADE])
	damage := damage_settings_validate(values.damage)
	switches[.USE_DAMAGE_OVERLAY], switches[.SHOW_HIT_INDICATORS] = damage.toggles[.OVERLAY], damage.toggles[.INDICATORS]
	colors[.HIT_INDICATOR_COLOR] = damage.colors[.INDICATOR]
	switches[.SHOW_TRAILS], switches[.YOUR_TRAILS] = !values.trails.hide_others, !values.trails.hide_yours
	switches[.SHOW_FPS], switches[.INVERT_Y] = values.show_fps, values.invert_mouse
	switches[.SHOW_KILLS], numbers[.FEED_LIMIT] = !values.hud.hide_kill_feed, f64(kill_feed_limit(values.hud))
	numbers[.SCALE_UI], switches[.UI_SCALING] = f64(ui_scale(values.hud)), !values.hud.ui_scaling_off
	quality := quality_settings_validate(values.quality)
	switches[.SHADOWS], switches[.SOFT_SHADOWS], switches[.HIGH_RES_SHADOWS], switches[.DYNAMIC_SHADOWS] = quality.shadows, quality.soft_shadows, quality.high_res_shadows, quality.dynamic_shadows
	numbers[.LIGHTING] = f64(clamp(quality.lighting, 0, 3))
	switches[.IMPACT_HOLES], switches[.SHOW_PING], switches[.SHOW_UI] = !values.hud.hide_bullet_holes, !values.hud.hide_ping, !values.hud.hide_hud
	switches[.SHOW_KILL_COUNTER], switches[.SHOW_DEATH_COUNTER] = !values.hud.hide_kill_counter, !values.hud.hide_death_counter
	switch {
	case values.hud.hide_nametags && values.hud.hide_healthbars: numbers[.HIDE_NAMES] = 3
	case values.hud.hide_nametags: numbers[.NAMETAG_STYLE] = 3
	case values.hud.hide_healthbars: numbers[.NAMETAG_STYLE] = 1
	}

	builder := strings.builder_make(allocator)
	strings.write_byte(&builder, '{')
	first := true
	for setting, key in KRUNKER_SETTINGS {
		changed: bool
		switch setting.kind {
		case .NUMBER: changed = abs(numbers[key]-setting.default) > 0.000001
		case .SWITCH: changed = switches[key] != (setting.default != 0)
		case .COLOR: changed = colors[key] != u32(setting.default)
		}
		if !changed { continue }
		if !first { strings.write_byte(&builder, ',') }
		first = false
		fmt.sbprintf(&builder, "\"%s\":", setting.key)
		switch setting.kind {
		case .NUMBER: krunker_write_number(&builder, numbers[key])
		case .SWITCH: strings.write_string(&builder, switches[key] ? "true" : "false")
		case .COLOR: fmt.sbprintf(&builder, "\"#%06x\"", colors[key])
		}
	}

	if values.crosshair.kind == .IMAGE && len(values.crosshair.image_url) > 0 {
		if !first { strings.write_byte(&builder, ',') }
		first = false
		escaped, _ := json.marshal(values.crosshair.image_url, allocator = context.temp_allocator)
		fmt.sbprintf(&builder, "\"crosshairImage\":%s,\"crosshairImageW\":", string(escaped))
		krunker_write_number(&builder, f64(values.crosshair.values[.IMAGE_WIDTH]))
		strings.write_string(&builder, ",\"crosshairImageH\":")
		krunker_write_number(&builder, f64(values.crosshair.values[.IMAGE_HEIGHT]))
	}

	extra_colors := [4]u32{values.hud.health_color_team, values.hud.health_color_enemy, values.hud.hud_health_high, values.hud.hud_health_low}
	for name, i in ([4]string{"healthColT", "healthColE", "hudHealthHigh", "hudHealthLow"}) {
		if extra_colors[i] == 0 { continue }
		if !first { strings.write_byte(&builder, ',') }
		first = false
		fmt.sbprintf(&builder, "\"%s\":\"#%06x\"", name, extra_colors[i] & 0xffffff)
	}
	if values.hud.fps_update_ms > 0 {
		if !first { strings.write_byte(&builder, ',') }
		first = false
		fmt.sbprintf(&builder, "\"fpsRate\":%d", fps_update_ms(values.hud))
	}
	if values.hud.default_region > 0 {
		if !first { strings.write_byte(&builder, ',') }
		first = false
		fmt.sbprintf(&builder, "\"defaultRegion\":\"%s\"", default_region(values.hud).id)
	}

	controls := strings.builder_make(context.temp_allocator)
	controls_first := true
	write_control :: proc(builder: ^strings.Builder, first: ^bool, name: string, value: string) {
		if !first^ { strings.write_byte(builder, ',') }
		first^ = false
		fmt.sbprintf(builder, "\"%s\":%s", name, value)
	}
	for slot in 0..<2 {
		keys: [4]Maybe(i64)
		last := -1
		for action, i in KRUNKER_MOVE_ACTIONS {
			js, ok := binding_to_krunker_key(values.bindings[action][slot])
			default := slot == 0 ? KRUNKER_MOVE_DEFAULTS[i] : -1
			if ok && js != default { keys[i], last = js, i }
		}
		if last < 0 { continue }
		array := strings.builder_make(context.temp_allocator)
		strings.write_byte(&array, '[')
		for i in 0..=last {
			if i > 0 { strings.write_byte(&array, ',') }
			if js, ok := keys[i].?; ok { fmt.sbprintf(&array, "%d", js) } else { strings.write_string(&array, "null") }
		}
		strings.write_byte(&array, ']')
		write_control(&controls, &controls_first, slot == 0 ? "moveKeys" : "moveKeys_alt", strings.to_string(array))
	}
	for bind, action in KRUNKER_BINDS {
		if len(bind.name) == 0 { continue }
		for slot in 0..<2 {
			js, ok := binding_to_krunker_key(values.bindings[action][slot])
			default := slot == 0 ? bind.default : bind.alt_default
			if !ok || js == default { continue }
			write_control(&controls, &controls_first, slot == 0 ? bind.name : fmt.tprintf("%s_alt", bind.name), fmt.tprintf("%d", js))
		}
	}
	if !controls_first {
		if !first { strings.write_byte(&builder, ',') }
		strings.write_string(&builder, `"controls":{`)
		strings.write_string(&builder, strings.to_string(controls))
		strings.write_byte(&builder, '}')
	}
	strings.write_byte(&builder, '}')
	return strings.to_string(builder)
}
