package main

import "core:os"
import "core:strings"
import "core:testing"
import glfw "vendor:glfw"
import menuui "../menu"

when ODIN_TEST {
	unbind_test_every_key :: proc(window: glfw.WindowHandle, code: i32) -> bool { return true }

	@(test)
	unbound_actions_never_fire :: proc(t: ^testing.T) {
		client := Client{bindings = menuui.default_bindings()}
		client.bindings[.JUMP] = {0, 0}
		client.bindings[.FIRE] = {0, 0}
		client.bindings[.FORWARD] = {0, 'I'}
		// Even a reader that reports every code as held never fires an unbound slot.
		testing.expect(t, !client_action_down(&client, .JUMP, unbind_test_every_key) && !client_action_down(&client, .FIRE, unbind_test_every_key), "an action with both slots unbound never fires")
		testing.expect(t, client_action_down(&client, .FORWARD, unbind_test_every_key), "the remaining bound slot still fires")
		testing.expect(t, !client_binding_down(nil, 0), "code 0 is never read from GLFW")

		// Every action unbound: no command, no crash.
		for action in menuui.Binding_Action { client.bindings[action] = {0, 0} }
		bound, sustained := client_gameplay_bound_input(&client, unbind_test_every_key)
		testing.expect(t, bound.move_dir == -1 && !bound.jump && !bound.shoot && !bound.scope && !bound.reload && !bound.crouch && bound.swap == 0, "a fully unbound layout produces an idle command")
		testing.expect(t, sustained == bound)
		client.mouse_state.locked, client.scroll_press = true, true
		testing.expect(t, !client_action_down(&client, .MELEE, unbind_test_every_key), "a Scroll press does not reach an unbound action")
	}

	@(test)
	unbound_slots_persist_and_apply :: proc(t: ^testing.T) {
		path := "bin/client-settings-unbind-test.json"
		defer os.remove(path)
		settings := client_settings_defaults()
		settings.bindings[.JUMP] = {0, 0}
		settings.bindings[.RELOAD] = {0, 'T'}
		testing.expect(t, client_settings_validate(settings).bindings == settings.bindings, "validation keeps unbound slots unbound")
		testing.expect(t, client_settings_save(settings, path))
		loaded := client_settings_load(path)
		testing.expect(t, loaded.bindings[.JUMP] == {0, 0} && loaded.bindings[.RELOAD] == {0, 'T'}, "unbound slots survive a restart instead of reverting to defaults")

		// Unbinding in the menu only changes the draft until Save.
		client := Client{sensitivity = 1, audio_settings = DEFAULT_AUDIO_SETTINGS, bindings = menuui.default_bindings()}
		client.menu.settings_draft.bindings = menuui.default_bindings()
		menuui.activate(&client.menu, {action = {kind = .UNBIND_KEY, index = i32(menuui.Binding_Action.JUMP)*2}})
		testing.expect(t, client.menu.settings_draft.bindings[.JUMP] == {0, 0} && client.bindings[.JUMP] == {32, 0}, "unbinding stages the change")
		menu_apply_action(&client, {kind = .UNBIND_KEY})
		testing.expect(t, client.bindings[.JUMP] == {32, 0}, "the unbind action itself applies nothing")
		menu_apply_action(&client, {kind = .SETTINGS_SAVE})
		testing.expect(t, client.bindings[.JUMP] == {0, 0} && client.settings_dirty && client_settings_snapshot(&client).bindings[.JUMP] == {0, 0}, "Save applies and persists the unbound slot")
	}

	@(test)
	unbound_slots_export_to_krunker_as_minus_one :: proc(t: ^testing.T) {
		source := menuui.Settings_Values{fov = menuui.DEFAULT_FOV, sensitivity = 1, mouse_dpi = menuui.DEFAULT_MOUSE_DPI, ads_sensitivity = 1,
			bindings = menuui.default_bindings(), visuals = menuui.DEFAULT_VISUAL_SETTINGS, viewmodel = menuui.DEFAULT_VIEWMODEL_SETTINGS, crosshair = menuui.DEFAULT_CROSSHAIR_SETTINGS}
		source.bindings[.JUMP] = {0, 0}
		source.bindings[.FIRE] = {0, 0} // Krunker's alternate default for shoot1Key is 220, so both slots export.
		source.bindings[.FORWARD] = {0, 0}
		text := menuui.krunker_settings_export(source)
		defer delete(text)
		testing.expect(t, strings.contains(text, `"jumpKey":-1`), "an unbound primary exports as -1")
		testing.expect(t, strings.contains(text, `"shoot1Key":-1`) && strings.contains(text, `"shoot1Key_alt":-1`), "both unbound slots export as -1")
		testing.expect(t, strings.contains(text, `"moveKeys":[-1]`), "an unbound movement key exports as -1")
		testing.expect(t, !strings.contains(text, `"jumpKey_alt"`), "a slot unbound by default is not exported")
		code, ok := menuui.binding_to_krunker_key(0)
		testing.expect(t, ok && code == -1)

		target := source
		target.bindings = menuui.default_bindings()
		_, error := menuui.krunker_settings_import(&target, text)
		testing.expect(t, len(error) == 0 && target.bindings == source.bindings, "-1 imports back as unbound")
	}
}
