package main

import "core:fmt"
import menuui "../menu"
import clay "../third_party/clay"

@(private="file")
search_test_shown :: proc(state: ^menuui.State, id: clay.ElementId) -> bool {
	for control in state.controls[:state.control_count] { if control.id.id == id.id { return true } }
	return false
}

@(private="file")
search_test_type :: proc(state: ^menuui.State, view: menuui.View, query: string) {
	menu_test_frame(state, view, {clear_text = true})
	menu_test_frame(state, view, {text = query})
	menu_test_frame(state, view, {})
}

test_fuzzy_matcher :: proc() -> bool {
	matches := [?][2]string{
		{"shp", "Show Ping"}, {"hbar", "Show healthbars"}, {"SHOW PING", "Show Ping"}, {"showping", "Show Ping"},
		{"ping", "Show Ping"}, {"fov", "Field of view (FOV)"}, {"olume", "Master volume"}, {"e", "Hide cats"},
		{"crouch", "Crouch / slide"}, {"vsync", "V-Sync"}, {"wfov", "Weapon FOV"},
	}
	for pair in matches {
		if !menuui.fuzzy_match(pair[0], pair[1]) { fmt.println("Fuzzy search should match:", pair); return false }
	}
	misses := [?][2]string{
		{"xyz", "Show Ping"}, {"pings", "Show Ping"}, {"gnip", "Show Ping"}, {"sat", "Show nametags"}, {"pingshow", "Show Ping"},
	}
	for pair in misses {
		if menuui.fuzzy_match(pair[0], pair[1]) { fmt.println("Fuzzy search should not match:", pair); return false }
	}
	if !menuui.fuzzy_match("", "Anything") || !menuui.fuzzy_match("  ", "Anything") { fmt.println("An empty query matches every row"); return false }
	// Synonyms: "disable" finds Hide rows and "enable" finds Show rows.
	synonyms := [?][2]string{
		{"disable", "Hide cats"}, {"disable cats", "Hide cats"}, {"Disable", "Hide extra props"},
		{"disable extra props", "Hide extra props"}, {"remove props", "Hide extra props"},
		{"enable ping", "Show Ping"}, {"display fps", "Show FPS"}, {"hide cats", "Hide cats"},
	}
	for pair in synonyms {
		if !menuui.search_label_match(pair[0], pair[1]) { fmt.println("Synonym search should match:", pair); return false }
	}
	synonym_misses := [?][2]string{
		{"disable", "Master volume"}, {"disable ping", "Show Ping"}, {"enable cats", "Hide cats"}, {"disable", "Hideout"},
	}
	for pair in synonym_misses {
		if menuui.search_label_match(pair[0], pair[1]) { fmt.println("Synonym search should not match:", pair); return false }
	}
	ranked := [?][3]string{
		// Query, better label, worse label: prefixes and contiguous runs beat
		// word-start abbreviations, which beat matches in the middle of words.
		{"ping", "Show Ping", "Shopping"},
		{"sho", "Show Ping", "Hide shots"},
		{"ads", "ADS (cm/360)", "Aim down sights"},
	}
	for entry in ranked {
		better, _ := menuui.fuzzy_score(entry[0], entry[1])
		worse, _ := menuui.fuzzy_score(entry[0], entry[2])
		if better <= worse { fmt.println("Fuzzy ranking failed:", entry, better, worse); return false }
	}
	// Equal word-start abbreviations score alike regardless of label length.
	a, _ := menuui.fuzzy_score("sh", "Show healthbars")
	b, _ := menuui.fuzzy_score("sh", "Show hands")
	if a != b { fmt.println("Fuzzy score should not depend on unmatched text"); return false }
	fmt.println("Fuzzy settings matcher tests OK")
	return true
}

test_settings_search :: proc() -> bool {
	state := menuui.State{}
	if !menuui.init(&state, menu_test_measure, nil) { return false }
	defer menuui.fini(&state)
	view := menuui.View{online = true, ready = true, resolution = "1920 x 1080", sensitivity = 1, audio_volumes = {0.8, 1, 0.5, 0}}
	view.bindings = menuui.default_bindings()
	view.resolution_options = []string{"1280 x 720", "1920 x 1080"}
	view.monitor_names = []string{"Primary monitor", "Second monitor"}
	view.max_anisotropy = 16
	state.page = .SETTINGS
	state.settings_tab = .VIDEO
	menu_test_frame(&state, view, {})
	search := clay.ID("SettingsSearch")
	if !search_test_shown(&state, search) { fmt.println("The settings header must contain the search field"); return false }
	if menu_test_click(&state, view, search).kind != .NONE || !menuui.settings_search_focused(&state) { fmt.println("Clicking the search field must focus it"); return false }

	// Results span every tab: key binds and a Gameplay slider both match "reload".
	search_test_type(&state, view, "reload")
	if !menuui.settings_searching(&state) || state.page != .SETTINGS { fmt.println("Typing must start a search"); return false }
	if !search_test_shown(&state, clay.ID("Binding", u32(menuui.Binding_Action.RELOAD)*2)) || !search_test_shown(&state, clay.ID("WeaponReloadY")) {
		fmt.println("Search must list matching rows from every tab"); return false
	}
	if search_test_shown(&state, clay.ID("VSync")) || search_test_shown(&state, clay.ID("Binding", u32(menuui.Binding_Action.JUMP)*2)) {
		fmt.println("Search must hide rows that do not match"); return false
	}
	if state.errors != 0 { fmt.println("Search results reported a layout error"); return false }

	// "Disable" finds the Hide cats / Hide extra props rows through synonyms.
	search_test_type(&state, view, "Disable")
	if !search_test_shown(&state, clay.ID("HideCats")) || !search_test_shown(&state, clay.ID("HideExtraProps", 1)) {
		fmt.println("Searching Disable must list Hide cats and Hide extra props"); return false
	}
	if search_test_shown(&state, clay.ID("VSync")) { fmt.println("Searching Disable must hide unrelated rows"); return false }

	// "night" finds Night mode and its strength slider.
	search_test_type(&state, view, "night")
	if !search_test_shown(&state, clay.ID("NightMode", 2)) || !search_test_shown(&state, clay.ID("NightStrength")) { fmt.println("Searching night must list Night mode and Night strength"); return false }
	if search_test_shown(&state, clay.ID("HideCats")) { fmt.println("Searching night must hide unrelated rows"); return false }
	search_test_type(&state, view, "reload")

	// Fuzzy abbreviations, and toggling a result in place.
	search_test_type(&state, view, "hbar")
	healthbars := clay.ID("HudHealthbars", 5)
	if !search_test_shown(&state, healthbars) || search_test_shown(&state, clay.ID("HudPing", 3)) { fmt.println("\"hbar\" must find Show healthbars only"); return false }
	before := state.settings_draft.hud.hide_healthbars
	if menu_test_click(&state, view, healthbars).kind != .NONE || state.settings_draft.hud.hide_healthbars == before || !menuui.settings_searching(&state) {
		fmt.println("A search result toggle must work in place"); return false
	}
	menu_test_click(&state, view, healthbars)
	if state.settings_draft.hud.hide_healthbars != before { fmt.println("Toggling a result twice must restore it"); return false }

	// Sliders in results stay interactive, and section names match their rows.
	menu_test_click(&state, view, search)
	search_test_type(&state, view, "interface")
	if !search_test_shown(&state, clay.ID("HudNametags", 4)) || !search_test_shown(&state, healthbars) { fmt.println("A matching section must list all of its rows"); return false }
	search_test_type(&state, view, "effects")
	box := clay.GetElementData(clay.ID("EffectsVolume")).boundingBox
	menu_test_frame(&state, view, {pointer = {box.x + box.width*0.25, box.y + box.height*0.5}, down = true})
	menu_test_frame(&state, view, {pointer = {box.x + box.width*0.25, box.y + box.height*0.5}})
	if abs(state.settings_draft.audio_volumes[1] - 0.25) > 0.02 { fmt.println("A search result slider must work in place", state.settings_draft.audio_volumes[1]); return false }

	// The menu FPS limit row is found by its label.
	menu_test_click(&state, view, search)
	search_test_type(&state, view, "fps limit")
	if !search_test_shown(&state, clay.ID("MenuFpsLimit")) || search_test_shown(&state, clay.ID("VSync")) { fmt.println("Searching fps limit must list Menu FPS limit only"); return false }

	// No matches.
	menu_test_click(&state, view, search)
	search_test_type(&state, view, "zzqx")
	if !clay.GetElementData(clay.ID("SettingsSearchEmpty")).found { fmt.println("An unmatched search must say No settings found"); return false }

	// Typed letters only edit the query; they never trigger menu actions or binds.
	bindings := state.settings_draft.bindings
	menu_test_frame(&state, view, {clear_text = true})
	for c in "wasd erqf" {
		buffer := [1]u8{u8(c)}
		if menu_test_frame(&state, view, {text = string(buffer[:])}).kind != .NONE || state.binding_capture != 0 || state.page != .SETTINGS {
			fmt.println("Typing in search must not trigger an action"); return false
		}
	}
	if menuui.settings_search_query(&state) != "wasd erqf" || state.settings_draft.bindings != bindings { fmt.println("Typed letters must go to the search field only", menuui.settings_search_query(&state)); return false }
	if menu_test_frame(&state, view, {enter = true}).kind != .NONE || !menuui.settings_search_focused(&state) { fmt.println("Enter in search must not activate anything"); return false }
	menu_test_frame(&state, view, {})

	// Clearing the box restores the normal tab view.
	menu_test_frame(&state, view, {backspace = true})
	menu_test_frame(&state, view, {})
	if menuui.settings_search_query(&state) != "wasd erq" { fmt.println("Backspace must delete one character"); return false }
	menu_test_frame(&state, view, {clear_text = true})
	menu_test_frame(&state, view, {})
	if menuui.settings_searching(&state) || state.settings_tab != .VIDEO || !search_test_shown(&state, clay.ID("VSync")) || search_test_shown(&state, clay.ID("EffectsVolume", 1)) {
		fmt.println("Clearing the search must restore the selected tab"); return false
	}

	// Escape with text clears the search and leaves the field, without closing.
	search_test_type(&state, view, "ping")
	if menu_test_frame(&state, view, {escape = true}).kind != .NONE || state.page != .SETTINGS || menuui.settings_searching(&state) || menuui.settings_search_focused(&state) {
		fmt.println("Escape in search must clear it and keep Settings open"); return false
	}
	menu_test_frame(&state, view, {})
	if !search_test_shown(&state, clay.ID("VSync")) { fmt.println("Escape must restore the tab view"); return false }
	// Escape with focus but no text only leaves the field.
	menu_test_click(&state, view, search)
	if menu_test_frame(&state, view, {escape = true}).kind != .NONE || state.page != .SETTINGS || menuui.settings_search_focused(&state) {
		fmt.println("Escape in an empty focused search must keep Settings open"); return false
	}
	menu_test_frame(&state, view, {})
	// Escape with text but focus on a result still clears the search first.
	menu_test_click(&state, view, search)
	search_test_type(&state, view, "hbar")
	menu_test_click(&state, view, healthbars)
	if menu_test_frame(&state, view, {escape = true}).kind != .NONE || state.page != .SETTINGS || menuui.settings_searching(&state) {
		fmt.println("Escape must clear an unfocused search before closing"); return false
	}
	menu_test_frame(&state, view, {})

	// Choosing a tab clears the search, as Krunker's changeTab does.
	menu_test_click(&state, view, search)
	search_test_type(&state, view, "fov")
	menu_test_click(&state, view, clay.ID("SettingsTab", u32(menuui.Settings_Tab.AUDIO)))
	menu_test_frame(&state, view, {})
	if menuui.settings_searching(&state) || state.settings_tab != .AUDIO { fmt.println("Selecting a tab must clear the search"); return false }

	// Keyboard focus walks the results and scrolls them into view.
	menu_test_click(&state, view, search)
	search_test_type(&state, view, "e")
	if state.errors != 0 || state.control_count >= len(state.controls) { fmt.println("A broad search must fit the control list", state.control_count); return false }
	for _ in 0..<len(state.controls) {
		if state.focus == healthbars.id { break }
		menu_test_frame(&state, view, {tab = true})
		menu_test_frame(&state, view, {})
	}
	menu_test_frame(&state, view, {})
	panel := clay.GetElementData(clay.ID("SettingsPanel")).boundingBox
	row := clay.GetElementData(healthbars).boundingBox
	if state.focus != healthbars.id || row.y < panel.y-1 || row.y+row.height > panel.y+panel.height+1 { fmt.println("Keyboard focus must scroll search results into view"); return false }
	if menuui.settings_search_query(&state) != "e" { fmt.println("Tab must move focus, not type"); return false }

	// The second Escape (focus is on a result, the search is cleared) closes
	// Settings; the search text is not kept for the next visit.
	menu_test_frame(&state, view, {escape = true})
	menu_test_frame(&state, view, {})
	menu_test_frame(&state, view, {escape = true})
	if state.page != .HOME { fmt.println("Escape must close Settings once the search is cleared"); return false }
	state.page = .SETTINGS
	menu_test_frame(&state, view, {})
	if menuui.settings_searching(&state) { fmt.println("Search text must not persist between visits"); return false }
	fmt.println("Settings search tests OK")
	return true
}

// Settings > Video > Menu FPS limit: a dropdown staged in the draft until Save.
test_menu_fps_limit_setting :: proc() -> bool {
	state := menuui.State{}
	if !menuui.init(&state, menu_test_measure, nil) { return false }
	defer menuui.fini(&state)
	view := menuui.View{online = true, ready = true, resolution = "1920 x 1080", sensitivity = 1}
	view.bindings = menuui.default_bindings()
	view.menu_fps_limit = 75 // Not an option: the draft falls back to Monitor refresh.
	state.page = .SETTINGS
	state.settings_tab = .VIDEO
	menu_test_frame(&state, view, {})
	field := clay.ID("MenuFpsLimit")
	if !search_test_shown(&state, field) || state.settings_draft.menu_fps_limit != menuui.MENU_FPS_LIMIT_MONITOR { fmt.println("The Video tab must show the Menu FPS limit at Monitor refresh"); return false }
	if len(menuui.MENU_FPS_LIMITS) != 7 || menuui.MENU_FPS_LIMIT_LABELS[0] != "Monitor refresh" || menuui.MENU_FPS_LIMIT_LABELS[6] != "Unlimited" { fmt.println("Unexpected menu FPS limit options"); return false }
	// The VRR cap row and notes push the field below the fold at 720p.
	menu_test_reveal(&state, view, field)
	menu_test_click(&state, view, field)
	if state.settings_dropdown != .MENU_FPS_LIMIT || state.focus != clay.ID("SettingsOption", 0).id { fmt.println("Opening the dropdown must focus the current limit"); return false }
	menu_test_frame(&state, view, {})
	menu_test_click(&state, view, clay.ID("SettingsOption", 4))
	if state.settings_dropdown != .NONE || state.settings_draft.menu_fps_limit != 144 { fmt.println("Choosing 144 must stage it", state.settings_draft.menu_fps_limit); return false }
	menu_test_frame(&state, view, {})
	menu_test_click(&state, view, field)
	if state.focus != clay.ID("SettingsOption", 4).id { fmt.println("Reopening the dropdown must focus 144"); return false }
	menuui.activate(&state, {id = clay.ID("SettingsOption", 6), action = {kind = .MENU_FPS_LIMIT, index = 6}})
	if state.settings_draft.menu_fps_limit != menuui.MENU_FPS_LIMIT_UNLIMITED { fmt.println("Choosing Unlimited must stage -1"); return false }
	if menuui.activate(&state, {action = {kind = .SETTINGS_SAVE}}).kind != .SETTINGS_SAVE { fmt.println("Save must reach the client"); return false }
	if state.errors != 0 { fmt.println("The Menu FPS limit dropdown reported a layout error"); return false }
	fmt.println("Menu FPS limit setting tests OK")
	return true
}
