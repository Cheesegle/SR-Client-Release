package main

import "core:fmt"
import "core:math/rand"
import menuui "../menu"
import shared "../shared"
import kproto "../krunker"

// Krunker's killfeed (Krunker's client, the chat/feed builder and
// KILL_PLAYER's handler):
//   - #killFeed sits in #topRight (top: 20px, right: 20px, text-align right),
//     newest line at the bottom ("beforeend").
//   - Each line is a .killfeedItem pill: 17px white text, 5px/10px padding,
//     4px radius, rgba(0,0,0,0.2) background, 10px below each line.
//   - Line: killer, mirrored weapon icon (58x28, opacity 0.7), wallbang and
//     headshot icons (28x28), victim. Names are "You" in white for the local
//     player, #9eeb56 for teammates and #eb5656 for everyone else.
//   - A line lives 0xfa0 ms (4 s) and is then removed outright (no fade).
//   - Before adding, the oldest lines are dropped while the feed holds
//     feedLimit (Settings > "Killfeed Limit", 1..10, default 8) lines.
//   - Settings > "Display Kill feed" (showKills, default on) hides it.
//   - No killer: "<victim> committed <random phrase>".
KILL_FEED_LIFE :: 4.0
KILL_FEED_CAPACITY :: menuui.KILL_FEED_MAX_LIMIT
KILL_FEED_NAME_BYTES :: 48
KILL_FEED_TEXT_SIZE :: 17.0
KILL_FEED_ROW_HEIGHT :: 38.0
KILL_FEED_ROW_PITCH :: 48.0
KILL_FEED_BACKGROUND :: shared.Vec4{0, 0, 0, 0.2}
KILL_FEED_MUTED :: shared.Vec4{1, 1, 1, 0.7}
KILL_FEED_YOU_COLOR :: shared.Vec4{1, 1, 1, 1}
// Krunker's teammate and enemy name colours.
KILL_FEED_TEAM_COLOR :: shared.Vec4{0x9e / 255.0, 0xeb / 255.0, 0x56 / 255.0, 1}
KILL_FEED_ENEMY_COLOR :: shared.Vec4{0xeb / 255.0, 0x56 / 255.0, 0x56 / 255.0, 1}
// Krunker's list, picked at random for deaths without a killer.
KILL_FEED_SUICIDE_PHRASES := [?]string{"uninstall life", "toaster bath", "alt f4", "not alive", "neck rope", "scooter ankle", "death.exe", "ctrl w"}

Kill_Feed_Name :: struct {
	bytes: [KILL_FEED_NAME_BYTES]u8,
	length: int,
	color: shared.Vec4,
}

Kill_Feed_Entry :: struct {
	killer, victim: Kill_Feed_Name,
	// false: an environmental death, drawn as "<victim> committed <phrase>".
	has_killer: bool,
	// -1 draws no weapon icon (nukes, streak rewards).
	weapon_id: i32,
	fists, headshot, wallbang: bool,
	phrase: int,
	life: f32,
}

Kill_Feed :: struct {
	entries: [KILL_FEED_CAPACITY]Kill_Feed_Entry,
	count: int,
}

kill_feed_icon_headshot, kill_feed_icon_wallbang, kill_feed_icon_fists: u32

kill_feed_name :: proc(text: string, is_you: bool, team, local_team: i32) -> Kill_Feed_Name {
	name: Kill_Feed_Name
	label := text
	switch {
	case is_you: label, name.color = "You", KILL_FEED_YOU_COLOR
	case local_team > 0 && team == local_team: name.color = KILL_FEED_TEAM_COLOR
	case: name.color = KILL_FEED_ENEMY_COLOR
	}
	// Trim on a UTF-8 boundary so a long name never splits a code point.
	length := min(len(label), KILL_FEED_NAME_BYTES)
	for length > 0 && length < len(label) && label[length] & 0xc0 == 0x80 { length -= 1 }
	name.length = copy(name.bytes[:], label[:length])
	return name
}

kill_feed_name_text :: proc(name: ^Kill_Feed_Name) -> string { return string(name.bytes[:name.length]) }

// Matches the browser: drop the oldest lines until there is room under limit.
kill_feed_push :: proc(feed: ^Kill_Feed, entry: Kill_Feed_Entry, limit: int) {
	limit := clamp(limit, 1, KILL_FEED_CAPACITY)
	for feed.count >= limit { kill_feed_remove(feed, 0) }
	feed.entries[feed.count] = entry
	feed.entries[feed.count].life = KILL_FEED_LIFE
	feed.count += 1
}

kill_feed_remove :: proc(feed: ^Kill_Feed, index: int) {
	if index < 0 || index >= feed.count { return }
	copy(feed.entries[index:feed.count - 1], feed.entries[index + 1:feed.count])
	feed.count -= 1
}

kill_feed_tick :: proc(feed: ^Kill_Feed, delta: f32) {
	for i := 0; i < feed.count; {
		feed.entries[i].life -= delta
		if feed.entries[i].life <= 0 { kill_feed_remove(feed, i) } else { i += 1 }
	}
}

kill_feed_clear :: proc(feed: ^Kill_Feed) { feed^ = {} }

kill_feed_valid_weapon :: proc(client: ^Client, weapon_id: i32) -> i32 {
	if weapon_id < 0 || int(weapon_id) >= len(client.game.weapons) || client.game.weapons[weapon_id] == nil { return -1 }
	return weapon_id
}

kill_feed_equipped_weapon :: proc(player: ^shared.Player) -> i32 {
	if player == nil || player.loadout_index < 0 || int(player.loadout_index) >= len(player.loadout) { return -1 }
	return player.loadout[player.loadout_index]
}

// Native server and local practice: names follow the scoreboard ("You",
// otherwise "Player <uid>").
client_kill_feed_entry_native :: proc(client: ^Client, event: shared.Kill_Event) -> (entry: Kill_Feed_Entry, ok: bool) {
	victim := client_find_player(client, event.victim_uid)
	if victim == nil { return {}, false }
	local_team: i32 = client.me != nil ? client.me.team : 0
	native_name :: proc(player: ^shared.Player, local_team: i32) -> Kill_Feed_Name {
		return kill_feed_name(fmt.tprintf("Player %d", player.uid), player.is_you, player.team, local_team)
	}
	entry.victim = native_name(victim, local_team)
	entry.weapon_id = -1
	if killer := client_find_player(client, event.killer_uid); killer != nil {
		entry.has_killer = true
		if killer != victim { entry.killer = native_name(killer, local_team) }
		entry.weapon_id = kill_feed_valid_weapon(client, event.weapon_id)
		entry.headshot = event.headshot
	}
	return entry, true
}

// Live lobbies: Krunker names and teams from the world state.
client_kill_feed_entry_live :: proc(client: ^Client, kill: ^kproto.Krunker_World_Kill) -> (entry: Kill_Feed_Entry, ok: bool) {
	world := &client.krunker_world
	local_team: i32
	victim_index, killer_index := -1, -1
	for player, i in world.players {
		if player.sid == world.local_sid { local_team = player.team }
		if player.sid == kill.victim_sid { victim_index = i }
		if kill.killer_sid >= 0 && player.sid == kill.killer_sid { killer_index = i }
	}
	if victim_index < 0 { return {}, false }
	live_name :: proc(player: ^kproto.Krunker_World_Player, local_sid, local_team: i32) -> Kill_Feed_Name {
		text := len(player.name) > 0 ? player.name : fmt.tprintf("Player %d", player.sid)
		return kill_feed_name(text, player.sid == local_sid, player.team, local_team)
	}
	victim := &world.players[victim_index]
	entry.victim = live_name(victim, world.local_sid, local_team)
	entry.weapon_id = -1
	if killer_index >= 0 {
		killer := &world.players[killer_index]
		entry.has_killer = true
		if killer_index != victim_index { entry.killer = live_name(killer, world.local_sid, local_team) }
		entry.headshot, entry.wallbang, entry.fists = kill.headshot, kill.wallbang, kill.fists
		// A streak reward shows its streak badge instead of a weapon; without
		// the browser's streak art, show neither. Otherwise the browser uses wId
		// or the killer's equipped weapon.
		if kill.streak < 0 && !kill.fists {
			weapon := kill.weapon_id
			if weapon < 0 { weapon = kill_feed_equipped_weapon(client_find_player(client, kill.killer_sid)) }
			entry.weapon_id = kill_feed_valid_weapon(client, weapon)
		}
	}
	return entry, true
}

kill_feed_add :: proc(client: ^Client, entry: Kill_Feed_Entry) {
	entry := entry
	if !entry.has_killer { entry.phrase = rand.int_max(len(KILL_FEED_SUICIDE_PHRASES)) }
	kill_feed_push(&client.kill_feed, entry, menuui.kill_feed_limit(client.hud_settings))
}

// Drains both kill sources and ages the feed. Runs every frame, also while
// the HUD is hidden, so lines expire on the browser's clock.
client_tick_kill_feed :: proc(client: ^Client, delta: f32) {
	kill_feed_tick(&client.kill_feed, delta)
	kill_chat_tick(delta)
	for event in client.game.kill_events {
		if entry, ok := client_kill_feed_entry_native(client, event); ok {
			kill_feed_add(client, entry)
			kill_chat_add(entry)
			killer := entry.killer
			death_cam_note_kill(client.me != nil && event.victim_uid == client.me.uid, entry.has_killer && event.killer_uid != event.victim_uid, event.killer_uid, kill_feed_name_text(&killer))
		}
	}
	clear(&client.game.kill_events)
	for &kill in client.krunker_world.kills {
		if entry, ok := client_kill_feed_entry_live(client, &kill); ok {
			kill_feed_add(client, entry)
			kill_chat_add(entry)
			killer := entry.killer
			death_cam_note_kill(kill.victim_sid == client.krunker_world.local_sid, entry.has_killer && kill.killer_sid >= 0 && kill.killer_sid != kill.victim_sid, kill.killer_sid, kill_feed_name_text(&killer))
		}
	}
	clear(&client.krunker_world.kills)
}

kill_feed_load_icon :: proc(icon: ^u32, relative: string) -> u32 {
	if icon^ == 0 {
		path := shared.concat(shared.assets_path(), relative)
		icon^ = load_texture(path)
		delete(path)
		overlay_icon_filter(icon^)
	}
	return icon^
}

// Lays out one line right-aligned at `right`. With draw false it only
// measures, so drawing and measuring can never disagree.
kill_feed_entry_layout :: proc(client: ^Client, entry: ^Kill_Feed_Entry, right, top: f32, draw: bool, width_in: f32 = 0, text_points: f32 = KILL_FEED_TEXT_SIZE) -> (width: f32) {
	ui := client.ui
	s := ui.scale
	text_size := text_points * s
	x := right - width_in + 10 * s
	baseline := top + 27 * s
	text :: proc(ui: ^UI, x: ^f32, value: string, color: shared.Vec4, baseline, size: f32, draw: bool) {
		if len(value) == 0 { return }
		if draw { ui_fill_text(ui, color, value, x^, baseline, size) }
		x^ += ui_measure_text(ui, value, size)
	}
	image :: proc(ui: ^UI, x: ^f32, texture: u32, before, w, h, after, top: f32, color: shared.Vec4, mirror, draw: bool) {
		x^ += before
		if draw && texture != 0 { ui_draw_image(ui, texture, x^, top, w, h, color, mirror) }
		x^ += w + after
	}
	if !entry.has_killer {
		text(ui, &x, kill_feed_name_text(&entry.victim), entry.victim.color, baseline, text_size, draw)
		text(ui, &x, fmt.tprintf(" committed %s", KILL_FEED_SUICIDE_PHRASES[entry.phrase]), KILL_FEED_MUTED, baseline, text_size, draw)
	} else {
		text(ui, &x, kill_feed_name_text(&entry.killer), entry.killer.color, baseline, text_size, draw)
		icon: u32
		melee := false
		if entry.fists {
			icon = kill_feed_load_icon(&kill_feed_icon_fists, "textures/weapons/icon_0.png")
		} else if entry.weapon_id >= 0 {
			weapon: ^shared.Weapon
			icon, weapon = overlay_weapon_icon(client, entry.weapon_id)
			melee = weapon != nil && weapon.melee
		}
		if entry.fists || entry.weapon_id >= 0 {
			// .weaponChatIcon / .meleeChatIcon: 58x28, 10px margins, sitting
			// 5px (12px for melee) below the text baseline, mirrored.
			image(ui, &x, icon, 10 * s, 58 * s, 28 * s, 10 * s, baseline - (melee ? 16 : 23) * s, KILL_FEED_MUTED, true, draw)
		} else {
			x += 10 * s
		}
		// .headShotChatIcon: 28x28, -5px left and 8px right margins.
		if entry.wallbang {
			image(ui, &x, kill_feed_load_icon(&kill_feed_icon_wallbang, "img/wallbang_0.png"), -5 * s, 28 * s, 28 * s, 8 * s, baseline - 24 * s, {1, 1, 1, 1}, false, draw)
		}
		if entry.headshot {
			image(ui, &x, kill_feed_load_icon(&kill_feed_icon_headshot, "img/headshot_0.png"), -5 * s, 28 * s, 28 * s, 8 * s, baseline - 24 * s, {1, 1, 1, 1}, false, draw)
		}
		text(ui, &x, kill_feed_name_text(&entry.victim), entry.victim.color, baseline, text_size, draw)
	}
	return x - (right - width_in) + 10 * s
}

kill_feed_render :: proc(client: ^Client) {
	feed := &client.kill_feed
	if client.hud_settings.hide_kill_feed || feed.count == 0 { return }
	s := client.ui.scale
	right, top := client.ui.width - 20 * s, 20 * s
	if g_leaderboard_bottom > 0 { top = g_leaderboard_bottom + 10 * s } // under Krunker's leaderboard
	// Lowering the limit in Settings trims the oldest visible lines at once.
	first := max(0, feed.count - menuui.kill_feed_limit(client.hud_settings))
	for i in first..<feed.count {
		entry := &feed.entries[i]
		width := kill_feed_entry_layout(client, entry, right, top, false)
		ui_round_rect(client.ui, KILL_FEED_BACKGROUND, right - width, top, width, KILL_FEED_ROW_HEIGHT * s, 4 * s)
		kill_feed_entry_layout(client, entry, right, top, true, width)
		top += KILL_FEED_ROW_PITCH * s
	}
}

kill_feed_fini :: proc() {
	texture_release(kill_feed_icon_headshot)
	texture_release(kill_feed_icon_wallbang)
	texture_release(kill_feed_icon_fists)
	kill_feed_icon_headshot, kill_feed_icon_wallbang, kill_feed_icon_fists = 0, 0, 0
}
