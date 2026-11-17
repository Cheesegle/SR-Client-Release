package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import gl "vendor:OpenGL"
import glfw "vendor:glfw"
import stbi "vendor:stb/image"
import menuui "../menu"
import shared "../shared"
import kproto "../krunker"

when ODIN_TEST {
	@(private = "file")
	feed_entry :: proc(victim: string) -> Kill_Feed_Entry {
		return {has_killer = true, killer = kill_feed_name("Killer", false, 1, 2), victim = kill_feed_name(victim, false, 2, 2), weapon_id = 1}
	}

	@(test)
	kill_feed_caps_at_the_limit_dropping_the_oldest :: proc(t: ^testing.T) {
		feed: Kill_Feed
		for i in 0..<12 { kill_feed_push(&feed, feed_entry(fmt.tprintf("v%d", i)), menuui.KILL_FEED_DEFAULT_LIMIT) }
		testing.expect_value(t, feed.count, 8)
		testing.expect_value(t, kill_feed_name_text(&feed.entries[0].victim), "v4")
		testing.expect_value(t, kill_feed_name_text(&feed.entries[7].victim), "v11")
		// Browser feedLimit is 1..10; anything outside is clamped.
		kill_feed_push(&feed, feed_entry("one"), 1)
		testing.expect_value(t, feed.count, 1)
		for i in 0..<20 { kill_feed_push(&feed, feed_entry("many"), 99) }
		testing.expect_value(t, feed.count, menuui.KILL_FEED_MAX_LIMIT)
		// Settings: zero (missing key) means 8, values clamp to 10.
		testing.expect_value(t, menuui.kill_feed_limit({}), 8)
		testing.expect_value(t, menuui.kill_feed_limit({kill_feed_limit = 3}), 3)
		testing.expect_value(t, menuui.kill_feed_limit({kill_feed_limit = 50}), 10)
	}

	@(test)
	kill_feed_lines_expire_after_four_seconds :: proc(t: ^testing.T) {
		feed: Kill_Feed
		kill_feed_push(&feed, feed_entry("first"), 8)
		kill_feed_tick(&feed, 2)
		kill_feed_push(&feed, feed_entry("second"), 8)
		kill_feed_tick(&feed, 1.9)
		testing.expect_value(t, feed.count, 2)
		kill_feed_tick(&feed, 0.2) // first reaches 4.1 s and is removed outright.
		testing.expect_value(t, feed.count, 1)
		testing.expect_value(t, kill_feed_name_text(&feed.entries[0].victim), "second")
		kill_feed_tick(&feed, 2)
		testing.expect_value(t, feed.count, 0)
	}

	@(test)
	kill_feed_names_use_krunker_colours :: proc(t: ^testing.T) {
		you := kill_feed_name("Me", true, 1, 1)
		testing.expect_value(t, kill_feed_name_text(&you), "You")
		testing.expect(t, you.color == KILL_FEED_YOU_COLOR)
		mate := kill_feed_name("Mate", false, 1, 1)
		testing.expect(t, mate.color == shared.hex_to_vec(0x9eeb56))
		enemy := kill_feed_name("Enemy", false, 2, 1)
		testing.expect(t, enemy.color == shared.hex_to_vec(0xeb5656))
		// FFA: no local team, so everyone else is an enemy.
		ffa := kill_feed_name("Other", false, 0, 0)
		testing.expect(t, ffa.color == KILL_FEED_ENEMY_COLOR)
		long := kill_feed_name(strings.repeat("é", 40, context.temp_allocator), false, 0, 0)
		testing.expect(t, long.length <= KILL_FEED_NAME_BYTES && long.length % 2 == 0, "long names are cut on a UTF-8 boundary")
	}

	@(test)
	kill_feed_native_kills_come_from_the_simulation :: proc(t: ^testing.T) {
		mode := shared.Game_Mode{}
		client := Client{}
		client.game.mode = &mode
		client.game.weapons = shared.g_weapons()
		client.game.is_local = true
		defer { delete(client.game.players); delete(client.game.kill_events) }
		me := new(shared.Player); defer free(me)
		bot := new(shared.Player); defer free(bot)
		me^ = {uid = 1, is_you = true, active = true, health = 100, game = &client.game, team = 0}
		bot^ = {uid = 2, active = true, health = 100, game = &client.game, team = 0}
		append(&client.game.players, me, bot)
		client.me = me
		testing.expect(t, shared.player_apply_damage(bot, me, 150, 0, true))
		testing.expect_value(t, len(client.game.kill_events), 1)
		event := client.game.kill_events[0]
		testing.expect(t, event.victim_uid == 2 && event.killer_uid == 1 && event.weapon_id == 0 && event.headshot)

		// Native server -> client wire format.
		buf: [shared.PACKET_HEADER_SIZE + shared.PACKET_KILL_FEED_PAYLOAD_SIZE]byte
		size := shared.packet_serialize_kill_feed(buf[:], &event)
		decoded, ok := shared.packet_deserialize_kill_feed(buf[:size])
		testing.expect(t, ok && decoded == event)
		bad := event; bad.weapon_id = 17 // A nil slot is rejected.
		size = shared.packet_serialize_kill_feed(buf[:], &bad)
		_, ok = shared.packet_deserialize_kill_feed(buf[:size])
		testing.expect(t, !ok)

		client_tick_kill_feed(&client, 0)
		testing.expect_value(t, len(client.game.kill_events), 0)
		testing.expect_value(t, client.kill_feed.count, 1)
		entry := client.kill_feed.entries[0]
		testing.expect_value(t, kill_feed_name_text(&entry.killer), "You")
		testing.expect_value(t, kill_feed_name_text(&entry.victim), "Player 2")
		testing.expect(t, entry.has_killer && entry.headshot && entry.weapon_id == 0)

		// Falling out of the map has no killer: "<victim> committed ...".
		me.active = true
		shared.player_kill(me, nil, nil, false)
		client_tick_kill_feed(&client, 0)
		testing.expect_value(t, client.kill_feed.count, 2)
		testing.expect(t, !client.kill_feed.entries[1].has_killer)
		testing.expect_value(t, kill_feed_name_text(&client.kill_feed.entries[1].victim), "You")

		// Hidden or not, lines keep ageing.
		client.hud_settings.hide_kill_feed = true
		client_tick_kill_feed(&client, KILL_FEED_LIFE + 0.1)
		testing.expect_value(t, client.kill_feed.count, 0)
	}

	@(test)
	kill_feed_live_kill_player_packet :: proc(t: ^testing.T) {
		client := Client{}
		client.game.weapons = shared.g_weapons()
		world := &client.krunker_world
		world^ = {local_sid = 5}
		defer kproto.krunker_world_reset(world)
		append(&world.players,
			kproto.Krunker_World_Player{sid = 5, name = strings.clone("Local"), team = 1, active = true},
			kproto.Krunker_World_Player{sid = 6, name = strings.clone("Ally"), team = 1, active = true},
			kproto.Krunker_World_Player{sid = 7, name = strings.clone("Foe"), team = 2, active = true},
		)
		// The killer's equipped weapon is used when the info has no wId.
		foe := new(shared.Player); defer free(foe)
		loadout := [2]i32{0, 12}
		foe^ = {uid = 7, loadout = loadout[:], loadout_size = 2, loadout_index = 1}
		append(&client.game.players, foe)
		defer delete(client.game.players)

		info := []kproto.Krunker_Msgpack_Map_Entry{{key = "wId", value = i64(1)}, {key = "hs", value = true}}
		packet := []kproto.Krunker_Msgpack_Value{"3", i64(6), i64(3), i64(5), kproto.Krunker_Msgpack_Nil{}, info}
		testing.expect(t, kproto.krunker_world_apply_packet(world, packet))
		testing.expect_value(t, len(world.kills), 1)
		packet = []kproto.Krunker_Msgpack_Value{"3", i64(5), i64(1), i64(7), kproto.Krunker_Msgpack_Nil{}, []kproto.Krunker_Msgpack_Map_Entry{{key = "wb", value = i64(1)}}}
		testing.expect(t, kproto.krunker_world_apply_packet(world, packet))
		// Killer null: an environmental death.
		packet = []kproto.Krunker_Msgpack_Value{"3", i64(7), i64(1), kproto.Krunker_Msgpack_Nil{}}
		testing.expect(t, kproto.krunker_world_apply_packet(world, packet))
		// The last argument suppresses the feed line.
		packet = []kproto.Krunker_Msgpack_Value{"3", i64(6), i64(4), i64(7), kproto.Krunker_Msgpack_Nil{}, kproto.Krunker_Msgpack_Nil{}, true}
		testing.expect(t, kproto.krunker_world_apply_packet(world, packet))
		testing.expect_value(t, len(world.kills), 3)

		client_tick_kill_feed(&client, 0)
		testing.expect_value(t, len(world.kills), 0)
		testing.expect_value(t, client.kill_feed.count, 3)
		first := &client.kill_feed.entries[0]
		testing.expect_value(t, kill_feed_name_text(&first.killer), "You")
		testing.expect_value(t, kill_feed_name_text(&first.victim), "Ally")
		testing.expect(t, first.victim.color == KILL_FEED_TEAM_COLOR && first.headshot && first.weapon_id == 1)
		second := &client.kill_feed.entries[1]
		testing.expect_value(t, kill_feed_name_text(&second.killer), "Foe")
		testing.expect(t, second.killer.color == KILL_FEED_ENEMY_COLOR && second.victim.color == KILL_FEED_YOU_COLOR)
		testing.expect(t, second.wallbang && !second.headshot && second.weapon_id == 12, "equipped knife fallback")
		third := &client.kill_feed.entries[2]
		testing.expect(t, !third.has_killer)
		testing.expect_value(t, kill_feed_name_text(&third.victim), "Foe")
	}

	@(test)
	kill_feed_settings_stage_save_and_import :: proc(t: ^testing.T) {
		client := Client{}
		view := menuui.View{}
		client.menu.page = .SETTINGS
		menuui.prepare_settings(&client.menu, view)
		testing.expect_value(t, menuui.settings_slider_value(&client.menu, view, {kind = .KILL_FEED_LIMIT}), 8)
		menuui.activate(&client.menu, {action = {kind = .HUD_TOGGLE, index = 6}})
		menuui.activate(&client.menu, {action = {kind = .KILL_FEED_LIMIT, value = 4.2}})
		testing.expect(t, client.menu.settings_draft.hud.hide_kill_feed && client.menu.settings_draft.hud.kill_feed_limit == 4)
		menuui.activate(&client.menu, {action = {kind = .KILL_FEED_LIMIT, value = 40}})
		testing.expect_value(t, client.menu.settings_draft.hud.kill_feed_limit, 10)
		menu_apply_action(&client, {kind = .SETTINGS_SAVE})
		testing.expect(t, client.hud_settings.hide_kill_feed && client.hud_settings.kill_feed_limit == 10, "Save must commit the killfeed settings")

		// Krunker Export/Import: showKills and feedLimit.
		values: menuui.Settings_Values
		values.hud = {hide_kill_feed = true, kill_feed_limit = 3}
		text := menuui.krunker_settings_export(values, context.temp_allocator)
		testing.expectf(t, strings.contains(text, `"showKills":false`) && strings.contains(text, `"feedLimit":3`), "export: %s", text)
		imported: menuui.Settings_Values
		_, err := menuui.krunker_settings_import(&imported, `{"showKills":false,"feedLimit":5}`)
		testing.expect(t, len(err) == 0 && imported.hud.hide_kill_feed && imported.hud.kill_feed_limit == 5)
		_, err = menuui.krunker_settings_import(&imported, `{}`)
		testing.expect(t, len(err) == 0 && !imported.hud.hide_kill_feed && menuui.kill_feed_limit(imported.hud) == 8, "missing keys reset to Krunker's defaults")
	}

	@(private = "file")
	feed_frame :: proc(client: ^Client, pixels: []u8) {
		ui_flush()
		gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
		ui_update(client.ui, f32(client.viewport_width), f32(client.viewport_height))
		kill_feed_render(client)
		gl.PixelStorei(gl.PACK_ALIGNMENT, 1)
		ui_flush()
		gl.ReadPixels(0, 0, client.viewport_width, client.viewport_height, gl.RGB, gl.UNSIGNED_BYTE, raw_data(pixels))
	}

	// Changed pixels and the lowest changed row (top-down), in UI units.
	@(private = "file")
	feed_changes :: proc(client: ^Client, before, after: []u8) -> (inside, outside: int, bottom, left: f32) {
		w, h := int(client.viewport_width), int(client.viewport_height)
		left = f32(w)
		for y in 0..<h {
			for x in 0..<w {
				o := ((h-1-y)*w + x)*3
				if before[o] == after[o] && before[o+1] == after[o+1] && before[o+2] == after[o+2] { continue }
				if f32(x) > f32(w)*0.5 && f32(y) < f32(h)*0.6 { inside += 1 } else { outside += 1 }
				bottom = max(bottom, f32(y)/client.ui.scale)
				left = min(left, f32(x)/client.ui.scale)
			}
		}
		return
	}

	@(test)
	kill_feed_renders_top_right :: proc(t: ^testing.T) {
		logger := context.logger
		context = runtime.default_context()
		context.logger = logger
		if !testing.expect(t, bool(glfw.Init())) { return }
		defer glfw.Terminate()
		glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)
		glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 5)
		window := glfw.CreateWindow(1280, 720, "Killfeed", nil, nil)
		if !testing.expect(t, window != nil) { return }
		defer glfw.DestroyWindow(window)
		glfw.MakeContextCurrent(window)
		gl.load_up_to(4, 5, glfw.gl_set_proc_address)
		gl.Enable(gl.BLEND)
		gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
		gl.ClearColor(0.42, 0.55, 0.62, 1)
		framebuffer, color_texture: u32
		gl.GenFramebuffers(1, &framebuffer)
		gl.GenTextures(1, &color_texture)
		defer gl.DeleteFramebuffers(1, &framebuffer)
		defer gl.DeleteTextures(1, &color_texture)
		gl.BindFramebuffer(gl.FRAMEBUFFER, framebuffer)
		client := Client{ui = ui_init()}
		defer { overlay_fini(); ui_fini(client.ui); resource_cache_fini() }
		client.game.weapons = shared.g_weapons()

		// Several Krunker-style lines: team kill with headshot, an enemy knife
		// kill on you, a wallbang, a rocket self-kill and a fall.
		entries := [?]Kill_Feed_Entry{
			{has_killer = true, killer = kill_feed_name("Me", true, 1, 1), victim = kill_feed_name("Sidney", false, 2, 1), weapon_id = 1, headshot = true},
			{has_killer = true, killer = kill_feed_name("Ash_Ketchum", false, 2, 1), victim = kill_feed_name("Me", true, 1, 1), weapon_id = 12},
			{has_killer = true, killer = kill_feed_name("Teammate", false, 1, 1), victim = kill_feed_name("Hunter", false, 2, 1), weapon_id = 0, wallbang = true, headshot = true},
			{has_killer = true, victim = kill_feed_name("Rocketeer", false, 2, 1), weapon_id = 8},
			{has_killer = false, victim = kill_feed_name("Faller", false, 1, 1), phrase = 2},
		}
		for size in ([?][2]i32{{1280, 720}, {1920, 1080}}) {
			gl.BindTexture(gl.TEXTURE_2D, color_texture)
			gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGB8, size[0], size[1], 0, gl.RGB, gl.UNSIGNED_BYTE, nil)
			gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, color_texture, 0)
			if !testing.expect(t, gl.CheckFramebufferStatus(gl.FRAMEBUFFER) == gl.FRAMEBUFFER_COMPLETE) { return }
			gl.BindTexture(gl.TEXTURE_2D, 0)
			g_active_texture = 0
			client.viewport_width, client.viewport_height = size[0], size[1]
			gl.Viewport(0, 0, size[0], size[1])
			empty := make([]u8, int(size[0]*size[1]*3)); defer delete(empty)
			full := make([]u8, len(empty)); defer delete(full)
			scratch := make([]u8, len(empty)); defer delete(scratch)

			kill_feed_clear(&client.kill_feed)
			client.hud_settings = {}
			feed_frame(&client, empty)
			for entry in entries { kill_feed_push(&client.kill_feed, entry, menuui.kill_feed_limit(client.hud_settings)) }
			feed_frame(&client, full)
			inside, outside, bottom, _ := feed_changes(&client, empty, full)
			testing.expectf(t, inside > 0 && outside == 0, "the feed draws only in the top-right (inside=%d outside=%d)", inside, outside)
			// Five 38 px lines on a 48 px pitch below the 20 px inset.
			testing.expectf(t, bottom > 20 + 4*48 && bottom < 20 + 5*48, "five lines end near %v px (got %v)", 20 + 4*48 + 38, bottom)

			// Icons: the AK, knife, headshot and wallbang textures all load.
			ak, _ := overlay_weapon_icon(&client, 1)
			knife, _ := overlay_weapon_icon(&client, 12)
			testing.expect(t, ak != 0 && knife != 0 && kill_feed_icon_headshot != 0 && kill_feed_icon_wallbang != 0, "killfeed icons must load from assets")

			// Settings > Killfeed limit 3 keeps the newest three lines.
			client.hud_settings.kill_feed_limit = 3
			feed_frame(&client, scratch)
			_, _, bottom, _ = feed_changes(&client, empty, scratch)
			testing.expectf(t, bottom > 20 + 2*48 && bottom < 20 + 3*48, "a limit of 3 shows three lines (bottom %v)", bottom)
			client.hud_settings.kill_feed_limit = 0

			// Settings > Show killfeed off.
			client.hud_settings.hide_kill_feed = true
			feed_frame(&client, scratch)
			inside, outside, _, _ = feed_changes(&client, empty, scratch)
			testing.expect(t, inside == 0 && outside == 0, "a hidden feed draws nothing")
			client.hud_settings.hide_kill_feed = false

			// After 4 s every line is gone.
			kill_feed_tick(&client.kill_feed, KILL_FEED_LIFE)
			feed_frame(&client, scratch)
			inside, outside, _, _ = feed_changes(&client, empty, scratch)
			testing.expect(t, inside == 0 && outside == 0 && client.kill_feed.count == 0, "expired lines are removed")

			when #config(HUD_PREVIEW, false) {
				os.make_directory("bin/killfeed")
				w, h := int(size[0]), int(size[1])
				stbi.write_png(fmt.ctprintf("bin/killfeed/killfeed-%dx%d.png", w, h), i32(w), i32(h), 3, &full[(h-1)*w*3], i32(-w*3))
			}
		}
		testing.expect(t, gl.GetError() == gl.NO_ERROR)
	}
}
