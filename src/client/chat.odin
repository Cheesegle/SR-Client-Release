package main

import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
import glfw "vendor:glfw"
import shared "../shared"
import kproto "../krunker"

// Krunker's in-game chat (bottom left, together with the kill lines).
//
// Receive: "ch" ADD_CHAT [channel, name, text, kind, color, nameColor,
// accountId, extra]; channel 1 is the team channel, -1/0 everyone. kind 0 is a
// player line, 2 a server line in `color`, 1/4 game lines, 3 a trade request
// (ignored). The text arrives HTML-escaped.
// Send: "ct" CHAT_MESSAGE [channel, text], channel 1 = team, 0 = everyone.
// The server closes the connection after more than 3 lines in 1 s and drops a
// line sent within 0.8 s of the previous one, so sends are spaced here.
//
// Keys, as in Krunker: the Chat bind (Enter, T) opens the box, Enter sends,
// Escape closes, Tab switches Team / All. A comp match starts on Team.

CHAT_STORED :: 40       // lines kept
CHAT_SHOWN :: 7         // lines drawn while not typing
CHAT_SHOWN_TYPING :: 12 // lines drawn while typing
CHAT_KILL_LIFE :: 45.0    // Krunker keeps its chat box; old lines go after a while
CHAT_MESSAGE_LIFE :: 60.0
CHAT_MAX_RUNES :: 70
CHAT_TEXT_BYTES :: 4*CHAT_MAX_RUNES + 64
CHAT_NAME_BYTES :: 64
CHAT_SEND_SPACING :: 0.85

Chat_Line_Kind :: enum u8 { KILL, PLAYER, SYSTEM }

Chat_Line :: struct {
	kind: Chat_Line_Kind,
	channel: i8, // -1 every channel, 0 all, 1 team
	killer, victim: Kill_Feed_Name, // KILL
	has_killer: bool,
	entry: Kill_Feed_Entry, // KILL: drawn like Krunker's chat (weapon, headshot icons)
	name: [CHAT_NAME_BYTES]u8, name_length: int,
	name_color: shared.Vec4,
	text: [CHAT_TEXT_BYTES]u8, text_length: int,
	text_color: shared.Vec4,
	life: f32,
}

Chat :: struct {
	lines: [CHAT_STORED]Chat_Line,
	count: int,
	typing: bool,
	ignore_chars: bool, // the key that opened the box also sends a character
	escape_hold: bool,  // Escape closed the box: do not also open the menu
	channel: i32,       // 0 all, 1 team
	input: [CHAT_TEXT_BYTES]u8,
	input_length: int,
	last_sent: f64,
	channel_set_for: u64, // match identity the comp default was applied to
	serial: u64,          // +1 per new line (the HUD redraws when it changes)
}

g_chat: Chat

chat_typing :: proc() -> bool { return g_chat.typing }

@(private = "file")
chat_push :: proc(line: Chat_Line) {
	chat := &g_chat
	if chat.count == CHAT_STORED {
		copy(chat.lines[:], chat.lines[1:])
		chat.count -= 1
	}
	chat.lines[chat.count] = line
	chat.count += 1
	chat.serial += 1
}

@(private = "file")
chat_copy :: proc(dst: []u8, text: string) -> int {
	n := min(len(dst), len(text))
	// Never cut a UTF-8 sequence in half.
	for n > 0 && n < len(text) && (text[n] & 0xC0) == 0x80 { n -= 1 }
	copy(dst, text[:n])
	return n
}

kill_chat_add :: proc(entry: Kill_Feed_Entry) {
	chat_push({kind = .KILL, channel = -1, killer = entry.killer, victim = entry.victim, has_killer = entry.has_killer && entry.killer.length > 0, entry = entry, life = CHAT_KILL_LIFE})
}

kill_chat_tick :: proc(delta: f32) {
	chat := &g_chat
	for i in 0..<chat.count { chat.lines[i].life -= delta }
}

kill_chat_clear :: proc() {
	channel := g_chat.channel
	g_chat = {}
	g_chat.channel = channel
}

// ------------------------------------------------------------- receiving

// "&amp;" etc. back to text, and any markup removed.
chat_unescape :: proc(text: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(0, len(text), allocator)
	i := 0
	for i < len(text) {
		c := text[i]
		if c == '<' {
			if end := strings.index_byte(text[i:], '>'); end > 0 { i += end + 1; continue }
		}
		if c == '&' {
			if end := strings.index_byte(text[i:], ';'); end > 1 && end <= 10 {
				entity := text[i+1:i+end]
				replacement := ""
				switch entity {
				case "amp": replacement = "&"
				case "lt": replacement = "<"
				case "gt": replacement = ">"
				case "quot": replacement = "\""
				case "apos": replacement = "'"
				case "nbsp": replacement = " "
				case:
					if len(entity) > 1 && entity[0] == '#' {
						value: int; ok: bool
						if entity[1] == 'x' || entity[1] == 'X' { value, ok = strconv.parse_int(entity[2:], 16) }
						else { value, ok = strconv.parse_int(entity[1:], 10) }
						if ok && value > 0 && value < 0x110000 {
							bytes, n := utf8.encode_rune(rune(value))
							strings.write_bytes(&b, bytes[:n])
							i += end + 1
							continue
						}
					}
				}
				if len(replacement) > 0 { strings.write_string(&b, replacement); i += end + 1; continue }
			}
		}
		if c < 0x20 { strings.write_byte(&b, ' ') } else { strings.write_byte(&b, c) }
		i += 1
	}
	return strings.to_string(b)
}

// "#rgb" / "#rrggbb" -> color.
chat_parse_color :: proc(text: string, fallback: shared.Vec4) -> shared.Vec4 {
	value := strings.trim_space(text)
	if strings.has_prefix(value, "#") { value = value[1:] }
	if len(value) == 3 {
		expanded := [6]u8{value[0], value[0], value[1], value[1], value[2], value[2]}
		value = strings.clone(string(expanded[:]), context.temp_allocator)
	}
	if len(value) != 6 { return fallback }
	rgb, ok := strconv.parse_int(value, 16)
	if !ok { return fallback }
	return {f32((rgb >> 16) & 255)/255, f32((rgb >> 8) & 255)/255, f32(rgb & 255)/255, 1}
}

@(private = "file")
chat_value_string :: proc(packet: []kproto.Krunker_Msgpack_Value, index: int) -> string {
	if index < len(packet) { if text, ok := packet[index].(string); ok { return text } }
	return ""
}

@(private = "file")
chat_value_int :: proc(packet: []kproto.Krunker_Msgpack_Value, index: int, fallback: i64) -> i64 {
	if index >= len(packet) { return fallback }
	#partial switch v in packet[index] {
	case i64: return v
	case f64: return i64(v)
	case bool: return v ? 1 : 0
	}
	return fallback
}

chat_sender_color :: proc(client: ^Client, name: string, team_channel: bool) -> shared.Vec4 {
	world := &client.krunker_world
	local_team: i32
	for player in world.players { if player.sid == world.local_sid { local_team = player.team } }
	for player in world.players {
		if len(player.name) == 0 || !(name == player.name || strings.has_prefix(name, player.name) || strings.has_suffix(name, player.name)) { continue }
		if player.sid == world.local_sid { return KILL_FEED_YOU_COLOR }
		if local_team > 0 && player.team == local_team { return KILL_FEED_TEAM_COLOR }
		return KILL_FEED_ENEMY_COLOR
	}
	return team_channel ? KILL_FEED_TEAM_COLOR : shared.Vec4{1, 1, 1, 0.9}
}

CHAT_SERVER_COLOR :: shared.Vec4{0xfc/255.0, 0x03/255.0, 0xec/255.0, 1}
CHAT_TEXT_COLOR :: shared.Vec4{1, 1, 1, 0.7} // .chatMsg
CHAT_GAME_COLOR :: shared.Vec4{1, 1, 1, 0.7}

// packet = ["ch", channel, name, text, kind, color, nameColor, ...]
chat_receive :: proc(client: ^Client, packet: []kproto.Krunker_Msgpack_Value) {
	if len(packet) < 4 { return }
	kind := chat_value_int(packet, 4, 0)
	if kind == 3 { return } // trade request
	text := chat_unescape(chat_value_string(packet, 3))
	if len(strings.trim_space(text)) == 0 { return }
	channel := chat_value_int(packet, 1, 0)
	line: Chat_Line
	line.channel = channel == 1 ? 1 : (channel < 0 ? -1 : 0)
	line.life = CHAT_MESSAGE_LIFE
	line.text_length = chat_copy(line.text[:], text)
	switch kind {
	case 0:
		line.kind = .PLAYER
		name := chat_unescape(chat_value_string(packet, 2))
		line.name_length = chat_copy(line.name[:], name)
		// Like Krunker's chat: you white, your team green, the enemy red.
		line.name_color = chat_sender_color(client, name, line.channel == 1)
		line.text_color = CHAT_TEXT_COLOR
	case 2:
		line.kind = .SYSTEM
		line.text_color = chat_parse_color(chat_value_string(packet, 5), CHAT_SERVER_COLOR)
	case:
		line.kind = .SYSTEM
		line.text_color = CHAT_GAME_COLOR
	}
	chat_push(line)
}

// ------------------------------------------------------------- channel

@(private = "file")
chat_team_mode :: proc(client: ^Client) -> bool {
	return client.game.mode != nil && client.game.mode.config.teams
}

// Like Krunker's round INIT: outside team modes the channel is All, and a
// comp match starts on Team. Runs every frame; cheap.
chat_channel_tick :: proc(client: ^Client) {
	chat := &g_chat
	chat.ignore_chars = false // characters from the key that opened the box are past
	if !client.krunker.connected { chat.channel_set_for = 0; return }
	if !chat_team_mode(client) { chat.channel = 0; return }
	identity := u64(client.krunker_world.map_index+1) << 32 | u64(u32(client.krunker_world.mode_index+1))
	if client.krunker_world.is_comp && chat.channel_set_for != identity {
		chat.channel_set_for = identity
		chat.channel = 1
	}
}

// ------------------------------------------------------------- typing

chat_can_open :: proc(client: ^Client) -> bool {
	online := client.krunker.connected && client.krunker.ready_received
	return (online || client.local_practice) && client.mouse_state.locked && !client.hud_settings.hide_chat
}

chat_open :: proc() {
	g_chat.typing = true
	g_chat.ignore_chars = true
	g_chat.input_length = 0
}

chat_close :: proc() {
	g_chat.typing = false
	g_chat.input_length = 0
}

// Called from the GLFW key callback. Returns true when chat used the key.
chat_key :: proc(client: ^Client, key, action: i32) -> bool {
	chat := &g_chat
	if action != glfw.PRESS && action != glfw.REPEAT { return chat.typing }
	if !chat.typing {
		if action != glfw.PRESS || !chat_can_open(client) { return false }
		for code in client.bindings[.CHAT] {
			if code > 0 && code == key { chat_open(); return true }
		}
		return false
	}
	if !client.mouse_state.locked { chat_close(); return false }
	switch key {
	case glfw.KEY_ESCAPE:
		chat_close()
		chat.escape_hold = true
	case glfw.KEY_ENTER, glfw.KEY_KP_ENTER:
		if action == glfw.PRESS { chat_submit(client) }
	case glfw.KEY_TAB:
		if action == glfw.PRESS && chat_team_mode(client) { chat.channel = chat.channel == 1 ? 0 : 1 }
	case glfw.KEY_BACKSPACE:
		n := chat.input_length
		if n > 0 {
			n -= 1
			for n > 0 && (chat.input[n] & 0xC0) == 0x80 { n -= 1 }
			chat.input_length = n
		}
	}
	return true
}

// Called from the GLFW character callback while typing.
chat_character :: proc(codepoint: rune) {
	chat := &g_chat
	if !chat.typing || chat.ignore_chars || codepoint < 32 || codepoint == 0x7f { return }
	if utf8.rune_count(string(chat.input[:chat.input_length])) >= CHAT_MAX_RUNES { return }
	bytes, n := utf8.encode_rune(codepoint)
	if chat.input_length + n > len(chat.input) { return }
	copy(chat.input[chat.input_length:], bytes[:n])
	chat.input_length += n
}

// Escape that closed the chat must not open the menu; cleared once released.
chat_escape_blocked :: proc(client: ^Client) -> bool {
	if g_chat.escape_hold && glfw.GetKey(client.window, glfw.KEY_ESCAPE) != glfw.PRESS { g_chat.escape_hold = false }
	return g_chat.typing || g_chat.escape_hold
}

chat_submit :: proc(client: ^Client) {
	chat := &g_chat
	text := strings.trim_space(string(chat.input[:chat.input_length]))
	if len(text) == 0 { chat_close(); return }
	now := glfw.GetTime()
	if !client.krunker.connected {
		// Local practice: no server, so the line is only shown here.
		line := Chat_Line{kind = .PLAYER, channel = -1, life = CHAT_MESSAGE_LIFE, name_color = {1, 1, 1, 0.85}, text_color = CHAT_TEXT_COLOR}
		line.name_length = chat_copy(line.name[:], "You")
		line.text_length = chat_copy(line.text[:], text)
		chat_push(line)
		chat_close()
		return
	}
	if now - chat.last_sent < CHAT_SEND_SPACING { return } // keep the line; Enter again in a moment
	if krunker_ws_send_chat(&client.krunker, chat.channel, text) {
		chat.last_sent = now
		chat_close()
	}
}

// ------------------------------------------------------------- drawing

@(private = "file")
chat_visible :: proc(line: ^Chat_Line, channel: i32, typing: bool) -> bool {
	if line.channel >= 0 && line.kind == .PLAYER && i32(line.channel) != channel { return false }
	return typing || line.life > 0
}

// Krunker's chat box (#chatHolder in game: left 15, bottom 130, 413 wide):
// #chatList (black .4, rounded top) with the chat and kill lines, newest at
// the bottom, each .chatItem 14px with 10px margins above and below and 12px
// on the left; the input row under it while typing.
CHAT_BOX_WIDTH :: 413.0
CHAT_TEXT_PX :: 14.0

@(private = "file")
Chat_Row :: struct { line: ^Chat_Line, text: string, first: bool }

// Splits a chat line into rows that fit the box (Krunker wraps long lines).
@(private = "file")
chat_wrap :: proc(ui: ^UI, line: ^Chat_Line, prefix_w, width, size: f32, rows: ^[dynamic]Chat_Row) {
	text := string(line.text[:line.text_length])
	first := true
	for len(text) > 0 {
		room := width - (first ? prefix_w : 0)
		end := len(text)
		if ui_measure_text(ui, text, size) > room {
			// Longest prefix that fits, broken at a space when possible.
			fit := 0
			for i := 1; i <= len(text); i += 1 {
				if i < len(text) && (text[i] & 0xC0) == 0x80 { continue }
				if ui_measure_text(ui, text[:i], size) > room { break }
				fit = i
			}
			if fit == 0 { fit = 1; for fit < len(text) && (text[fit] & 0xC0) == 0x80 { fit += 1 } }
			end = fit
			if space := strings.last_index_byte(text[:fit], ' '); space > 0 && fit < len(text) { end = space + 1 }
		}
		append(rows, Chat_Row{line = line, text = text[:end], first = first})
		text = text[end:]
		first = false
	}
	if first { append(rows, Chat_Row{line = line, first = true}) }
}

kill_chat_render :: proc(client: ^Client) {
	chat := &g_chat
	if client.hud_settings.hide_chat { if chat.typing { chat_close() }; return }
	typing := chat.typing && client.mouse_state.locked
	ui := client.ui
	s := ui.scale
	size := CHAT_TEXT_PX*KH_EM*s
	line_h := CHAT_TEXT_PX*KH_LINE*s
	kill_h := 28*s // the 28px weapon icon on the line, 5px under the baseline
	x := 15*s
	width := min(CHAT_BOX_WIDTH*s, ui.width*0.4)
	inner := width - 24*s
	bottom := ui.height - 130*s
	team_mode := chat_team_mode(client)

	rows := make([dynamic]Chat_Row, 0, 16, context.temp_allocator)
	limit := typing ? CHAT_SHOWN_TYPING : CHAT_SHOWN
	for i in 0..<chat.count {
		line := &chat.lines[i]
		if !chat_visible(line, chat.channel, typing) { continue }
		if line.kind == .KILL && client.hud_settings.hide_kill_feed { continue }
		switch line.kind {
		case .KILL: append(&rows, Chat_Row{line = line, first = true})
		case .PLAYER:
			prefix := strings.concatenate({string(line.name[:line.name_length]), ": "}, context.temp_allocator)
			chat_wrap(ui, line, ui_measure_text(ui, prefix, size), inner, size, &rows)
		case .SYSTEM: chat_wrap(ui, line, 0, inner, size, &rows)
		}
	}
	shown_rows := rows[max(0, len(rows)-limit):]
	if len(shown_rows) == 0 && !typing { return }
	// Each item: 10px margin, its lines, 10px margin.
	row_height :: proc(rows: []Chat_Row, i: int, line_h, kill_h, s: f32) -> f32 {
		h := rows[i].line.kind == .KILL ? kill_h : line_h
		if rows[i].first { h += 10*s }
		if i+1 >= len(rows) || rows[i+1].first { h += 10*s }
		return h
	}
	list_h: f32 = 0
	for i in 0..<len(shown_rows) { list_h += row_height(shown_rows, i, line_h, kill_h, s) }
	input_h := typing ? (8 + 12 + CHAT_TEXT_PX*KH_LINE)*s : 0
	top := bottom - input_h - list_h
	if len(shown_rows) > 0 {
		// border-radius: 5px 5px 0 0
		ui_round_rect_top(ui, shared.Vec4{0, 0, 0, 0.4}, x, top, width, list_h, 5*s)
	}
	y := top
	for &row, i in shown_rows {
		line := row.line
		if row.first { y += 10*s }
		cursor := x + 12*s
		switch line.kind {
		case .KILL:
			entry := line.entry
			text_points: f32 = CHAT_TEXT_PX*KH_EM
			measured := kill_feed_entry_layout(client, &entry, 0, 0, false, 0, text_points)
			// Right-aligned at `right` with a 10px inset and its baseline 27px
			// below `top`; the line's baseline is 23px into its 28px box.
			kill_feed_entry_layout(client, &entry, cursor - 10*s + measured, y + (23 - 27)*s, true, measured, text_points)
			y += kill_h
		case .PLAYER:
			baseline := y + CHAT_TEXT_PX*KH_ASCENT*s
			if row.first {
				label := strings.concatenate({string(line.name[:line.name_length]), ": "}, context.temp_allocator)
				ui_fill_text(ui, line.name_color, label, cursor, baseline, size)
				cursor += ui_measure_text(ui, label, size)
			}
			ui_fill_text(ui, line.text_color, row.text, cursor, baseline, size)
			y += line_h
		case .SYSTEM:
			ui_fill_text(ui, line.text_color, row.text, cursor, y + CHAT_TEXT_PX*KH_ASCENT*s, size)
			y += line_h
		}
		if i+1 >= len(shown_rows) || shown_rows[i+1].first { y += 10*s }
	}
	if typing {
		// #chatInputHolder (black, radius 4) with #chatInput (black .4, 14px,
		// padding 6 10) and the channel.
		white := shared.Vec4{1, 1, 1, 1}
		holder := bottom - input_h
		ui_round_rect(ui, KH_BLACK, x, holder, width, input_h, 4*s)
		label := chat.channel == 1 && team_mode ? "Team" : "All"
		label_color := chat.channel == 1 && team_mode ? KILL_FEED_TEAM_COLOR : shared.Vec4{1, 1, 1, 0.8}
		label_w := ui_measure_text(ui, label, size)
		field_x := x + 4*s
		field_w := width - 8*s - label_w - 20*s
		ui_fill_rect(ui, shared.Vec4{0, 0, 0, 0.4}, field_x, holder + 4*s, field_w, input_h - 8*s)
		baseline := holder + 10*s + CHAT_TEXT_PX*KH_ASCENT*s
		ui_fill_text(ui, label_color, label, x + width - 10*s - label_w, baseline, size)
		input := string(chat.input[:chat.input_length])
		shown := input
		for len(shown) > 0 && ui_measure_text(ui, shown, size) > field_w - 24*s { shown = shown[1:]; for len(shown) > 0 && (shown[0] & 0xC0) == 0x80 { shown = shown[1:] } }
		text_x := field_x + 10*s
		ui_fill_text(ui, white, shown, text_x, baseline, size)
		if (int(glfw.GetTime()*2) % 2) == 0 { ui_fill_text(ui, white, "|", text_x + ui_measure_text(ui, shown, size), baseline, size) }
		if len(input) == 0 { ui_fill_text(ui, shared.Vec4{1, 1, 1, 0.7}, "Enter Message", text_x + 6*s, baseline, size) }
		if team_mode {
			hint := "Tab: Team / All"
			ui_fill_text(ui, shared.Vec4{1, 1, 1, 0.5}, hint, x + width + 10*s, baseline, 12*KH_EM*s)
		}
	}
}
