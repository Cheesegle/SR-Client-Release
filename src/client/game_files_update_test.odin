package main

import "core:testing"

// Map auto-update: only Krunker's {"data":{...}} answer for the expected map
// is accepted, byte for byte.
@(test)
game_files_map_answer_is_checked :: proc(t: ^testing.T) {
	data, ok := game_files_map_data(`{"data":{"name":"Burg","objects":[{"p":[0,0,0]}],"spawns":[[1,2,3]]}}`)
	testing.expect(t, ok && data == `{"name":"Burg","objects":[{"p":[0,0,0]}],"spawns":[[1,2,3]]}`, "the data object is kept exactly")
	testing.expect(t, game_files_map_valid(data, 0), "Burg is map 0")
	testing.expect(t, !game_files_map_valid(data, 1), "a different map at index 1 is refused")
	_, bad := game_files_map_data(`<html>error</html>`)
	testing.expect(t, !bad, "an error page is refused")
	empty, empty_ok := game_files_map_data(`{"data":{"name":"Burg","objects":[],"spawns":[]}}`)
	testing.expect(t, empty_ok && !game_files_map_valid(empty, 0), "a map without objects or spawns is refused")
	spaced, spaced_ok := game_files_map_data(`{"data":{"name":"Krunk Plaza","objects":[1],"spawns":[1]}}`)
	testing.expect(t, spaced_ok && game_files_map_valid(spaced, 20), "names with spaces match their file name")
	factory, factory_ok := game_files_map_data(`{"data":{"name":"Factory","objects":[1],"spawns":[1]}}`)
	testing.expect(t, factory_ok && !game_files_map_valid(factory, 40) && game_files_map_valid(factory, 40, "Factory"), "a renamed map matches the name of the file it replaces")
}
