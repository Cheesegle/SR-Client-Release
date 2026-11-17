package main

import "core:testing"
import "core:os"
import "core:fmt"
import glfw "vendor:glfw"
import menuui "../menu"

when ODIN_TEST {
	// Regression: in Fullscreen the picker stayed on the live window size
	// ("2560 x 1600") whatever was picked, and Save always kept the largest mode.
	@(test)
	resolution_picker_follows_fullscreen_choice :: proc(t: ^testing.T) {
		client := Client{display_mode = .Fullscreen}
		view := menuui.View{display_mode = 2, resolution = "2560 x 1600", resolution_options = []string{"1280 x 720", "1600 x 900", "1920 x 1080", "2560 x 1440"},
			fullscreen_options = []string{"2560 x 1600", "1920 x 1200", "1920 x 1080", "1280 x 720"}}
		state := &client.menu
		state.page = .SETTINGS
		menuui.prepare_settings(state, view)
		testing.expect(t, menuui.settings_resolution_label(state, view) == "2560 x 1600", "an unset fullscreen size must show the monitor's largest mode")
		for option, i in view.fullscreen_options {
			menuui.activate(state, {action = {kind = .RESOLUTION_SELECT, index = i32(i)}})
			testing.expectf(t, menuui.settings_resolution_label(state, view) == option, "picked %s, picker shows %s", option, menuui.settings_resolution_label(state, view))
		}
		testing.expect(t, state.settings_draft.fullscreen_index == 3 && state.settings_draft.resolution_index == 0 && state.settings_resolution_selected,
			"a fullscreen pick must stage the fullscreen mode without changing the windowed preset")
		menuui.activate(state, {action = {kind = .RESOLUTION, index = 1}})
		testing.expect(t, menuui.settings_resolution_label(state, view) == "2560 x 1600", "cycling must wrap through the fullscreen modes")
		testing.expect(t, raw_data(menuui.settings_resolution_options(state, view)) == raw_data(view.fullscreen_options), "the fullscreen dropdown must list the monitor's modes")

		state.settings_draft.display_mode = 0
		menuui.activate(state, {action = {kind = .RESOLUTION_SELECT, index = 2}})
		testing.expect(t, menuui.settings_resolution_label(state, view) == "1920 x 1080" && state.settings_draft.fullscreen_index == 0,
			"windowed picks must keep using the window presets")
		state.settings_draft.display_mode = 1
		testing.expect(t, len(menuui.settings_resolution_options(state, view)) == 0 && menuui.settings_resolution_label(state, view) == "2560 x 1600",
			"borderless always covers the monitor, so its picker shows the live size and is disabled")

		menuui.activate(state, {action = {kind = .SETTINGS_CANCEL}})
		view.fullscreen_index = 2
		state.page = .SETTINGS
		menuui.prepare_settings(state, view)
		testing.expect(t, !state.settings_resolution_selected && menuui.settings_resolution_label(state, view) == "1920 x 1080", "reopening Settings must show the saved fullscreen mode")
	}

	@(test)
	resolution_picker_save_applies_monitor_mode :: proc(t: ^testing.T) {
		if !testing.expect(t, bool(glfw.Init())) do return
		defer glfw.Terminate()
		glfw.DefaultWindowHints()
		glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)
		glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
		window := glfw.CreateWindow(320, 180, "Fullscreen resolution test", nil, nil)
		if !testing.expect(t, window != nil) do return
		defer glfw.DestroyWindow(window)
		defer glfw.DefaultWindowHints()
		monitor := client_monitor(0)
		sizes := monitor_resolutions(monitor)
		if !testing.expect(t, len(sizes) > 0, "the monitor must report fullscreen modes") do return
		native_width, native_height, _ := monitor_max_video_mode(monitor)
		testing.expect(t, sizes[0] == Display_Resolution{native_width, native_height}, "the largest mode must be listed first")
		for size, i in sizes[1:] {
			testing.expect(t, size != sizes[i] && size.width*size.height <= sizes[i].width*sizes[i].height, "modes must be distinct and largest first")
		}
		width, height, rate := monitor_fullscreen_mode(monitor, {})
		testing.expect(t, width == native_width && height == native_height && rate > 0, "an unset fullscreen size must keep using the largest mode")
		smallest := sizes[len(sizes)-1]
		width, height, rate = monitor_fullscreen_mode(monitor, smallest)
		testing.expect(t, Display_Resolution{width, height} == smallest && rate > 0, "a supported fullscreen size must be applied as chosen")
		width, height, _ = monitor_fullscreen_mode(monitor, {123, 45})
		testing.expect(t, width == native_width && height == native_height, "an unsupported saved size must fall back to the largest mode")
		testing.expect(t, client_fullscreen_index(sizes, smallest) == i32(len(sizes)-1) && client_fullscreen_index(sizes, {}) == 0, "the picker must show the saved mode")

		client := Client{window = window, display_mode = .Fullscreen}
		view := menuui.View{display_mode = 2, fullscreen_options = make([]string, len(sizes), context.temp_allocator)}
		client.menu.page = .SETTINGS
		menuui.prepare_settings(&client.menu, view)
		testing.expect(t, client_staged_fullscreen_resolution(&client, client.menu.settings_draft) == Display_Resolution{}, "Save without a pick must keep the saved fullscreen size")
		menuui.activate(&client.menu, {action = {kind = .RESOLUTION_SELECT, index = i32(len(sizes)-1)}})
		testing.expect(t, client_staged_fullscreen_resolution(&client, client.menu.settings_draft) == smallest, "Save must apply the picked fullscreen mode")

		client.fullscreen_resolution = smallest
		path := "resolution-picker-test.json"
		defer os.remove(path)
		testing.expect(t, client_settings_save(client_settings_snapshot(&client), path))
		loaded := client_settings_load(path)
		testing.expect(t, Display_Resolution{loaded.fullscreen_width, loaded.fullscreen_height} == smallest, fmt.tprintf("the fullscreen size must persist, got %dx%d", loaded.fullscreen_width, loaded.fullscreen_height))
		loaded.fullscreen_width = -5
		loaded = client_settings_validate(loaded)
		testing.expect(t, loaded.fullscreen_width == 0 && loaded.fullscreen_height == 0, "an invalid saved size must fall back to the largest mode")
	}
	// The menu reads monitor modes and names from a cache, refreshed when the
	// chosen monitor changes, GLFW reports a monitor change, or Settings opens.
	@(test)
	monitor_cache_follows_monitors_and_settings :: proc(t: ^testing.T) {
		if !testing.expect(t, bool(glfw.Init())) do return
		defer glfw.Terminate()
		glfw.DefaultWindowHints()
		glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)
		glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
		window := glfw.CreateWindow(320, 180, "Monitor cache test", nil, nil)
		if !testing.expect(t, window != nil) do return
		defer glfw.DestroyWindow(window)
		defer glfw.DefaultWindowHints()
		client := Client{window = window}
		g_client = &client
		defer g_client = nil
		defer { delete(menu_portraits); menu_portraits = nil }

		view := menu_view(&client)
		sizes := monitor_resolutions(client_monitor(0))
		testing.expect(t, client.monitor_cache.valid && len(view.fullscreen_options) == len(sizes) && len(sizes) > 0, "the picker must list the monitor's modes")
		for size, i in sizes {
			testing.expectf(t, client.monitor_cache.sizes[i] == size && view.fullscreen_options[i] == fmt.tprintf("%d x %d", size.width, size.height), "mode %d must match a fresh listing", i)
		}
		monitors := glfw.GetMonitors()
		testing.expect(t, len(view.monitor_names) == len(monitors), "every monitor must be named")
		for monitor, i in monitors {
			testing.expect(t, view.monitor_names[i] == fmt.tprintf("%d: %s", i+1, glfw.GetMonitorName(monitor)), "monitor names must match GLFW")
		}

		// A stale entry stays until something invalidates it.
		append(&client.monitor_cache.sizes, Display_Resolution{1, 1})
		testing.expect(t, len(menu_view(&client).fullscreen_options) == len(sizes) + 1, "menu frames must reuse the cache")
		client_monitor_changed(nil, glfw.CONNECTED)
		testing.expect(t, len(menu_view(&client).fullscreen_options) == len(sizes), "a monitor change must refresh the cache")
		append(&client.monitor_cache.sizes, Display_Resolution{1, 1})
		client.monitor_index = 1
		testing.expect(t, len(menu_view(&client).fullscreen_options) == len(monitor_resolutions(client_monitor(1))) && client.monitor_cache.index == 1, "choosing another monitor must refresh the cache")
		append(&client.monitor_cache.sizes, Display_Resolution{1, 1})
		client.menu.page = .SETTINGS
		testing.expect(t, len(menu_view(&client).fullscreen_options) == len(monitor_resolutions(client_monitor(1))), "opening Settings must refresh the cache")

		// Menus and loading wait about one refresh per frame; gameplay is uncapped.
		testing.expect(t, client.monitor_cache.idle_frame_interval > 0 && client.monitor_cache.idle_frame_interval <= 1.0/24, "the idle frame interval must come from the refresh rate")
		testing.expect(t, client_idle_frame_interval(&client) > 0, "an unready game must not spin")
		client.game.ready = true
		testing.expect(t, client_idle_frame_interval(&client) > 0, "the menu must not spin")
		client.mouse_state.locked = true
		testing.expect(t, client_idle_frame_interval(&client) == 0, "gameplay must stay uncapped")
		client.game.ready = false
		client.krunker.connected, client.krunker_world.ready = true, true
		testing.expect(t, client_idle_frame_interval(&client) == 0, "live Krunker gameplay must stay uncapped")
		// Krunker's "ready" packet clears this during waiting/warmup while the
		// player still moves; capping then caused hitches.
		client.krunker_world.ready = false
		testing.expect(t, client_idle_frame_interval(&client) == 0, "live play during warmup must stay uncapped")
		client.mouse_state.locked = false
		testing.expect(t, client_idle_frame_interval(&client) > 0, "releasing the cursor must cap again")
	}
}
