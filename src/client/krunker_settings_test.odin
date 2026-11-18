package main

import "core:math"
import "core:strings"
import "core:testing"
import menuui "../menu"

when ODIN_TEST {
	// A Krunker export: non-default list values with real key names, "controls"
	// with JS keyCodes (sparse moveKeys -> null), and "customize".
	KRUNKER_SAMPLE_EXPORT :: `{"showTrails":false,"showFPS":true,"crosshairSho":5,"crosshairOpacity":0.6,"crosshairUseOpacity":true,"crosshairAlways":true,"crosshairColor":"#00ff00","crosshairShadow":"#202020","crosshairShadowThickess":1.5,"crosshairThick":3,"crosshairLen":10.5,"crosshairGap":4,"crosshairDot":false,"sensitivityX":1.6,"sensitivityY":1.6,"aimSensitivityX":1.6,"aimSensitivityY":1.6,"invertY":true,"sound":0.5,"playerVolume":0.7,"uiVolume":0.3,"fov":110,"fpsFOV":110,"weaponBob":0.2,"weaponLean":0,"weaponOffX":1.5,"adsFovMlt":0.5,"toggleADS":true,"showHands":false,"leftHand":true,"saturationn":1.4,"resolution":1,"scaleUI":0.8,"hitColor":"#ff0000","customize":{"favorites":[]},"controls":{"moveKeys":[90,null,81],"moveKeys_alt":[38,40,37,39],"crouchKey":67,"shoot1Key_alt":-1,"aim1Key":10002,"reloadKey":70,"inspKey":71,"swapKey":10004,"meleeKey":20000,"sprayKey":84,"toggleSets":["","","","","",""]}}`

	krunker_test_values :: proc() -> menuui.Settings_Values {
		return {fov = menuui.DEFAULT_FOV, sensitivity = 1, ads_sensitivity = 0.5, advanced_sensitivity = true, mouse_dpi = 1600, audio_volumes = {0.8, 1, 0.8, 0.6},
			bindings = menuui.default_bindings(), visuals = menuui.DEFAULT_VISUAL_SETTINGS, viewmodel = menuui.DEFAULT_VIEWMODEL_SETTINGS, crosshair = menuui.DEFAULT_CROSSHAIR_SETTINGS}
	}

	@(test)
	krunker_import_full_sample :: proc(t: ^testing.T) {
		values := krunker_test_values()
		result, error := menuui.krunker_settings_import(&values, KRUNKER_SAMPLE_EXPORT)
		testing.expect_value(t, error, "")
		testing.expect_value(t, result, menuui.Krunker_Import_Result{imported = 46, ignored = 3, not_applicable = 1})
		testing.expect(t, values.damage.colors[.INDICATOR] == 0xff0000 && values.damage.toggles[.INDICATORS] && values.damage.toggles[.OVERLAY], "hitColor imports; absent damage switches use Krunker defaults")
		testing.expect(t, abs(values.sensitivity-1.6) < 0.0001 && !values.advanced_sensitivity && values.invert_mouse && values.mouse_dpi == 1600, "sensitivity, inversion and DPI")
		testing.expect(t, values.fov == 110 && values.show_fps && values.trails == menuui.Trail_Settings{hide_others = true, hide_yours = false}, "fov, FPS and trails")
		testing.expect(t, values.audio_volumes == [4]f32{0.5, 1, 0.7, 0.3}, "master, footsteps and UI volume; effects untouched")
		testing.expect(t, abs(values.visuals.values[.SATURATION]-1.4) < 0.0001, "saturation")
		testing.expect(t, abs(menuui.ui_scale(values.hud)-0.8) < 0.0001 && !values.hud.ui_scaling_off, "scaleUI imports as UI Scale")
		vm := values.viewmodel
		testing.expect(t, vm.values[.WEAPON_FOV] == 110 && abs(vm.values[.BOBBING]-0.2) < 0.0001 && vm.values[.LEANING] == 0 && vm.values[.OFFSET_X] == 1.5 && vm.values[.ADS_FOV_POWER] == 0.5, "viewmodel values")
		testing.expect(t, abs(vm.values[.OFFSET_Y]-1.3) < 0.0001 && vm.toggles[.TOGGLE_ADS] && !vm.toggles[.SHOW_HANDS] && vm.toggles[.LEFT_HANDED] && vm.toggles[.AIM_ANIMATION], "absent viewmodel keys use Krunker defaults")
		ch := values.crosshair
		testing.expect(t, ch.color == 0x00ff00 && ch.shadow_color == 0x202020 && ch.toggles == {.CUSTOM_OPACITY = true, .ALWAYS_SHOW = true, .DOT = false}, "crosshair colors and toggles")
		testing.expect(t, abs(ch.values[.OPACITY]-0.6) < 0.0001 && ch.values[.SHADOW] == 1.5 && ch.values[.THICKNESS] == 3 && ch.values[.SIZE] == 10.5 && ch.values[.GAP] == 4, "crosshair values")
		b := values.bindings
		testing.expect(t, b[.FORWARD] == {'Z', 265} && b[.BACKWARD] == {'S', 264} && b[.LEFT] == {'Q', 263} && b[.RIGHT] == {'D', 262}, "moveKeys and sparse nulls")
		testing.expect(t, b[.CROUCH] == {'C', 0} && b[.FIRE] == {-1, 0} && b[.AIM] == {-3, 0} && b[.RELOAD] == {'F', 0} && b[.INSPECT] == {'G', 0} && b[.SECONDARY] == {-4, 0}, "named binds")
		testing.expect(t, b[.MELEE] == {menuui.BINDING_SCROLL, 0} && b[.JUMP] == {32, 0} && b[.MENU] == {256, 0}, "scroll-wheel melee (20000) imports as Scroll; absent binds stay unchanged")
	}

	@(test)
	krunker_import_partial_and_unknown :: proc(t: ^testing.T) {
		values := krunker_test_values()
		values.fov = 80
		values.bindings[.JUMP] = {'V', 0}
		values.audio_volumes[1] = 0.4
		result, error := menuui.krunker_settings_import(&values, `{"fov":120,"someFutureKey":1,"sensitivityX_3":2,"crosshairColor":"red","weaponBob":null,"aimSensitivityX":3}`)
		testing.expect_value(t, error, "")
		testing.expect_value(t, result, menuui.Krunker_Import_Result{imported = 1, ignored = 4})
		testing.expect(t, values.fov == 120 && values.mouse_dpi == 1600 && values.bindings[.JUMP] == {'V', 0} && values.audio_volumes[1] == 0.4, "known value applied; DPI, binds and effects volume preserved")
		testing.expect(t, abs(values.viewmodel.values[.BOBBING]-0.7) < 0.0001 && abs(values.audio_volumes[0]-0.8) < 0.0001 && values.crosshair.color == 0xffffff && values.sensitivity == 1,
			"absent, null and invalid values reset to Krunker defaults, as Krunker's import does")
	}

	@(test)
	krunker_import_rejects_bad_input :: proc(t: ^testing.T) {
		for text in ([?]string{"", "   ", "not json", "[1,2]", "5", `{"fov":`, `{"fov":100} x`, `{'fov':100}`, `{"fov":100`}) {
			values := krunker_test_values()
			values.fov = 77
			before := values
			result, error := menuui.krunker_settings_import(&values, text)
			testing.expectf(t, len(error) > 0 && result == {} && values == before, "bad input %q must be rejected without changes", text)
		}
	}

	@(test)
	krunker_import_clamps :: proc(t: ^testing.T) {
		values := krunker_test_values()
		values.mouse_dpi = 800
		result, error := menuui.krunker_settings_import(&values, `{"fov":500,"crosshairGap":-1000,"crosshairThick":"250","sensitivityX":100,"saturationn":3,"weaponRot":-9,"sound":2,"showFPS":"false","crosshairDot":0}`)
		testing.expect_value(t, error, "")
		testing.expect_value(t, result, menuui.Krunker_Import_Result{imported = 9, ignored = 0})
		testing.expect(t, values.fov == menuui.MAX_FOV && values.crosshair.values[.GAP] == -100 && values.crosshair.values[.THICKNESS] == 100, "Krunker ranges")
		testing.expect(t, values.sensitivity == menuui.sensitivity_validate(15, 800) && values.visuals.values[.SATURATION] == 2 && values.viewmodel.values[.ROTATION] == -2 && values.audio_volumes[0] == 1, "SR Client validators")
		testing.expect(t, !values.show_fps && !values.crosshair.toggles[.DOT], "switch coercion")
	}

	@(test)
	krunker_keycode_mapping :: proc(t: ^testing.T) {
		pairs := [?][2]i64{{87, 'W'}, {48, '0'}, {32, 32}, {13, 257}, {9, 258}, {8, 259}, {16, 340}, {17, 341}, {18, 342}, {20, 280},
			{37, 263}, {38, 265}, {39, 262}, {40, 264}, {46, 261}, {96, 320}, {105, 329}, {107, 334}, {112, 290}, {123, 301},
			{186, 59}, {187, 61}, {188, 44}, {189, 45}, {190, 46}, {191, 47}, {219, 91}, {220, 92}, {221, 93}, {222, 39},
			{-1, 0}, {10001, -1}, {10002, -3}, {10003, -2}, {10004, -4}, {10005, -5},
			{20000, i64(menuui.BINDING_SCROLL)}} // Krunker's wheel bind (20000 -> "SCROLL").
		for pair in pairs {
			code, ok := menuui.krunker_key_to_binding(pair[0])
			testing.expectf(t, ok && i64(code) == pair[1], "Krunker %d -> %d, got %d", pair[0], pair[1], code)
			js, back := menuui.binding_to_krunker_key(code)
			testing.expectf(t, back && js == pair[0], "GLFW %d -> Krunker %d, got %d", code, pair[0], js)
		}
		for rejected in ([?]i64{27, 192, 0, 255, 99999, 19999, 20001}) {
			_, ok := menuui.krunker_key_to_binding(rejected)
			testing.expectf(t, !ok, "Krunker code %d has no SR Client binding", rejected)
		}
		js, ok := menuui.binding_to_krunker_key(344)
		testing.expect(t, ok && js == 16, "right shift exports as Shift")
	}

	@(test)
	krunker_export_round_trip :: proc(t: ^testing.T) {
		source := krunker_test_values()
		_, error := menuui.krunker_settings_import(&source, KRUNKER_SAMPLE_EXPORT)
		testing.expect_value(t, error, "")
		text := menuui.krunker_settings_export(source)
		defer delete(text)
		testing.expect(t, strings.has_prefix(text, `{"showTrails":false,"showFPS":true,"crosshairSho":5,`) && strings.contains(text, `"crosshairColor":"#00ff00"`) &&
			strings.contains(text, `"fov":110,`) && strings.contains(text, `"moveKeys":[90,null,81]`) && strings.contains(text, `"aim1Key":10002`) && strings.contains(text, `"meleeKey":20000`), "export uses Krunker's keys and value encodings")
		target := krunker_test_values()
		target.fov, target.bindings[.MELEE] = 60, {'M', 0}
		result, import_error := menuui.krunker_settings_import(&target, text)
		testing.expect_value(t, import_error, "")
		testing.expect(t, result.ignored == 0 && result.imported > 0, "a SR Client export imports without ignored keys")
		testing.expect(t, target.fov == source.fov && target.sensitivity == source.sensitivity && target.invert_mouse == source.invert_mouse && target.show_fps == source.show_fps && target.trails == source.trails, "general settings round trip")
		testing.expect(t, target.audio_volumes == source.audio_volumes && target.viewmodel == source.viewmodel && target.crosshair == source.crosshair && target.visuals == source.visuals, "audio, viewmodel, crosshair and saturation round trip")
		testing.expect(t, target.bindings == source.bindings && target.bindings[.MELEE] == {menuui.BINDING_SCROLL, 0}, "changed binds round trip, including Scroll melee exported as 20000")
		source_q := source
		source_q.bindings[.MELEE] = {'Q', 0}
		q_text := menuui.krunker_settings_export(source_q)
		defer delete(q_text)
		target.bindings[.MELEE] = {'M', 0}
		menuui.krunker_settings_import(&target, q_text)
		testing.expect(t, target.bindings[.MELEE] == {'M', 0}, "Q melee equals Krunker's default, is not exported, and the target's bind stays (Krunker semantics)")
		target.bindings[.MELEE] = source.bindings[.MELEE]
		again := menuui.krunker_settings_export(target)
		defer delete(again)
		testing.expect_value(t, again, text)
		defaults := menuui.krunker_settings_export({fov = 100, sensitivity = 1, mouse_dpi = 800, audio_volumes = {0.8, 1, 1, 1}, bindings = #partial {.FORWARD = {'W', 0}, .BACKWARD = {'S', 0}, .LEFT = {'A', 0}, .RIGHT = {'D', 0}, .FIRE = {-1, 220}, .AIM = {-2, 221}},
			visuals = menuui.DEFAULT_VISUAL_SETTINGS, viewmodel = {values = #partial {.WEAPON_FOV = 95, .BOBBING = 0.7, .LEANING = 0.6, .OFFSET_X = 1, .OFFSET_Y = 1.3, .OFFSET_Z = 1, .ADS_OFFSET_Y = 1, .SWAP_Y = 1, .RELOAD_Y = 1, .ADS_FOV_POWER = 1},
			toggles = #partial {.AIM_ANIMATION = true, .SHOW_HANDS = true, .SHOW_PRIMARY = true, .SHOW_SECONDARY = true, .SHOW_MELEE = true}}, crosshair = menuui.DEFAULT_CROSSHAIR_SETTINGS, quality = menuui.DEFAULT_QUALITY_SETTINGS})
		defer delete(defaults)
		testing.expect_value(t, defaults, `{"crosshairSho":5,"showKillC":true,"showDeaths":true,"controls":{"jumpKey":-1,"crouchKey":-1,"reloadKey":-1,"primKey":-1,"swapKey":-1,"meleeKey":-1,"inspKey":-1}}`)
	}

	@(test)
	krunker_import_applies_like_save :: proc(t: ^testing.T) {
		client := Client{sensitivity = 1, audio_settings = DEFAULT_AUDIO_SETTINGS, visual_settings = menuui.DEFAULT_VISUAL_SETTINGS}
		client.menu.page = .SETTINGS
		client.menu.settings_draft = krunker_test_values()
		client.menu.settings_active = true
		client.menu.import_open = true
		client.menu.import_length = copy(client.menu.import_buffer[:], KRUNKER_SAMPLE_EXPORT)
		action := menuui.activate(&client.menu, {action = {kind = .SETTINGS_IMPORT}})
		testing.expect(t, action.kind == .SETTINGS_IMPORT && !client.menu.import_open && client.menu.page == .SETTINGS, "a successful import closes the popup and keeps Settings open")
		testing.expect_value(t, menuui.settings_message(&client.menu), "Imported 46 Krunker settings. 3 aren't in SR Client yet. 1 don't apply (controller, voice chat, effects you have off).")
		menu_apply_action(&client, action)
		testing.expect(t, abs(client.camera.fov-110*math.PI/180) < 0.000001 && abs(client.sensitivity-1.6) < 0.0001 && client.invert_mouse && client.show_fps && client.settings_dirty, "import commits the draft like Save")
		testing.expect(t, client.bindings[.FORWARD] == {'Z', 265} && client.crosshair_settings.color == 0x00ff00 && client.audio_settings == Audio_Settings{0.5, 1, 0.7, 0.3} && client.audio_settings_dirty, "binds, crosshair and audio are applied")
		testing.expect(t, client_settings_snapshot(&client).viewmodel == client.viewmodel_settings, "imported viewmodel persists with the client settings")
	}
}

@(test)
krunker_import_image_crosshair_and_quality :: proc(t: ^testing.T) {
	values := client_settings_default_values()
	text := `{"crosshairSho":"4","crosshairImage":"https://media.discordapp.net/attachments/1/2/cross.png?ex=1&format=webp","crosshairImageW":33,"crosshairImageH":35,"shadows":false,"lighting":"0","gunsVolume":0.2,"netRate":"5"}`
	result, error := menuui.krunker_settings_import(&values, text)
	testing.expect_value(t, error, "")
	testing.expect(t, values.crosshair.kind == .IMAGE, "crosshairSho 4 with an image selects the image crosshair")
	testing.expect_value(t, values.crosshair.image_url, "https://media.discordapp.net/attachments/1/2/cross.png?ex=1&format=webp")
	testing.expect(t, values.crosshair.values[.IMAGE_WIDTH] == 33 && values.crosshair.values[.IMAGE_HEIGHT] == 35, "image size comes from crosshairImageW/H")
	testing.expect(t, !values.quality.shadows && values.quality.lighting == 0, "shadows and lighting import")
	testing.expect(t, abs(values.audio_volumes[1]-0.2) < 0.0001, "gunsVolume sets the effects volume")
	testing.expect(t, result.ignored >= 1, "unsupported keys such as netRate are counted as ignored")
	// The Discord WebP preview is fetched as PNG.
	fetch := crosshair_image_fetch_url(values.crosshair.image_url, context.temp_allocator)
	testing.expect_value(t, fetch, "https://media.discordapp.net/attachments/1/2/cross.png?ex=1&format=png")
	// Export writes the image crosshair back in Krunker's keys.
	exported := menuui.krunker_settings_export(values)
	defer delete(exported)
	testing.expect(t, strings.contains(exported, `"crosshairSho":4`) && strings.contains(exported, `"crosshairImage":"https://media.discordapp.net`) && strings.contains(exported, `"crosshairImageW":33`), exported)
	// Without crosshairSho 4 the image is kept but Precision stays selected.
	values = client_settings_default_values()
	menuui.krunker_settings_import(&values, `{"crosshairImage":"https://example.com/x.png"}`)
	testing.expect(t, values.crosshair.kind == .PRECISION && values.crosshair.image_url == "https://example.com/x.png", "an image link alone does not switch the type")
}

// 0.18: Glorp-style import choices, and the Krunker keys SR Client applies
// since then (impact holes, nametag style, ping/UI, counters, health colours,
// FPS update rate, and effects SR never draws that are switched off).
@(test)
krunker_import_parts_and_new_keys :: proc(t: ^testing.T) {
	text := `{"sensitivityX":0.21,"sensitivityY":0.21,"aimSensitivityX":0.21,"aimSensitivityY":0.21,"sound":0.3,"playerVolume":0.2,"gunsVolume":0.2,"impactHoles":false,"nametagStyle":"3","showKillC":true,"showDeaths":true,"showPing":false,"healthColT":"#99d6fe","healthColE":"#ffff19","hudHealthHigh":"#009b00","hudHealthLow":"#9b0000","fpsRate":1000,"particles":false,"muzzleFlash":false,"bulletCasings":false,"screenShake":false,"deathMarkers":"3","rawMouse":true,"netRate":"5","controls":{"reloadKey":70}}`
	values := client_settings_default_values()
	values.sensitivity, values.audio_volumes = 2, {0.9, 0.9, 0.9, 0.9}
	reload := values.bindings[.RELOAD]
	result, error := menuui.krunker_settings_import(&values, text, menuui.IMPORT_ALL_PARTS - {.KEYBINDS, .SENSITIVITY, .SOUND})
	testing.expect_value(t, error, "")
	testing.expect(t, values.sensitivity == 2 && values.audio_volumes == [4]f32{0.9, 0.9, 0.9, 0.9} && values.bindings[.RELOAD] == reload, "switched-off parts keep the current sensitivity, sound and binds")
	testing.expect(t, values.hud.hide_bullet_holes && values.hud.hide_nametags && !values.hud.hide_healthbars && values.hud.hide_ping, "impact holes, Health Only nametags and ping")
	testing.expect(t, !values.hud.hide_kill_counter && !values.hud.hide_death_counter && values.hud.fps_update_ms == 1000, "counters and FPS update rate")
	colors := menuui.health_colors(values.hud)
	testing.expect(t, colors == menuui.Health_Colors{team = 0x99d6fe, enemy = 0xffff19, hud_high = 0x009b00, hud_low = 0x9b0000}, "health colours")
	testing.expect_value(t, result.ignored, 1) // netRate: SR keeps Krunker's own network timing.

	all := client_settings_default_values()
	_, error = menuui.krunker_settings_import(&all, text)
	testing.expect_value(t, error, "")
	testing.expect(t, abs(all.sensitivity-0.21) < 0.0001 && abs(all.audio_volumes[0]-0.3) < 0.0001 && all.bindings[.RELOAD][0] == 'F', "with every part on, sensitivity, sound and binds import")

	plain := client_settings_default_values()
	defaults := menuui.health_colors(plain.hud)
	testing.expect(t, defaults == menuui.Health_Colors{team = 0x9eeb56, enemy = 0xff4444, hud_high = 0x009b00, hud_low = 0x009b00}, "unset colours keep the 0.17 look")
	testing.expect_value(t, menuui.fps_update_ms(plain.hud), 250)
}

// Krunker's objOpac / adsObjOpac (the hardpoint marker): defaults 1 and 0.5,
// 0 is a real value, and they import and export as Krunker writes them.
@(test)
krunker_objective_opacity_settings :: proc(t: ^testing.T) {
	plain := client_settings_default_values()
	testing.expect_value(t, menuui.objective_opacity(plain.hud), f32(1))
	testing.expect_value(t, menuui.ads_objective_opacity(plain.hud), f32(0.5))
	export := menuui.krunker_settings_export(plain)
	testing.expect(t, !strings.contains(export, "objOpac"), "unchanged opacities are left out of the export")
	delete(export)

	values := client_settings_default_values()
	result, error := menuui.krunker_settings_import(&values, `{"objOpac":0,"adsObjOpac":0.3}`)
	testing.expect_value(t, error, "")
	testing.expect_value(t, result.imported, 2)
	testing.expect_value(t, result.ignored, 0)
	testing.expect_value(t, menuui.objective_opacity(values.hud), f32(0))
	testing.expect(t, abs(menuui.ads_objective_opacity(values.hud) - 0.3) < 0.0001, "ADS opacity imports")
	export = menuui.krunker_settings_export(values)
	defer delete(export)
	testing.expect(t, strings.contains(export, `"objOpac":0`) && strings.contains(export, `"adsObjOpac":0.3`), "both export in Krunker's form")
	testing.expect_value(t, menuui.objective_opacity_encode(2), i32(11)) // clamped to 1
	testing.expect_value(t, menuui.objective_opacity_decode(menuui.objective_opacity_encode(0.7), 0), f32(0.7))
}
