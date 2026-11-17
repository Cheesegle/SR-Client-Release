package main

import "core:testing"
import "core:strings"
import kproto "../krunker"

@(test)
chat_unescape_html :: proc(t: ^testing.T) {
	testing.expect_value(t, chat_unescape("1 hp &amp; low &lt;3"), "1 hp & low <3")
	testing.expect_value(t, chat_unescape("it&#39;s &#x27;ok&#x27; &quot;go&quot;"), "it's 'ok' \"go\"")
	testing.expect_value(t, chat_unescape("<span style='color:red'>[CLAN]</span> name"), "[CLAN] name")
	testing.expect_value(t, chat_unescape("&unknown; stays"), "&unknown; stays")
	testing.expect_value(t, chat_unescape("&#269;au"), "čau")
}

@(test)
chat_color_parse :: proc(t: ^testing.T) {
	fallback := [4]f32{0, 0, 0, 0}
	testing.expect_value(t, chat_parse_color("#ff0000", fallback), [4]f32{1, 0, 0, 1})
	testing.expect_value(t, chat_parse_color("#0f0", fallback), [4]f32{0, 1, 0, 1})
	testing.expect_value(t, chat_parse_color("nope", fallback), fallback)
}

// "ct" goes out as [ "ct", channel, text ] plus the two counter bytes, and
// decodes back to the same values.
@(test)
chat_send_packet_round_trip :: proc(t: ^testing.T) {
	state: Krunker_WS_State
	for channel in ([2]i32{0, 1}) {
		text := channel == 1 ? "1 hp" : strings.repeat("ž", 70, context.temp_allocator)
		counter := u8(7)
		packet := krunker_ws_chat_packet(&state, channel, text, &counter)
		defer delete(packet)
		testing.expect_value(t, counter, kproto.krunker_msgpack_counter_next(7, "ct"))
		messages, trailer, error := kproto.krunker_msgpack_decode_packet(packet[:])
		testing.expect_value(t, error, "")
		testing.expect_value(t, trailer, counter)
		if len(messages) != 1 { testing.fail(t); continue }
		values, ok := messages[0].([]kproto.Krunker_Msgpack_Value)
		testing.expect(t, ok && len(values) == 3)
		if !ok || len(values) != 3 { continue }
		testing.expect_value(t, values[0].(string), "ct")
		testing.expect_value(t, values[1].(i64), i64(channel))
		testing.expect_value(t, values[2].(string), text)
	}
}

@(test)
chat_receive_lines :: proc(t: ^testing.T) {
	kill_chat_clear()
	defer kill_chat_clear()
	client: Client
	packet := []kproto.Krunker_Msgpack_Value{"ch", i64(1), "Teammate", "1 hp &amp; rotating", i64(0), nil, "#9eeb56", i64(42)}
	chat_receive(&client, packet)
	server := []kproto.Krunker_Msgpack_Value{"ch", i64(-1), "", "Match starting", i64(2), "#ffffff"}
	chat_receive(&client, server)
	trade := []kproto.Krunker_Msgpack_Value{"ch", i64(0), "x", "12", i64(3)}
	chat_receive(&client, trade)
	testing.expect_value(t, g_chat.count, 2)
	line := &g_chat.lines[0]
	testing.expect_value(t, line.kind, Chat_Line_Kind.PLAYER)
	testing.expect_value(t, line.channel, i8(1))
	testing.expect_value(t, string(line.name[:line.name_length]), "Teammate")
	testing.expect_value(t, string(line.text[:line.text_length]), "1 hp & rotating")
	testing.expect_value(t, g_chat.lines[1].kind, Chat_Line_Kind.SYSTEM)
	testing.expect_value(t, g_chat.lines[1].text_color, [4]f32{1, 1, 1, 1})
}

@(test)
chat_typing_input :: proc(t: ^testing.T) {
	kill_chat_clear()
	defer kill_chat_clear()
	chat_open()
	chat_character('x') // the key that opened the box
	g_chat.ignore_chars = false
	for c in "1 hp č" { chat_character(c) }
	testing.expect_value(t, string(g_chat.input[:g_chat.input_length]), "1 hp č")
	for _ in 0..<200 { chat_character('a') }
	count := 0
	for _ in string(g_chat.input[:g_chat.input_length]) { count += 1 }
	testing.expect_value(t, count, CHAT_MAX_RUNES)
	chat_close()
	testing.expect(t, !chat_typing())
}
