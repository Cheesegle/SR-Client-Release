package shared

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

// Asset tracing records every file the client opens, relative to the
// repository root. It is off unless `--asset-sweep` turns it on, so the normal
// cost is one boolean check per load. Loaders call asset_trace after each open,
// whether it succeeded or not.
Asset_Trace :: struct {
	enabled:       bool,
	optional:      int, // > 0 while a load may fail without consequence
	used:          map[string]struct{},
	missing:       map[string]struct{},
	optional_miss: map[string]struct{},
}

g_asset_trace: Asset_Trace

asset_trace_begin :: proc() {
	asset_trace_end()
	g_asset_trace.enabled = true
}

asset_trace_end :: proc() {
	for set in ([]^map[string]struct{}{&g_asset_trace.used, &g_asset_trace.missing, &g_asset_trace.optional_miss}) {
		for key in set^ { delete(key) }
		delete(set^)
		set^ = nil
	}
	g_asset_trace = {}
}

// "./assets/x", "../assets/x" and "assets\x" all become "assets/x". Absolute
// paths are not packaged assets and return "".
asset_trace_relative :: proc(path: string, allocator := context.allocator) -> string {
	normalized, _ := strings.replace_all(path, "\\", "/", context.temp_allocator)
	if len(normalized) == 0 || normalized[0] == '/' || strings.contains(normalized, ":") { return "" }
	for {
		if strings.has_prefix(normalized, "./") { normalized = normalized[2:] }
		else if strings.has_prefix(normalized, "../") { normalized = normalized[3:] }
		else { break }
	}
	if len(normalized) == 0 || strings.contains(normalized, "/../") { return "" }
	return strings.clone(normalized, allocator)
}

asset_trace :: proc(path: string, ok: bool) {
	if !g_asset_trace.enabled { return }
	relative := asset_trace_relative(path, context.temp_allocator)
	if len(relative) == 0 { return }
	if ok {
		asset_trace_insert(&g_asset_trace.used, relative)
		if relative in g_asset_trace.missing {
			key, _ := delete_key(&g_asset_trace.missing, relative)
			delete(key)
		}
	} else if _, used := g_asset_trace.used[relative]; !used {
		asset_trace_insert(g_asset_trace.optional > 0 ? &g_asset_trace.optional_miss : &g_asset_trace.missing, relative)
	}
}

// Wrap probes that have a fallback (texture variants, sky captures) so a
// failed probe is reported separately and does not fail the sweep.
asset_trace_optional_begin :: proc() { g_asset_trace.optional += 1 }
asset_trace_optional_end :: proc() { g_asset_trace.optional = max(0, g_asset_trace.optional - 1) }

@(private = "file")
asset_trace_insert :: proc(set: ^map[string]struct{}, relative: string) {
	if relative in set^ { return }
	set^[strings.clone(relative)] = {}
}

asset_trace_sorted :: proc(set: map[string]struct{}, allocator := context.temp_allocator) -> []string {
	keys := make([]string, len(set), allocator)
	i := 0
	for key in set {
		keys[i] = key
		i += 1
	}
	slice.sort(keys)
	return keys
}

// Writes one sorted path per line. Returns false if the file cannot be saved.
asset_trace_write_list :: proc(path: string, set: map[string]struct{}) -> bool {
	builder := strings.builder_make(context.temp_allocator)
	for key in asset_trace_sorted(set) {
		fmt.sbprintln(&builder, key)
	}
	return os.write_entire_file(path, transmute([]byte)strings.to_string(builder)) == nil
}
