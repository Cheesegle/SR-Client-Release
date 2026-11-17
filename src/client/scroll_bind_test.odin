package main

import "core:os"
import "core:testing"
import glfw "vendor:glfw"
import menuui "../menu"
import clay "../third_party/clay"
import shared "../shared"

when ODIN_TEST {
	scroll_test_no_keys :: proc(window: glfw.WindowHandle, code: i32) -> bool { return false }

	scroll_test_measure :: proc "c" (label: clay.StringSlice, config: ^clay.TextElementConfig, user: rawptr) -> clay.Dimensions {
		return {f32(label.length) * 8, 16}
	}

	@(test)
	scroll_bind_label_valid_persist_capture :: proc(t: ^testing.T) {
		scroll := menuui.BINDING_SCROLL
		testing.expect(t, scroll == 20000 && scroll > glfw.KEY_LAST, "Scroll uses Krunker's code, above every GLFW key and away from mouse buttons")
		testing.expect(t, menuui.binding_valid(scroll) && menuui.binding_label(scroll) == "Scroll", "Scroll is a valid, labelled bind")
		testing.expect(t, !menuui.binding_valid(scroll-1) && !menuui.binding_valid(scroll+1), "only the exact Scroll code is accepted")
		testing.expect(t, !client_binding_down(nil, scroll), "Scroll is never read through glfw.GetKey")

		path := "bin/client-settings-scroll-test.json"
		defer os.remove(path)
		settings := client_settings_defaults()
		settings.bindings[.JUMP] = {32, scroll}
		settings.bindings[.MELEE] = {scroll, 0}
		testing.expect(t, client_settings_validate(settings).bindings == settings.bindings, "validation keeps Scroll binds")
		testing.expect(t, client_settings_save(settings, path))
		loaded := client_settings_load(path)
		testing.expect(t, loaded.bindings[.JUMP] == {32, scroll} && loaded.bindings[.MELEE] == {scroll, 0}, "Scroll binds persist in client-settings.json")

		// The GLFW callback turns a notch in either direction into the bind,
		// and the menu does not also scroll behind the listener.
		client := Client{bindings = menuui.default_bindings()}
		client.menu.binding_capture = i32(menuui.Binding_Action.JUMP)*2 + 1 + 1
		client_scroll_event(&client, 0, -1, 1)
		testing.expect(t, client.binding_event == scroll && client.menu_scroll == {} && !client.scroll_press, "scrolling down while capturing assigns Scroll")
		client.binding_event = 0
		client_scroll_event(&client, 0, 2, 1)
		testing.expect(t, client.binding_event == scroll, "scrolling up while capturing assigns Scroll")

		state: menuui.State
		if !testing.expect(t, menuui.init(&state, scroll_test_measure, nil), "menu initialization failed") do return
		defer menuui.fini(&state)
		state.settings_draft.bindings = menuui.default_bindings()
		state.binding_capture = i32(menuui.Binding_Action.JUMP)*2 + 1 + 1
		menuui.interact(&state, {binding_pressed = scroll}, {})
		testing.expect(t, state.binding_capture == 0 && state.settings_draft.bindings[.JUMP] == {32, scroll}, "capture stores Scroll in the alternate slot")
		state.binding_capture = i32(menuui.Binding_Action.JUMP)*2 + 0 + 1
		menuui.interact(&state, {binding_pressed = scroll}, {})
		testing.expect(t, state.settings_draft.bindings[.JUMP] == {scroll, 0}, "capture stores Scroll in the primary slot and clears the duplicate")
	}

	@(test)
	scroll_press_is_throttled_like_krunker :: proc(t: ^testing.T) {
		client := Client{bindings = menuui.default_bindings(), scroll_press_time = -1}
		client.bindings[.JUMP][1] = menuui.BINDING_SCROLL
		// In menus the wheel only scrolls the UI and never reaches gameplay.
		client_scroll_event(&client, 0, -3, 1)
		testing.expect(t, client.menu_scroll == {0, -3} && !client.scroll_press, "unlocked: the wheel scrolls the menu only")
		client.scroll_press = true
		testing.expect(t, !client_action_down(&client, .JUMP, scroll_test_no_keys), "unlocked: a stale press never reads as held")
		client.scroll_press, client.menu_scroll = false, {}

		client.mouse_state.locked = true
		// Five notches within one frame (and 50 ms): Krunker presses key 20000
		// once, as keys[] is a boolean and the listener throttles at 50 ms.
		for i in 0..<5 { client_scroll_event(&client, 0, -1, 2 + f64(i)*0.004) }
		testing.expect(t, client.menu_scroll == {} && client.scroll_press, "locked: a notch presses Scroll and does not scroll the menu")
		bound, sustained := client_gameplay_bound_input(&client, scroll_test_no_keys)
		testing.expect(t, bound.jump && !sustained.jump, "Scroll (alternate slot) drives Jump for one command")
		client_scroll_frame_end(&client, false)
		bound, _ = client_gameplay_bound_input(&client, scroll_test_no_keys)
		testing.expect(t, !bound.jump, "the press is released after the command that read it, without auto-repeat")
		client_scroll_event(&client, 0, -1, 2.04)
		testing.expect(t, !client.scroll_press, "a notch within 50 ms of the last press is ignored")
		client_scroll_event(&client, 0, 1, 2.051)
		testing.expect(t, client.scroll_press, "either direction presses Scroll again after 50 ms")
		client_scroll_frame_end(&client, true)
		testing.expect(t, client.scroll_press, "a pending press survives a frame that built no command")

		// Primary slot and other actions work the same way.
		client.bindings[.JUMP] = {32, 0}
		client.bindings[.CROUCH] = {menuui.BINDING_SCROLL, 0}
		bound, sustained = client_gameplay_bound_input(&client, scroll_test_no_keys)
		testing.expect(t, bound.crouch && !bound.jump && !sustained.crouch, "any action bound to Scroll is pressed")
		space := proc(window: glfw.WindowHandle, code: i32) -> bool { return code == 32 }
		bound, sustained = client_gameplay_bound_input(&client, space)
		testing.expect(t, bound.jump && sustained.jump, "a held key is unaffected by the Scroll release")
	}

	@(test)
	scroll_jump_in_shared_movement :: proc(t: ^testing.T) {
		config := shared.config_load_gameplay()
		defer shared.config_destroy_gameplay(config)
		floor := shared.Object{active = true, collision_type = .BOX, position = {0, -1, 0}, scale = {10000, 1, 10000}}
		map_inst := shared.Map{death_y = -1000, config = {speed = {1, 1, 1}, air_accel = 1}}
		append(&map_inst.objects, &floor)
		defer delete(map_inst.objects)
		game: shared.Game
		shared.game_configure(&game, &config.game, []^shared.Map{&map_inst}, nil, config.weapons, config.classes)
		shared.game_init(&game, 0, 0, false)
		defer shared.game_destroy(&game)
		player := shared.player_init(&game)
		shared.game_players_add(&game, player)
		shared.player_spawn(player, 2)
		player.swap_timer = 0

		client := Client{bindings = menuui.default_bindings(), scroll_press_time = -1}
		client.bindings[.JUMP] = {32, menuui.BINDING_SCROLL}
		client.mouse_state.locked = true
		// One display frame of the native/offline path: one command per frame.
		frame :: proc(client: ^Client, player: ^shared.Player) -> bool {
			bound, _ := client_gameplay_bound_input(client, scroll_test_no_keys)
			input := shared.Input{delta = 0.007, move_dir = bound.move_dir, jump = bound.jump}
			shared.player_proc_input(player, &input, true, false)
			client_scroll_frame_end(client, false)
			return input.jump
		}
		for _ in 0..<30 { frame(&client, player) }
		if !testing.expect(t, player.on_ground && player.velocity.y == 0, "the player settles on the floor") do return

		now := 10.0
		jump_commands, jumps := 0, 0
		for _ in 0..<3 {
			client_scroll_event(&client, 0, -1, now)
			if frame(&client, player) { jump_commands += 1 }
			if player.velocity.y > 0 && !player.on_ground { jumps += 1 }
			for _ in 0..<400 {
				if frame(&client, player) { jump_commands += 1 }
				if player.on_ground { break }
			}
			testing.expect(t, player.on_ground, "the player lands before the next notch")
			// Like Krunker, did_jump clears on the first grounded command
			// without jump, so a notch on the exact landing command is spent.
			frame(&client, player)
			now += 1
		}
		testing.expect(t, jump_commands == 3 && jumps == 3, "each notch is one jump command and one jump in the shared simulation, so scroll bunnyhops repeat")
	}

	@(test)
	scroll_press_spans_live_command_ticks :: proc(t: ^testing.T) {
		config := shared.config_load_gameplay()
		defer shared.config_destroy_gameplay(config)
		floor := shared.Object{active = true, collision_type = .BOX, position = {0, -1, 0}, scale = {10000, 1, 10000}}
		map_inst := shared.Map{death_y = -1000, config = {speed = {1, 1, 1}, air_accel = 1}}
		append(&map_inst.objects, &floor)
		defer delete(map_inst.objects)
		client := Client{scroll_press_time = -1}
		shared.game_configure(&client.game, &config.game, []^shared.Map{&map_inst}, nil, config.weapons, config.classes)
		shared.game_init(&client.game, 0, 0, false)
		defer shared.game_destroy(&client.game)
		defer delete(client.predicted_inputs)
		defer krunker_ws_disconnect(&client.krunker)
		client.me = shared.player_init(&client.game)
		shared.game_players_add(&client.game, client.me)
		shared.player_spawn(client.me, 2)
		client.me.is_you = true
		client.krunker.spawned, client.krunker.bootstrapped = true, true
		client.bindings = menuui.default_bindings()
		client.bindings[.JUMP] = {menuui.BINDING_SCROLL, 0}
		client.mouse_state.locked = true

		// One display frame as client_tick runs it on the live path.
		frame :: proc(client: ^Client, delta: f32) -> []shared.Input {
			before := len(client.krunker.input_commands)
			bound, sustained := client_gameplay_bound_input(client, scroll_test_no_keys)
			input := shared.Input{delta = delta, move_dir = bound.move_dir, jump = bound.jump}
			after := input
			after.jump, after.move_dir = sustained.jump, sustained.move_dir
			client_scroll_frame_end(client, krunker_client_predict_frame(client, &input, after, 1))
			return client.krunker.input_commands[before:]
		}
		count_jumps :: proc(commands: []shared.Input) -> (n: int) {
			for command in commands { if command.jump { n += 1 } }
			return
		}
		for _ in 0..<60 { frame(&client, 1.0/60) }
		if !testing.expect(t, client.me.on_ground, "the player settles on the floor") do return

		// Several 360 Hz commands in one frame: only the first carries the jump.
		client_scroll_event(&client, 0, -1, 5)
		commands := frame(&client, 1.0/60)
		testing.expect(t, len(commands) >= 5 && commands[0].jump && count_jumps(commands) == 1, "a 60 FPS frame's six commands hold Scroll for exactly one")
		testing.expect(t, client.me.velocity.y > 0, "the predicted player jumps")
		for _ in 0..<120 { if count_jumps(frame(&client, 1.0/60)) != 0 { testing.expect(t, false, "no auto-repeat") }; if client.me.on_ground { break } }
		for _ in 0..<5 { frame(&client, 1.0/60) }

		// A frame shorter than one command keeps the press for the next frame.
		client.krunker.input_elapsed = 0
		client_scroll_event(&client, 0, 1, 6)
		testing.expect(t, len(frame(&client, 0.001)) == 0 && client.scroll_press, "no command this frame: the press is kept")
		commands = frame(&client, 1.0/60)
		testing.expect(t, count_jumps(commands) == 1 && commands[0].jump && !client.scroll_press, "the next frame's first command carries it")

		// A fast wheel spin at 144 FPS: Krunker presses at most once per 50 ms,
		// and every press reaches exactly one command.
		for _ in 0..<5 { frame(&client, 1.0/60) }
		now := 8.0
		presses, jumps, consecutive := 0, 0, false
		previous := false
		for _ in 0..<144 {
			was := client.scroll_press
			client_scroll_event(&client, 0, -1, now)
			if client.scroll_press && !was { presses += 1 }
			for command in frame(&client, 1.0/144) {
				if command.jump { jumps += 1; if previous { consecutive = true } }
				previous = command.jump
			}
			now += 1.0/144
		}
		testing.expect(t, presses >= 15 && presses <= 20, "a 144 Hz wheel spin presses about every 50 ms, as Krunker's throttle does")
		testing.expect(t, jumps == presses && !consecutive, "each press is one command: none lost, duplicated or held")
	}
}
