#+build !windows
package main

import "core:fmt"
import "core:os"
import "core:time"

tester_export_downloads_path :: proc(name: string) -> string {
	home, found := os.lookup_env_alloc("HOME", context.temp_allocator)
	if !found { return "" }
	return fmt.tprintf("%s/Downloads/%s", home, name)
}

tester_export_show_in_folder :: proc(path: string) {}

tester_export_local_stamp :: proc() -> string {
	now, _ := time.time_to_datetime(time.now())
	return fmt.tprintf("%04d-%02d-%02d_%02d-%02d-%02d", now.year, now.month, now.day, now.hour, now.minute, now.second)
}

cpu_model_name_windows :: proc() -> string { return "Unknown CPU" }

tester_export_system_text :: proc() -> string { return ODIN_OS_STRING }
