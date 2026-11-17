package main

import "core:fmt"
import menuui "../menu"
import clay "../third_party/clay"

// A long dropdown (e.g. a monitor's fullscreen resolutions) must scroll to its
// last option with the wheel and stay there. It used to snap back to the
// focused option every frame.
test_dropdown_scroll :: proc() -> bool {
	state := menuui.State{page = .SETTINGS, settings_tab = .VIDEO}
	if !menuui.init(&state, menu_test_measure, nil) { return false }
	defer menuui.fini(&state)
	options := []string{"3840 x 2160", "2560 x 1600", "2560 x 1440", "1920 x 1200", "1920 x 1080", "1680 x 1050", "1600 x 900", "1440 x 900", "1366 x 768", "1280 x 1024", "1280 x 800", "1280 x 720"}
	view := menuui.View{resolution_options = options, fullscreen_options = options, monitor_names = []string{"Primary monitor"}}
	menu_test_frame(&state, view, {})
	menu_test_frame(&state, view, {})
	menu_test_click(&state, view, clay.ID("Resolution"))
	menu_test_frame(&state, view, {})
	if state.settings_dropdown != .RESOLUTION { fmt.println("Resolution dropdown did not open"); return false }

	list := clay.GetElementData(clay.ID("SettingsOptions")).boundingBox
	over := menuui.Input{pointer = {list.x + list.width / 2, list.y + list.height / 2}}
	wheel := over
	wheel.scroll = {0, -3}
	for _ in 0 ..< 30 { menu_test_frame(&state, view, wheel) }
	for _ in 0 ..< 30 { menu_test_frame(&state, view, over) } // let any snap-back happen
	data := clay.GetScrollContainerData(clay.ID("SettingsOptions"))
	if !data.found || data.scrollPosition[1] > -1 {
		fmt.println("Dropdown snapped back to the top after scrolling", data.scrollPosition[1]); return false
	}
	list = clay.GetElementData(clay.ID("SettingsOptions")).boundingBox
	last := clay.GetElementData(clay.ID("SettingsOption", u32(len(options) - 1))).boundingBox
	if last.y < list.y - 1 || last.y + last.height > list.y + list.height + 1 {
		fmt.println("The last resolution cannot be scrolled into view", last, list); return false
	}
	// Keyboard navigation still reveals the option it moves to.
	for _ in 0 ..< len(options) { menu_test_frame(&state, view, {up = true}); menu_test_frame(&state, view, over) }
	first := clay.GetElementData(clay.ID("SettingsOption", 0)).boundingBox
	list = clay.GetElementData(clay.ID("SettingsOptions")).boundingBox
	if state.focus == clay.ID("SettingsOption", 0).id && (first.y < list.y - 1 || first.y > list.y + list.height) {
		fmt.println("Keyboard focus did not reveal the first option"); return false
	}
	fmt.println("Dropdown wheel scrolling reaches the last option OK")
	return true
}
