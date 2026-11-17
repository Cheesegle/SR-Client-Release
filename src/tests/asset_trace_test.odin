package main

import "core:fmt"
import "core:os"
import "core:strings"
import shared "../shared"

// The packager trusts the sweep manifest, so its path normalization, the
// required/optional split and the sorted output must stay stable.
test_asset_trace :: proc() -> bool {
	ok := true
	check :: proc(ok: ^bool, condition: bool, message: string) {
		if !condition {
			fmt.eprintln("Asset trace test:", message)
			ok^ = false
		}
	}

	relative := shared.asset_trace_relative(`../assets\maps/burg.json`, context.temp_allocator)
	check(&ok, relative == "assets/maps/burg.json", "relative paths must normalize to repository-root form")
	check(&ok, shared.asset_trace_relative("C:/assets/x.png", context.temp_allocator) == "", "absolute paths are not packaged")

	shared.asset_trace("./assets/textures/a.png", true)
	check(&ok, len(shared.g_asset_trace.used) == 0, "tracing must be off by default")

	shared.asset_trace_begin()
	shared.asset_trace("./assets/textures/b.png", true)
	shared.asset_trace("./assets/textures/a.png", true)
	shared.asset_trace("assets/textures/a.png", true)
	shared.asset_trace("./assets/sound/missing.mp3", false)
	shared.asset_trace_optional_begin()
	shared.asset_trace("./assets/textures/a_3.png", false)
	shared.asset_trace_optional_end()
	shared.asset_trace("krunker-configs/class-configs.json", true)
	trace := &shared.g_asset_trace
	check(&ok, len(trace.used) == 3, "used paths must be unique")
	check(&ok, "assets/sound/missing.mp3" in trace.missing, "a failed required load must be reported missing")
	check(&ok, "assets/textures/a_3.png" in trace.optional_miss && !("assets/textures/a_3.png" in trace.missing),
		"a failed probe with a fallback must not fail the sweep")

	path := "asset_trace_test_manifest.txt"
	written := shared.asset_trace_write_list(path, trace.used)
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	os.remove(path)
	expected := "assets/textures/a.png\nassets/textures/b.png\nkrunker-configs/class-configs.json\n"
	check(&ok, written && err == nil && strings.compare(string(data), expected) == 0, "the manifest must be sorted, one path per line")
	shared.asset_trace_end()
	check(&ok, !shared.g_asset_trace.enabled && len(shared.g_asset_trace.used) == 0, "ending the trace must reset it")
	return ok
}
