package main

import "core:testing"
import "core:os"
import menuui "../menu"

when ODIN_TEST {
	@(private="file")
	fps_limit_test_client :: proc(client: ^Client) {
		client^ = {sensitivity = 1, audio_settings = DEFAULT_AUDIO_SETTINGS, visual_settings = menuui.DEFAULT_VISUAL_SETTINGS}
		// A valid cache keeps GLFW out of the test: a 240 Hz monitor.
		client.monitor_cache.valid, client.monitor_cache.idle_frame_interval = true, 1.0/240
	}

	@(test)
	menu_fps_limit_persistence :: proc(t: ^testing.T) {
		testing.expect(t, client_settings_defaults().menu_fps_limit == menuui.MENU_FPS_LIMIT_MONITOR, "the default menu FPS limit must be Monitor refresh")
		path := "bin/client-settings-fps-limit-test.json"
		defer os.remove(path)
		for limit in menuui.MENU_FPS_LIMITS {
			settings := client_settings_defaults()
			settings.menu_fps_limit = limit
			testing.expect(t, client_settings_save(settings, path))
			testing.expectf(t, client_settings_load(path).menu_fps_limit == limit, "menu FPS limit %d must survive restarting", limit)
		}
		testing.expect(t, os.write_entire_file(path, `{"version":1,"sensitivity":1.235,"vsync":true}`) == nil)
		testing.expect(t, client_settings_load(path).menu_fps_limit == menuui.MENU_FPS_LIMIT_MONITOR, "older settings files must get Monitor refresh")
		testing.expect(t, os.write_entire_file(path, `{"version":1,"menu_fps_limit":75}`) == nil)
		testing.expect(t, client_settings_load(path).menu_fps_limit == menuui.MENU_FPS_LIMIT_MONITOR, "an unknown limit must fall back to Monitor refresh")
		client: Client
		fps_limit_test_client(&client)
		client.menu_fps_limit = 120
		testing.expect(t, client_settings_snapshot(&client).menu_fps_limit == 120, "the saved snapshot must include the menu FPS limit")
	}

	@(test)
	menu_fps_limit_interval :: proc(t: ^testing.T) {
		client: Client
		fps_limit_test_client(&client)
		expected := [7]f64{1.0/240, 1.0/30, 1.0/60, 1.0/120, 1.0/144, 1.0/240, 0}
		for limit, i in menuui.MENU_FPS_LIMITS {
			client.menu_fps_limit = limit
			client.mouse_state.locked = false
			got := client_idle_frame_interval(&client)
			testing.expectf(t, abs(got - expected[i]) < 1e-12, "limit %d must wait %f s, got %f", limit, expected[i], got)
			client.mouse_state.locked = true
			testing.expectf(t, client_idle_frame_interval(&client) == 0, "captured gameplay must stay uncapped with limit %d", limit)
		}
		client.mouse_state.locked = false
		client.menu_fps_limit = menuui.MENU_FPS_LIMIT_MONITOR
		client.monitor_cache.idle_frame_interval = 1.0/60
		testing.expect(t, client_idle_frame_interval(&client) == 1.0/60, "Monitor refresh must follow the monitor cache")

		// Deadlines advance by whole intervals so jitter does not lower the rate.
		interval := 1.0/144
		testing.expect(t, client_idle_frame_deadline(0, 10, interval) == 10+interval, "pacing starts one interval after the frame")
		testing.expect(t, client_idle_frame_deadline(10, 10.0005, interval) == 10+interval, "a late wakeup must not push the next deadline")
		testing.expect(t, client_idle_frame_deadline(10, 10.5, interval) == 10.5+interval, "a long frame must restart the schedule instead of bursting")
		testing.expect(t, client_idle_frame_deadline(10, 9, interval) == 9+interval, "a deadline too far ahead must restart the schedule")
		client.idle_frame_deadline = 5
		client_pace_idle_frame(&client, 6, 0)
		testing.expect(t, client.idle_frame_deadline == 0, "uncapped frames must reset the schedule")
	}

	@(test)
	menu_fps_limit_draft :: proc(t: ^testing.T) {
		client: Client
		fps_limit_test_client(&client)
		client.menu_fps_limit = 60
		view := menuui.View{sensitivity = 1, menu_fps_limit = client.menu_fps_limit, visuals = menuui.DEFAULT_VISUAL_SETTINGS}
		state := &client.menu
		state.page = .SETTINGS
		menuui.prepare_settings(state, view)
		testing.expect(t, state.settings_draft.menu_fps_limit == 60, "the draft must start from the saved limit")

		// The staged limit previews live and Cancel restores the saved one.
		menuui.activate(state, {action = {kind = .MENU_FPS_LIMIT, index = 6}})
		testing.expect(t, client_idle_frame_interval(&client) == 0 && client.menu_fps_limit == 60, "Unlimited must preview without being applied")
		menuui.activate(state, {action = {kind = .SETTINGS_CANCEL}})
		testing.expect(t, client_idle_frame_interval(&client) == 1.0/60 && client.menu_fps_limit == 60 && !client.settings_dirty, "Cancel must restore the saved limit")

		// Save applies and persists it.
		state.page = .SETTINGS
		menuui.prepare_settings(state, view)
		menuui.activate(state, {action = {kind = .MENU_FPS_LIMIT, index = 4}})
		menu_apply_action(&client, menuui.activate(state, {action = {kind = .SETTINGS_SAVE}}))
		testing.expect(t, client.menu_fps_limit == 144 && client.settings_dirty && client_settings_snapshot(&client).menu_fps_limit == 144, "Save must apply and persist the limit")
		testing.expect(t, abs(client_idle_frame_interval(&client) - 1.0/144) < 1e-12, "the saved limit must cap the menu")
	}
}
