package main

import "core:testing"
import "core:strings"
import shared "../shared"
import "core:os"
import "core:fmt"
import "core:math"
import "core:encoding/json"
import glfw "vendor:glfw"
import menuui "../menu"

when ODIN_TEST {
	@(test)
	settings_resolution_follows_window :: proc(t: ^testing.T) {
		if !testing.expect(t, bool(glfw.Init())) do return
		defer glfw.Terminate()
		glfw.DefaultWindowHints()
		glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)
		glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
		window := glfw.CreateWindow(1280, 720, "Resolution settings test", nil, nil)
		if !testing.expect(t, window != nil) do return
		defer glfw.DestroyWindow(window)
		defer glfw.DefaultWindowHints()
		client := Client{window = window, sensitivity = 1, audio_settings = DEFAULT_AUDIO_SETTINGS}
		view := menuui.View{resolution_options = []string{"1280 x 720", "1600 x 900"}}
		state := &client.menu
		state.page = .SETTINGS
		sizes := [?]Display_Resolution{{1280, 720}, {1500, 850}}
		for size in sizes {
			glfw.SetWindowSize(window, size.width, size.height)
			glfw.PollEvents()
			actual := client_window_resolution(&client)
			view.resolution = fmt.tprintf("%d x %d", actual.width, actual.height)
			menuui.prepare_settings(state, view)
			testing.expect(t, actual == size && menuui.settings_resolution_label(state, view) == fmt.tprintf("%d x %d", size.width, size.height),
				"the displayed resolution must follow actual window dimensions, including custom sizes")
		}
		menu_apply_action(&client, {kind = .SETTINGS_SAVE})
		testing.expect(t, client_window_resolution(&client) == Display_Resolution{1500, 850}, "saving unrelated preferences must preserve a manually resized window")
		menuui.activate(state, {action = {kind = .RESOLUTION_SELECT, index = 1}})
		testing.expect(t, menuui.settings_resolution_label(state, view) == "1600 x 900" && client_window_resolution(&client) == Display_Resolution{1500, 850},
			"an explicitly chosen preset must remain staged until Save")
		state.settings_draft.display_mode = 2
		testing.expect(t, menuui.settings_resolution_label(state, view) == "1500 x 850", "fullscreen must display the active size rather than a windowed preset")
		state.settings_draft.display_mode = 0
		menuui.activate(state, {action = {kind = .SETTINGS_CANCEL}})
		state.page = .SETTINGS
		menuui.prepare_settings(state, view)
		testing.expect(t, !state.settings_resolution_selected && menuui.settings_resolution_label(state, view) == "1500 x 850", "Cancel must discard a staged resolution")
		// Selecting the saved preset again must work after a manual resize.
		menuui.activate(state, {action = {kind = .RESOLUTION_SELECT, index = 0}})
		menu_apply_action(&client, {kind = .SETTINGS_SAVE})
		testing.expect(t, client_window_resolution(&client) == DISPLAY_RESOLUTIONS[0], "Save must apply an explicitly selected preset even when its index did not change")
	}

	@(test)
	settings_save_applies_draft :: proc(t: ^testing.T) {
		client := Client{sensitivity = 1, audio_settings = DEFAULT_AUDIO_SETTINGS, visual_settings = menuui.DEFAULT_VISUAL_SETTINGS}
		bindings := menuui.default_bindings()
		bindings[.JUMP][1] = -4
		client.menu.settings_draft = {sensitivity = 1.235, mouse_dpi = 1600, show_fps = true, audio_volumes = {0.5, 0.7, 0.9, 0.2}, bindings = bindings, hud = {hide_timer = true, hide_game_score = true}}
		client.menu.settings_draft.visuals = menuui.DEFAULT_VISUAL_SETTINGS
		client.menu.settings_draft.visuals.values[.GAMMA] = 1.2
		client.menu.settings_draft.quality = {smooth_textures = true, anisotropy = 4}
		client.menu.settings_draft.fov = 105
		client.menu.settings_draft.ads_sensitivity = 0.75
		client.menu.settings_draft.advanced_sensitivity, client.menu.settings_draft.invert_mouse = true, true
		client.menu.settings_draft.viewmodel = menuui.DEFAULT_VIEWMODEL_SETTINGS
		client.menu.settings_draft.viewmodel.values[.WEAPON_FOV] = 110
		client.menu.settings_draft.viewmodel.toggles[.SHOW_HANDS] = false
		client.menu.settings_draft.trails = {hide_others=true, hide_yours=true}
		client.menu.settings_draft.crosshair = menuui.DEFAULT_CROSSHAIR_SETTINGS
		client.menu.settings_draft.crosshair.values[.GAP] = -3
		client.menu.settings_draft.crosshair.color = 0x00ff00
		menu_apply_action(&client, {})
		testing.expect(t, client.sensitivity == 1 && !client.show_fps && client.audio_settings == DEFAULT_AUDIO_SETTINGS && !client.audio_settings_dirty,
			"editing the menu draft must not apply settings to the client")
		menu_apply_action(&client, {kind = .SETTINGS_SAVE})
		testing.expect(t, client.sensitivity == 1.235 && client.mouse_dpi == 1600 && client.show_fps,
			"Save must apply manual DPI and sensitivity without rounding the camera multiplier")
		testing.expect(t, abs(client.camera.fov - 105*math.PI/180) < 0.000001, "Save must apply the Gameplay FOV to the world camera")
		testing.expect(t, client.ads_sensitivity == 0.75 && client.advanced_sensitivity && client.invert_mouse, "Save must commit separate ADS sensitivity and mouse inversion")
		testing.expect(t, client.viewmodel_settings == client.menu.settings_draft.viewmodel, "Save must apply global viewmodel preferences alongside world FOV")
		testing.expect(t, client.trail_settings == client.menu.settings_draft.trails, "Save must apply both trail visibility switches")
		testing.expect(t, client.crosshair_settings == client.menu.settings_draft.crosshair && client_settings_snapshot(&client).crosshair == client.crosshair_settings, "Save and persistence snapshot must include the configured crosshair")
		testing.expect(t, client.audio_settings == Audio_Settings{0.5, 0.7, 0.9, 0.2} && client.audio_settings_dirty && client.audio_save_delay == 0.5,
			"Save must apply all audio channels and schedule their persistence")
		testing.expect(t, client.bindings == bindings && client.hud_settings.hide_timer && !client.hud_settings.hide_round_score && client.hud_settings.hide_game_score && client.settings_dirty,
			"Save must apply both bindings and each HUD preference, and persist the changes")
		testing.expect(t, client.visual_settings.values[.GAMMA] == 1.2 && client.quality_settings == menuui.Quality_Settings{smooth_textures = true, anisotropy = 4},
			"Save must commit graphics settings alongside the other categories")
	}

	@(test)
	client_settings_roundtrip :: proc(t: ^testing.T) {
		path := "bin/client-settings-test.json"
		defer os.remove(path)
		settings := client_settings_defaults()
		settings.bindings[.JUMP] = {32, -4}
		settings.bindings[.RELOAD] = {'T', 0}
		settings.bindings[.INSPECT] = {'G', -5}
		settings.bindings[.AIM] = {0, 0}
		settings.hud = {hide_round_score = true}
		settings.monitor_index, settings.display_mode, settings.resolution_index, settings.vsync = 1, 2, 2, true
		settings.visuals.values[.GAMMA], settings.visuals.values[.AMBIENT] = 1.25, 0.75
		settings.visuals.hide_cats, settings.visuals.hide_extra_props = true, true
		settings.quality = {smooth_textures=true, anisotropy=8}
		settings.trails = {hide_others=true, hide_yours=true}
		settings.crosshair.values[.OPACITY], settings.crosshair.values[.GAP] = 0.4, -3
		settings.crosshair.color, settings.crosshair.shadow_color = 0x12ab34, 0x101020
		settings.crosshair.toggles[.ALWAYS_SHOW], settings.crosshair.toggles[.CUSTOM_OPACITY], settings.crosshair.toggles[.DOT] = true, true, false
		settings.mouse_dpi = 1600
		settings.fov = 105
		settings.ads_sensitivity = 0.75
		settings.advanced_sensitivity, settings.invert_mouse = true, true
		for control in menuui.Viewmodel_Control { settings.viewmodel.values[control] = menuui.VIEWMODEL_LIMITS[control][0] }
		for toggle in menuui.Viewmodel_Toggle { settings.viewmodel.toggles[toggle] = !settings.viewmodel.toggles[toggle] }
		settings.sensitivity = menuui.sensitivity_from_cm360(35.5, settings.mouse_dpi)
		testing.expect(t, client_settings_save(settings, path))
		roundtrip := client_settings_load(path)
		testing.expect(t, abs(menuui.cm360_from_sensitivity(roundtrip.sensitivity, roundtrip.mouse_dpi)-35.5) < 0.0001, "saved sensitivity must retain the requested physical distance")
		parsed_settings := settings
		parsed_settings.sensitivity = roundtrip.sensitivity // JSON may differ by one float32 ULP.
		testing.expect(t, roundtrip == parsed_settings, "manual DPI and other preferences must survive restarting")
		legacy := settings
		legacy.visuals.values[.FOG_DISTANCE] = 4
		for group in menuui.Visual_Color { legacy.visuals.color_override[group] = true; legacy.visuals.colors[group] = {0.2,0.3,0.4} }
		data, err := json.marshal(legacy)
		defer delete(data)
		testing.expect(t, err == nil && os.write_entire_file(path, data) == nil && client_settings_load(path) == parsed_settings,
			"existing files must retain allowed preferences while discarding retired fog and color settings")
		testing.expect(t, os.write_entire_file(path, `{"version":1,"sensitivity":1.235}`) == nil)
		migrated := client_settings_load(path)
		testing.expect(t, migrated.bindings[.INSPECT] == ([2]i32{'F', 0}) && migrated.visuals.hide_cats && migrated.visuals.hide_extra_props,
			"older preferences must default inspect to F and hide cats and extra props once")
		testing.expect(t, migrated.sensitivity == 1.235 && migrated.mouse_dpi == menuui.DEFAULT_MOUSE_DPI && migrated.fov == menuui.DEFAULT_FOV, "existing preferences must retain turn speed and use the original world FOV")
		testing.expect(t, !migrated.advanced_sensitivity && !migrated.invert_mouse, "older preferences must retain automatic ADS scaling and normal vertical look")
		testing.expect(t, migrated.viewmodel == menuui.DEFAULT_VIEWMODEL_SETTINGS, "older preferences must retain the existing weapon pose, hands, ADS animation and zoom")
		testing.expect(t, migrated.trails == menuui.Trail_Settings{}, "older preferences must retain visible local and remote bullet trails")
		testing.expect(t, migrated.crosshair == menuui.DEFAULT_CROSSHAIR_SETTINGS, "older preferences must get the default Precision crosshair")
		testing.expect(t, os.write_entire_file(path, `{"version":1,"viewmodel":{"values":{"WEAPON_FOV":110},"toggles":{"TOGGLE_ADS":true,"AIM_ANIMATION":false,"HIDE_ON_ADS":true,"SHOW_HANDS":false}}}`) == nil)
		previous_viewmodel := client_settings_load(path).viewmodel
		expected_viewmodel := menuui.DEFAULT_VIEWMODEL_SETTINGS
		expected_viewmodel.values[.WEAPON_FOV] = 110
		expected_viewmodel.toggles[.TOGGLE_ADS], expected_viewmodel.toggles[.AIM_ANIMATION] = true, false
		expected_viewmodel.toggles[.HIDE_ON_ADS], expected_viewmodel.toggles[.SHOW_HANDS] = true, false
		testing.expect(t, previous_viewmodel == expected_viewmodel, "existing viewmodel preferences must preserve edits and default new weapon visibility to on and left handed to off")
		testing.expect(t, os.write_entire_file(path, `{"version":1,"sensitivity":-9,"display_mode":-5}`) == nil)
		loaded := client_settings_load(path)
		testing.expect(t, loaded.sensitivity == 1 && loaded.display_mode == 0 && loaded.bindings == menuui.default_bindings() && loaded.visuals == menuui.DEFAULT_VISUAL_SETTINGS && loaded.quality == menuui.DEFAULT_QUALITY_SETTINGS, "older preferences must keep neutral graphics, get Krunker's Shadows and Lighting defaults, and reject invalid sensitivity")
		settings.bindings[.FORWARD] = {96, -99}
		loaded = client_settings_validate(settings)
		testing.expect(t, loaded.bindings[.FORWARD] == menuui.default_bindings()[.FORWARD], "invalid and reserved key codes must never reach GLFW")
		testing.expect(t, os.write_entire_file(path, "invalid json") == nil)
		testing.expect(t, client_settings_load(path) == client_settings_defaults(), "malformed preferences must fall back safely")
	}

	@(test)
	bindings_drive_gameplay_commands :: proc(t: ^testing.T) {
		client := Client{bindings = menuui.default_bindings()}
		client.bindings[.FORWARD][1] = 'I'
		client.bindings[.FIRE][1] = -4
		primary := proc(window: glfw.WindowHandle, code: i32) -> bool { return code == 'W' }
		alternate := proc(window: glfw.WindowHandle, code: i32) -> bool { return code == 'I' || code == -4 || code == 32 }
		testing.expect(t, client_action_down(&client, .FORWARD, primary) && client_action_down(&client, .FORWARD, alternate), "either binding must activate the same action independently")
		held: [menuui.Binding_Action]bool
		for action in menuui.Binding_Action { held[action] = client_action_down(&client, action, alternate) }
		last_swap: u8
		input := client_bound_input(held, &last_swap)
		testing.expect(t, input.move_dir == 0 && input.jump && input.shoot && !input.scope && !input.reload, "alternate keyboard and mouse bindings must reach the shared gameplay command")
		held[.SECONDARY] = true
		testing.expect(t, client_bound_input(held, &last_swap).swap == 1 && client_bound_input(held, &last_swap).swap == 0, "holding a weapon key must swap only once")
		held[.SECONDARY] = false
		client_bound_input(held, &last_swap)
		held[.SECONDARY] = true
		testing.expect(t, client_bound_input(held, &last_swap).swap == 1, "releasing and pressing the key must allow another swap")
		held[.SECONDARY] = false
		client_bound_input(held, &last_swap)
		held[.PRIMARY] = true
		testing.expect(t, client_bound_input(held, &last_swap).swap == 3 && client_bound_input(held, &last_swap).swap == 0, "Krunker's Primary key sends wSwap 3, once per press")
		testing.expect(t, menuui.default_bindings()[.PRIMARY] == {'T', 0} && menuui.default_bindings()[.CHAT] == {257, 0}, "Krunker defaults: primKey T, chatKey Enter only")
	}

	// Files from before the Primary key get Krunker's defaults once: chat at
	// SR's old Enter+T moves T to Primary; a player's own later choice stays.
	@(test)
	older_settings_get_krunkers_primary_key_once :: proc(t: ^testing.T) {
		path := "test-primary-migration.json"
		defer os.remove(path)
		old := client_settings_defaults()
		old.bindings[.CHAT] = {257, 'T'}
		old.bindings[.PRIMARY] = {0, 0}
		data, _ := json.marshal(old)
		text, _ := strings.replace_all(string(data), `,"primary_key_default":true`, "")
		_ = os.write_entire_file(path, transmute([]byte)text)
		loaded := client_settings_load(path)
		testing.expect(t, loaded.bindings[.CHAT] == {257, 0} && loaded.bindings[.PRIMARY] == {'T', 0} && loaded.primary_key_default, "old default chat gives T to Primary")
		// The player then unbinds Primary; that survives the next load.
		loaded.bindings[.PRIMARY] = {0, 0}
		again, _ := json.marshal(loaded)
		_ = os.write_entire_file(path, again)
		testing.expect(t, client_settings_load(path).bindings[.PRIMARY] == {0, 0}, "a later unbind is kept")
		// A file where T is used elsewhere keeps it there.
		taken := client_settings_defaults()
		taken.bindings[.PRIMARY] = {0, 0}
		taken.bindings[.INSPECT] = {'T', 0}
		data2, _ := json.marshal(taken)
		text2, _ := strings.replace_all(string(data2), `,"primary_key_default":true`, "")
		_ = os.write_entire_file(path, transmute([]byte)text2)
		moved := client_settings_load(path)
		testing.expect(t, moved.bindings[.INSPECT] == {'T', 0} && moved.bindings[.PRIMARY] == {0, 0}, "T stays on the action the player gave it")
	}

	// Krunker's swapWeapon(player, ..., 0): code 3 goes to loadout slot 0 and is
	// nothing when already there; code 4 is equipment, not the Primary key.
	@(test)
	primary_key_swaps_to_the_first_slot :: proc(t: ^testing.T) {
		client: Client
		map_inst: shared.Map
		krunker_presentation_fixture(&client, &map_inst)
		defer krunker_presentation_cleanup(&client)
		player := client.me
		shared.player_spawn(player, 4)
		if !testing.expect(t, player.loadout_size >= 2, "the fixture class has a secondary") { return }
		shared.player_swap_weapon(player, 1, false, false, false)
		player.swap_timer = 0
		press := shared.Input{delta = 0.003, move_dir = -1, swap = 3}
		shared.player_proc_input(player, &press, false, false)
		testing.expect_value(t, player.loadout_index, 0)
		timer := player.swap_timer
		again := shared.Input{delta = 0.003, move_dir = -1, swap = 3}
		shared.player_proc_input(player, &again, false, false)
		testing.expect(t, player.loadout_index == 0 && player.swap_timer <= timer, "Primary on the primary does not swap again")
	}
}
