#+build !windows

package main

// Only Windows needs the game-drawn fullscreen cursor (see software_cursor.odin);
// elsewhere the OS cursor is left alone.
system_arrow_cursor_rgba :: proc(allocator := context.allocator) -> (rgba: []u8, width, height, hot_x, hot_y: i32, ok: bool) {
	return
}
