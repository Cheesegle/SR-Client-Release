#+build !windows

package main

import "core:os"

// Crash and hang reports are Windows-only for now; elsewhere the OS's own
// core dumps cover crashes. The writer still works so tests can use it.

crash_file_write :: proc(path: string, data: []u8) -> bool {
	diagnostics_make_log_dir()
	return os.write_entire_file(path, data) == nil
}

crash_handler_install :: proc() {}

crash_handler_uninstall :: proc() {}
