package main

import "core:os"
import "core:testing"
import menuui "../menu"
import shared "../shared"
import kproto "../krunker"

when ODIN_TEST {
	@(test)
	show_ping_defaults_on_and_persists :: proc(t: ^testing.T) {
		testing.expect(t, !client_settings_defaults().hud.hide_ping, "Show Ping must default to on, like Krunker's showPing")
		path := "bin/client-settings-ping-test.json"
		defer os.remove(path)
		testing.expect(t, os.write_entire_file(path, `{"version":1,"hud":{"hide_timer":true}}`) == nil)
		legacy := client_settings_load(path)
		testing.expect(t, legacy.hud.hide_timer && !legacy.hud.hide_ping, "existing preferences without the key must show ping")
		settings := client_settings_defaults()
		settings.hud.hide_ping = true
		testing.expect(t, client_settings_save(settings, path))
		testing.expect(t, client_settings_load(path).hud.hide_ping, "turning Show Ping off must survive a restart")

		client := Client{sensitivity = 1, audio_settings = DEFAULT_AUDIO_SETTINGS, visual_settings = menuui.DEFAULT_VISUAL_SETTINGS}
		client.menu.page = .SETTINGS
		menuui.prepare_settings(&client.menu, {sensitivity = 1, mouse_dpi = menuui.DEFAULT_MOUSE_DPI})
		client.menu.settings_draft.hud.hide_ping = true
		menu_apply_action(&client, {kind = .SETTINGS_SAVE})
		testing.expect(t, client.hud_settings.hide_ping && client_settings_snapshot(&client).hud.hide_ping, "Save must apply and persist Show Ping")
	}

	@(test)
	ping_label_and_color_match_krunker :: proc(t: ^testing.T) {
		testing.expect(t, ping_label(0, false) == "0", "pingText starts at 0 before the first report")
		testing.expect(t, ping_label(-1, true) == "-", "a reported -1 renders as -")
		testing.expect(t, ping_label(87, true) == "87")
		low, medium, high := ping_color(49), ping_color(50), ping_color(150)
		testing.expect(t, low == shared.Vec4{158.0/255, 235.0/255, 86.0/255, 1} && ping_color(-1) == low && ping_color(0) == low)
		testing.expect(t, medium == shared.Vec4{1, 213.0/255, 66.0/255, 1} && ping_color(149) == medium)
		testing.expect(t, high == shared.Vec4{1, 75.0/255, 66.0/255, 1} && ping_color(400) == high)

		client := Client{}
		_, _, available := client_ping(&client)
		testing.expect(t, !available, "local practice has no server to ping")
		client.net.connected = true
		client.net.ping = {has_sample = true, rtt_ms = 23}
		value, received, native := client_ping(&client)
		testing.expect(t, native && received && value == 23, "native sessions use the echo round trip")
		client.krunker.connected = true
		client.krunker_world.ping, client.krunker_world.has_ping = 61, true
		value, received, _ = client_ping(&client)
		testing.expect(t, received && value == 61, "live sessions use the server-reported ping")
	}

	@(test)
	krunker_sync_player_reports_most_recent_ping :: proc(t: ^testing.T) {
		world := kproto.Krunker_World_State{local_sid = 7}
		defer kproto.krunker_world_reset(&world)
		local: [18]kproto.Krunker_Msgpack_Value
		for &value in local { value = i64(0) }
		packet := []kproto.Krunker_Msgpack_Value{"l", local[:]}
		testing.expect(t, kproto.krunker_world_apply_sync_player(&world, packet) && !world.has_ping, "a zero ping is falsy and must not count as a report")
		local[1] = i64(42)
		kproto.krunker_world_apply_sync_player(&world, packet)
		testing.expect(t, world.has_ping && world.ping == 42)
		local[1] = i64(0)
		kproto.krunker_world_apply_sync_player(&world, packet)
		testing.expect(t, world.ping == 42, "zero keeps the previous ping, like the browser")
		local[1] = i64(-1)
		kproto.krunker_world_apply_sync_player(&world, packet)
		testing.expect(t, world.ping == -1 && ping_label(world.ping, world.has_ping) == "-")
		local[1] = f64(130)
		kproto.krunker_world_apply_sync_player(&world, packet)
		testing.expect(t, world.ping == 130, "the latest report replaces the previous value without smoothing")
	}

	@(test)
	native_ping_echo_measures_round_trip :: proc(t: ^testing.T) {
		buf: [shared.NET_PING_PACKET_SIZE]byte
		size := shared.packet_serialize_ping(buf[:], 0xDEADBEEF)
		seq, ok := shared.packet_deserialize_ping(buf[:size])
		testing.expect(t, size == shared.NET_PING_PACKET_SIZE && ok && seq == 0xDEADBEEF)
		_, ok = shared.packet_deserialize_ping(buf[:size-1])
		testing.expect(t, !ok, "truncated probes must be rejected")

		state: shared.Net_Ping_State
		first, due := shared.net_ping_due(&state, 10)
		testing.expect(t, due && first == 1, "the first probe goes out immediately")
		_, due = shared.net_ping_due(&state, 10.5)
		testing.expect(t, !due, "probes are spaced by the interval")
		testing.expect(t, !shared.net_ping_receive(&state, first+1, 10.02) && !state.has_sample, "an unknown sequence is ignored")
		testing.expect(t, shared.net_ping_receive(&state, first, 10.0374) && state.rtt_ms == 37, "RTT is rounded to whole milliseconds")
		testing.expect(t, !shared.net_ping_receive(&state, first, 10.5), "a duplicate echo must not replace the sample")
		second, _ := shared.net_ping_due(&state, 11)
		testing.expect(t, !shared.net_ping_receive(&state, first, 11.001) && state.rtt_ms == 37, "a late echo of an older probe must not produce a short sample")
		testing.expect(t, shared.net_ping_receive(&state, second, 11.120) && state.rtt_ms == 120, "the most recent sample is shown without smoothing")
	}
}
