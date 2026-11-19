package main

import "core:testing"
import "core:strings"
import "core:os"

// A dev build saves each game as one numbered section with the tester's
// weapons, input rate and every shot line, and a checkpoint left by a killed
// client is recovered as the next game.
@(test)
tester_export_saves_numbered_games_and_recovers_a_killed_one :: proc(t: ^testing.T) {
	when !TESTER_EXPORT { return }
	saved_export, saved_existing := g_export, os.exists(TESTER_EXPORT_FILE)
	if saved_existing { return } // never touch a real tester log
	defer { _ = os.remove(TESTER_EXPORT_FILE); _ = os.remove(TESTER_EXPORT_CURRENT); g_export = saved_export }
	client := new(Client); defer free(client)

	g_export = {}
	g_export.open = true
	g_export.ping_min = max(i32)
	tester_export_shot("t=1.000 Revolver aimed=3H server=3H rate=720\n", "Revolver", 720, true, true)
	tester_export_shot("t=1.500 Revolver aimed=- server=- rate=720\n", "Revolver", 720, false, false)
	tester_export_save(client, "finished")
	g_export.open = true
	tester_export_shot("t=9.000 Pistol aimed=2B server=- rate=1000\n", "Pistol", 1000, true, false)
	tester_export_save(client, "left before the end")
	// A killed client: only the checkpoint is left.
	testing.expect(t, tester_export_write(TESTER_EXPORT_CURRENT, "=== Game 0 === killed\nshots:\n", false))
	tester_export_recover()

	data, err := os.read_entire_file_from_path(TESTER_EXPORT_FILE, context.temp_allocator)
	testing.expect(t, err == nil)
	text := string(data)
	testing.expect(t, strings.has_prefix(text, "=== Game 1 ==="), "first game is Game 1")
	testing.expect(t, strings.contains(text, "  Revolver: 2 / 1 / 1"), "per-weapon shots / crosshair on / server hits")
	testing.expect(t, strings.contains(text, "inputs per second: 720\n"), "the input rate of the game's shots")
	testing.expect(t, strings.contains(text, "t=1.500 Revolver"), "every shot line is in the section")
	testing.expect(t, strings.contains(text, "=== Game 2 ===") && strings.contains(text, "left before the end") && strings.contains(text, "inputs per second: 1000\n"))
	testing.expect(t, strings.contains(text, "=== Game 3 === killed"), "a killed client's game is recovered as the next game")
	testing.expect(t, !os.exists(TESTER_EXPORT_CURRENT), "the checkpoint is removed once recovered")
}
