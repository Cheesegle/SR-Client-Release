package main

import "core:encoding/json"
import "core:testing"

// SR Client joins custom games only: a game listed as public ("c": 0) is
// refused; listed customs ("c": 1) and unlisted private lobbies (comp and
// bot-hosted games) are allowed, whatever their mode.
@(test)
custom_only_refuses_listed_public_games :: proc(t: ^testing.T) {
	list := `{"games":[
		["TOK:lbk0j","jb-hnd",4,8,{"c":0,"g":0,"i":"Site"},234],
		["NY:5ftt0","us-nj",0,8,{"c":1,"g":23,"i":"Tortuga","oc":1},297],
		["FRA:9u9rm","de-fra",2,2,{"c":1,"g":0,"i":"Bureau"},0]
	]}`
	value, err := json.parse_string(list, parse_integers = true)
	testing.expect(t, err == .None)
	defer json.destroy_value(value)
	testing.expect(t, krunker_ws_game_is_public(value, "TOK:lbk0j"), "a public match must be refused")
	testing.expect(t, !krunker_ws_game_is_public(value, "NY:5ftt0"), "an official custom game must be allowed")
	testing.expect(t, !krunker_ws_game_is_public(value, "FRA:9u9rm"), "a custom FFA 1v1 must be allowed")
	testing.expect(t, !krunker_ws_game_is_public(value, "LON:private1"), "an unlisted private lobby (comp, bot-hosted) must be allowed")
}
