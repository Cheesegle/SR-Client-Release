#+build !windows
package main

import "core:fmt"
import "core:os"

tester_export_desktop_path :: proc() -> string {
	home, found := os.lookup_env_alloc("HOME", context.temp_allocator)
	if !found { return "" }
	return fmt.tprintf("%s/Desktop/%s", home, TESTER_EXPORT_DESKTOP_NAME)
}

tester_export_show_in_folder :: proc(path: string) {}

cpu_model_name_windows :: proc() -> string { return "Unknown CPU" }
