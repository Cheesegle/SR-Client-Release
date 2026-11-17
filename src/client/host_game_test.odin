package main

import "core:encoding/hex"
import "core:testing"
import menuui "../menu"
import kproto "../krunker"

// Krunker's own Comp setup with its defaults (Burg, 4v4), captured from its
// page on 2026-11-16 without the 2-byte counter. SR Client must send exactly this.
@(private = "file")
HOST_CAPTURED_DEFAULT :: "94a6637573746f6dde0065a770726976617465c2a96b7252657761726473c2ac64656661756c745365747473c2a57368617265c2a9637573746f6d4d6170c0aa7261774d617044617461c0a46d6170739100a56d6f646573c0a7636c6173736573c0a86f7665727269646501a870617373436f6465c0aa6d6178506c617965727302aa6d696e506c617965727300a867616d6554696d6504aa7761726d757054696d6500a967616d526f756e647303a9696e7465726d546d721eaa666f726365537061776e00a56c6976657300aa73636f72654c696d697400aa6b6565705453636f726500a96f626a747654696d6501a6666f7263654300a66c6f6754696d00a76c737443686b5400a7677261764d6c7401a864656c74614d6c7401a766616c6c446d6700aa66616c6c446d6754687200a76a756d704d6c7401a66669784d6f7600a8736c696454696d6501a7736c696453706401aa696d70756c73654d6c7401a677616c6c4a5001a9737472616665537064cb3ff3333333333333a863616e536c69646500a76169725374726600a86175746f4a756d7000a56244726f7000a96865616c74684d6c7401a9686974426f78506164cb3fb999999999999aac68757274626f785363616c6501a5666952617401a5726553706401a76870526567656e00ab6b696c6c5265776172647300a96e6f4173736973747300ac6865616473686f744f6e6c7900ab6e6f5365636f6e6461727900a96e6f53747265616b7300a864697361626c654200a87468726f774d656c00a8636872675765707300a773656c5465616d00a666724669726500a56e6f50767000a96e616d655465616d31a5416c706861a96e616d655465616d32a5427261766fa96e616d655465616d3300a96e616d655465616d3400a96e616d655465616d3500a57431446d6701a57432446d6701a57433446d6701a57434446d6701a57435446d6701aa616c6c6f775370656374c3ab7468697264506572736f6e00a86e616d655461677300aa6e616d6554616773465200a56b43616d7300a561416e6f6e00b37472616e73666572486f73744f6e4c65617665c3a973706563536c6f747302a6746d53697a6503a66e6f436f736dc3a6747374436d70c3a76e6f4472617773c3a66273744f6652c3ab68656164436c6970466978c3a772616d70466978c3a7776562686f6f6ba0a86d696e696d61707300ac6c696d6974436c6173736573c3a9636c6173734c696d3001a9636c6173734c696d3101a9636c6173734c696d3201a9636c6173734c696d3301a9636c6173734c696d3401a9636c6173734c696d3501a9636c6173734c696d3601a9636c6173734c696d3700a9636c6173734c696d3801a9636c6173734c696d3900aa636c6173734c696d313000aa636c6173734c696d313100aa636c6173734c696d313201aa636c6173734c696d313301aa636c6173734c696d313400aa636c6173734c696d313501c0c2"

@(test)
host_default_setup_matches_krunker :: proc(t: ^testing.T) {
	settings := menuui.host_settings_default()
	payload := host_custom_payload(&settings)
	defer delete(payload)
	expected, ok := hex.decode(transmute([]byte)string(HOST_CAPTURED_DEFAULT))
	defer delete(expected)
	testing.expect(t, ok)
	testing.expect_value(t, len(payload), len(expected))
	testing.expect(t, string(payload[:]) == string(expected))
}

@(test)
host_setup_carries_the_players_choices :: proc(t: ^testing.T) {
	settings := menuui.host_settings_default()
	settings.maps = {3, 11} // Shipment, Frontier
	settings.team_size = 0
	menuui.host_value_set(&settings, .OBJECTIVE_TIME, 1.5)
	menuui.host_value_set(&settings, .HITBOX_PAD, -0.3)
	settings.toggles -= {.NO_DRAWS}
	menuui.host_text_set(&settings, .TEAM1, "Reds")
	payload := host_custom_payload(&settings)
	defer delete(payload)
	messages, _, error_text := kproto.krunker_msgpack_decode_packet(append_counter(payload[:]))
	testing.expect_value(t, error_text, "")
	testing.expect_value(t, len(messages), 1)
	packet := messages[0].([]kproto.Krunker_Msgpack_Value)
	testing.expect_value(t, packet[0].(string), "custom")
	entries := packet[1].([]kproto.Krunker_Msgpack_Map_Entry)
	testing.expect_value(t, len(entries), 101)
	find :: proc(entries: []kproto.Krunker_Msgpack_Map_Entry, key: string) -> kproto.Krunker_Msgpack_Value {
		for entry in entries { if name, ok := entry.key.(string); ok && name == key { return entry.value } }
		return nil
	}
	maps := find(entries, "maps").([]kproto.Krunker_Msgpack_Value)
	testing.expect_value(t, len(maps), 2)
	testing.expect_value(t, maps[0].(i64), 5)
	testing.expect_value(t, maps[1].(i64), 42)
	testing.expect_value(t, find(entries, "tmSize").(i64), 0)
	testing.expect_value(t, find(entries, "objtvTime").(f64), 1.5)
	testing.expect_value(t, find(entries, "hitBoxPad").(f64), -0.3)
	testing.expect_value(t, find(entries, "noDraws").(bool), false)
	testing.expect_value(t, find(entries, "nameTeam1").(string), "Reds")
}

@(private = "file")
append_counter :: proc(payload: []byte) -> []byte {
	out := make([]byte, len(payload)+2, context.temp_allocator)
	copy(out, payload)
	return out
}

@(test)
host_game_ids_are_checked :: proc(t: ^testing.T) {
	testing.expect(t, shared_game_id_valid("FRA:4llbw"))
	testing.expect(t, !shared_game_id_valid("FRA:"))
	testing.expect(t, !shared_game_id_valid("FRA:4ll/bw"))
	testing.expect(t, !shared_game_id_valid("nothing"))
}

@(test)
host_region_is_krunkers_default_region :: proc(t: ^testing.T) {
	hud: menuui.HUD_Settings
	testing.expect_value(t, menuui.default_region(hud).id, "de-fra") // unset = Frankfurt
	hud.default_region = 8
	testing.expect_value(t, menuui.default_region(hud).id, "us-tx")
	testing.expect_value(t, menuui.default_region(hud).name, "Dallas")
}
