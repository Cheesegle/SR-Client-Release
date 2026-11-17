package main

import "core:mem"
import "core:os"
import "core:testing"
import menuui "../menu"

when ODIN_TEST {
	// A client whose saved preferences differ from the defaults everywhere
	// Save can change without a window (display settings need one).
	settings_reset_test_client :: proc() -> Client {
		client := Client{sensitivity = 2, mouse_dpi = 1600, ads_sensitivity = 0.5, advanced_sensitivity = true, invert_mouse = true,
			show_fps = true, vsync = true, menu_fps_limit = menuui.MENU_FPS_LIMITS[2], bindings = menuui.default_bindings(),
			hud_settings = {hide_timer = true, hide_ping = true}, visual_settings = menuui.DEFAULT_VISUAL_SETTINGS, quality_settings = {smooth_textures = true, anisotropy = 4},
			viewmodel_settings = menuui.DEFAULT_VIEWMODEL_SETTINGS, trail_settings = {hide_others = true}, crosshair_settings = menuui.DEFAULT_CROSSHAIR_SETTINGS,
			audio_settings = {0.1, 0.2, 0.3, 0.4}, max_anisotropy = 16}
		client.camera.fov = 110 * 3.14159265 / 180
		client.bindings[.JUMP] = {'V', -4}
		client.bindings[.FIRE] = {0, 0}
		client.visual_settings.values[.GAMMA] = 1.3
		client.visual_settings.night_mode = true
		client.viewmodel_settings.toggles[.SHOW_HANDS] = false
		client.crosshair_settings.color = 0x00ff00
		return client
	}

	@(test)
	settings_reset_defaults_match_the_loader :: proc(t: ^testing.T) {
		defaults := client_settings_default_values()
		loader := client_settings_validate(client_settings_defaults())
		testing.expect(t, defaults.bindings == menuui.default_bindings() && defaults.fov == loader.fov && defaults.mouse_dpi == loader.mouse_dpi, "Reset uses the loader's defaults")
		testing.expect(t, defaults.audio_volumes == {DEFAULT_AUDIO_SETTINGS.master, DEFAULT_AUDIO_SETTINGS.effects, DEFAULT_AUDIO_SETTINGS.footsteps, DEFAULT_AUDIO_SETTINGS.ui}, "Reset uses the audio defaults")
		testing.expect(t, defaults != {}, "the menu enables Reset only for non-zero defaults")

		// Every saved preference returns to the loader's value: applying the
		// reset draft and snapshotting gives exactly the missing-file defaults.
		// A preference added to Client_Settings, the snapshot and Save, but not
		// to client_settings_default_values, fails here.
		client := settings_reset_test_client()
		client.menu.settings_draft = defaults
		menu_apply_action(&client, {kind = .SETTINGS_SAVE})
		snapshot := client_settings_snapshot(&client)
		snapshot.fov = loader.fov // Radians round trip; checked below.
		testing.expect(t, abs(client.camera.fov*180/3.14159265 - loader.fov) < 0.001, "Save after Reset restores the default FOV")
		testing.expect(t, snapshot == loader, "Save after Reset persists exactly the missing-file defaults")
		testing.expect(t, client.settings_dirty && client.audio_settings == DEFAULT_AUDIO_SETTINGS && client.audio_settings_dirty, "Save after Reset applies and schedules persistence of settings and audio")

		path := "bin/client-settings-reset-test.json"
		defer os.remove(path)
		testing.expect(t, client_settings_save(client_settings_snapshot(&client), path))
		loaded := client_settings_load(path)
		loaded.fov = loader.fov
		testing.expect(t, loaded == loader, "the reset preferences survive a restart")

		view := menu_view(&client)
		defer { delete(menu_portraits); menu_portraits = nil }
		testing.expect(t, view.settings_defaults == defaults, "the menu view carries the defaults to the Reset button")
	}

	@(test)
	settings_reset_tabs_cover_every_setting :: proc(t: ^testing.T) {
		defaults := client_settings_default_values()
		// Fill every byte so any field that no tab resets stays visibly wrong.
		draft: menuui.Settings_Values
		mem.set(&draft, 0x5a, size_of(draft))
		for tab in menuui.Settings_Tab { menuui.settings_reset_tab(&draft, defaults, tab) }
		testing.expect(t, draft == defaults, "each setting belongs to a tab, so resetting every tab equals Reset all")

		draft = client_settings_default_values()
		draft.bindings[.JUMP] = {'V', 0}
		draft.sensitivity, draft.fov = 2, 110
		menuui.settings_reset_tab(&draft, defaults, .INPUT)
		testing.expect(t, draft.bindings == defaults.bindings && draft.sensitivity == defaults.sensitivity && draft.fov == 110, "Controls resets key binds and sensitivity only")
	}

	@(test)
	settings_reset_save_and_cancel :: proc(t: ^testing.T) {
		client := settings_reset_test_client()
		saved := client_settings_snapshot(&client)
		saved_audio := client.audio_settings
		view := menu_view(&client)
		defer { delete(menu_portraits); menu_portraits = nil }
		state := &client.menu
		state.page = .SETTINGS
		menuui.prepare_settings(state, view)
		testing.expect(t, state.settings_draft.bindings[.JUMP] == {'V', -4}, "the draft starts from the saved settings")

		// Confirmation: opening Reset changes nothing.
		menuui.activate(state, {action = {kind = .SETTINGS_RESET_OPEN}})
		testing.expect(t, state.reset_open && state.settings_draft.bindings[.JUMP] == {'V', -4}, "Reset asks before changing anything")
		menuui.activate(state, {action = {kind = .SETTINGS_RESET_CLOSE}})
		testing.expect(t, !state.reset_open && state.settings_draft.bindings[.JUMP] == {'V', -4}, "declining keeps the draft")

		// Reset all, then Cancel: nothing is applied and the draft reverts.
		menuui.activate(state, {action = {kind = .SETTINGS_RESET_OPEN}})
		menuui.activate(state, {action = {kind = .SETTINGS_RESET}})
		testing.expect(t, state.settings_draft == client_settings_default_values(), "Reset all fills the draft with the defaults, key binds included")
		testing.expect(t, client_settings_snapshot(&client) == saved, "Reset does not apply until Save")
		menu_apply_action(&client, menuui.activate(state, {action = {kind = .SETTINGS_CANCEL}}))
		testing.expect(t, client_settings_snapshot(&client) == saved && client.audio_settings == saved_audio && !client.settings_dirty, "Cancel after Reset keeps the saved settings")
		state.page = .SETTINGS
		menuui.prepare_settings(state, view)
		testing.expect(t, state.settings_draft.bindings[.JUMP] == {'V', -4} && state.settings_draft.sensitivity == 2, "reopening Settings after Cancel shows the saved settings")

		// Reset all, then Save: the defaults are applied and persisted.
		menuui.activate(state, {action = {kind = .SETTINGS_RESET_OPEN}})
		menuui.activate(state, {action = {kind = .SETTINGS_RESET}})
		menu_apply_action(&client, menuui.activate(state, {action = {kind = .SETTINGS_SAVE}}))
		testing.expect(t, client.bindings == menuui.default_bindings() && client.sensitivity == 1 && !client.show_fps && client.settings_dirty, "Save after Reset applies the defaults")
	}
}
