package shared

import "base:runtime"
import "core:bytes"
import "core:compress/zlib"
import "core:encoding/endian"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"

// SR Client mods. The player picks a mod in Krunker's own Mods window (the
// browser helper); SR Client downloads that mod's zip into its private mods
// folder and loads its files instead of the game's matching files:
//
//   <mod>/sound/weapon_1.mp3   replaces assets/sound/weapon_1.mp3
//
// Only textures, models, sounds and images can be swapped; maps, shaders and
// configs always come from the game. Loading or removing a mod re-indexes the
// folder and the client reloads the changed files in place (no restart).

MOD_FOLDERS :: [?]string{"textures", "models", "sound", "img"}
MOD_UNPACK_DIR :: ".unpacked"
MOD_ZIP_MAX_ENTRY :: 256 * 1024 * 1024
MOD_ZIP_MAX_TOTAL :: 1024 * 1024 * 1024
MOD_ZIP_MAX_ENTRIES :: 20000

Mods :: struct {
	ready:     bool,
	directory: string,
	index:     map[string]string, // lowercase "sound/x.mp3" -> absolute file path
	zips:      int,
	errors:    int,
	active:    string, // the loaded Krunker mod's link, for Settings
}

g_mods: Mods

// %LOCALAPPDATA%\SR-Client\mods on Windows (beside the browser profile),
// ./mods elsewhere. Players never need to open it.
mods_directory :: proc(allocator := context.allocator) -> string {
	when ODIN_OS == .Windows {
		local, found := os.lookup_env_alloc("LOCALAPPDATA", context.temp_allocator)
		if found && len(local) > 0 { return fmt.aprintf("%s\\SR-Client\\mods", local, allocator = allocator) }
	}
	return strings.clone("mods", allocator)
}

MOD_ACTIVE_ZIP :: "krunker-mod.zip"
MOD_ACTIVE_NAME :: "active.txt"


// Finds the part of a path that starts at a swappable game folder, e.g.
// "MyMod/Sound/Weapon_1.mp3" -> "sound/weapon_1.mp3". Returns "" otherwise.
mods_key :: proc(relative: string, allocator := context.temp_allocator) -> string {
	normalized, _ := strings.replace_all(relative, "\\", "/", context.temp_allocator)
	lower := strings.to_lower(normalized, context.temp_allocator)
	parts := strings.split(lower, "/", context.temp_allocator)
	for part, i in parts {
		for folder in MOD_FOLDERS {
			if part == folder && i+1 < len(parts) { return strings.join(parts[i:], "/", allocator) }
		}
	}
	return ""
}

mods_init :: proc() {
	mods_shutdown()
	g_mods.directory = mods_directory()
	if err := os.make_directory_all(g_mods.directory); err != nil && !os.is_dir(g_mods.directory) {
		fmt.eprintln("[Mods] Could not create the mods folder:", g_mods.directory)
		return
	}
	name_path := strings.concatenate({g_mods.directory, "/", MOD_ACTIVE_NAME}, context.temp_allocator)
	if name, err := os.read_entire_file_from_path(name_path, context.temp_allocator); err == nil { g_mods.active = strings.clone(strings.trim_space(string(name))) }

	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil { return }
	defer virtual.arena_destroy(&arena)
	scratch := virtual.arena_allocator(&arena)

	// Unpack Krunker mod zips first; their files are indexed before loose files.
	entries, err := os.read_all_directory_by_path(g_mods.directory, scratch)
	if err == nil {
		slice.sort_by(entries, proc(a, b: os.File_Info) -> bool { return a.name < b.name })
		for entry in entries {
			if entry.type == .Directory || !strings.has_suffix(strings.to_lower(entry.name, scratch), ".zip") { continue }
			name := entry.name[:len(entry.name)-4]
			target := strings.concatenate({g_mods.directory, "/", MOD_UNPACK_DIR, "/", name}, scratch)
			if len(mods_unpack_zip(entry.fullpath, target, entry.size, scratch)) == 0 { g_mods.zips += 1 } else { g_mods.errors += 1 }
		}
	}
	unpacked := strings.concatenate({g_mods.directory, "/", MOD_UNPACK_DIR}, scratch)
	if os.is_dir(unpacked) { mods_index_tree(unpacked, unpacked, true, scratch) }
	mods_index_tree(g_mods.directory, g_mods.directory, false, scratch)
	g_mods.ready = true
	if len(g_mods.index) > 0 || g_mods.errors > 0 {
		fmt.printfln("[Mods] %d swapped files from %s (%d zip mods, %d problems)", len(g_mods.index), g_mods.directory, g_mods.zips, g_mods.errors)
	}
}

mods_shutdown :: proc() {
	for key, value in g_mods.index { delete(key); delete(value) }
	delete(g_mods.index)
	delete(g_mods.directory)
	delete(g_mods.active)
	g_mods = {}
}

@(private = "file")
mods_index_tree :: proc(root, dir: string, inside_unpacked: bool, scratch: runtime.Allocator) {
	entries, err := os.read_all_directory_by_path(dir, scratch)
	if err != nil { return }
	slice.sort_by(entries, proc(a, b: os.File_Info) -> bool { return a.name < b.name })
	for entry in entries {
		if entry.type == .Directory {
			if !inside_unpacked && dir == root && entry.name == MOD_UNPACK_DIR { continue }
			mods_index_tree(root, entry.fullpath, inside_unpacked, scratch)
			continue
		}
		relative := entry.fullpath[min(len(root)+1, len(entry.fullpath)):]
		key := mods_key(relative, scratch)
		if len(key) == 0 { continue }
		if old_value, found := g_mods.index[key]; found {
			old_key, _ := delete_key(&g_mods.index, key)
			delete(old_key); delete(old_value)
		}
		g_mods.index[strings.clone(key)] = strings.clone(entry.fullpath)
	}
}


// The file to load for a game asset: the mod's copy if one exists.
mod_resolve :: proc(path: string) -> string {
	if !g_mods.ready || len(g_mods.index) == 0 { return path }
	relative := asset_trace_relative(path, context.temp_allocator)
	if len(relative) == 0 { return path }
	if strings.has_prefix(relative, "assets/") { relative = relative[len("assets/"):] }
	key := strings.to_lower(relative, context.temp_allocator)
	if override, found := g_mods.index[key]; found { return override }
	return path
}

// Unpacks a .zip once; a marker records the source size so an unchanged zip
// is not unpacked again. Only swappable folders are written. Returns "" or
// why the zip could not be used.
@(private = "file")
mods_unpack_zip :: proc(zip_path, target: string, size: i64, scratch: runtime.Allocator) -> string {
	marker := strings.concatenate({target, "/.source"}, scratch)
	stamp := fmt.aprintf("size=%d", size, allocator = scratch)
	if existing, err := os.read_entire_file_from_path(marker, scratch); err == nil && string(existing) == stamp { return "" }
	if os.is_dir(target) { _ = os.remove_all(target) }
	data, err := os.read_entire_file_from_path(zip_path, scratch)
	if err != nil { fmt.eprintln("[Mods] Could not read", zip_path); return "could not read the saved zip" }
	if reason := mods_zip_extract(data, target, scratch); len(reason) > 0 { fmt.eprintln("[Mods]", reason, zip_path); return reason }
	_ = os.make_directory_all(target)
	_ = os.write_entire_file(marker, transmute([]byte)stamp)
	return ""
}

// What a download looks like when it is not a zip, for the error message.
mods_describe_data :: proc(data: []byte, allocator := context.temp_allocator) -> string {
	if len(data) == 0 { return "the download was empty" }
	head := data[:min(len(data), 12)]
	text := true
	for b in head { if b < 9 || (b > 13 && b < 32) || b > 126 { text = false } }
	if text { return fmt.aprintf("not a zip: %d bytes starting with \"%s\"", len(data), string(head), allocator = allocator) }
	return fmt.aprintf("not a zip: %d bytes starting with %x", len(data), head, allocator = allocator)
}

@(private = "file")
Zip_Entry :: struct { name: string, method: int, comp_size, full_size, local: int }

@(private = "file")
mods_zip_u16 :: proc(data: []byte, at: int) -> int { v, _ := endian.get_u16(data[at:], .Little); return int(v) }
@(private = "file")
mods_zip_u32 :: proc(data: []byte, at: int) -> int { v, _ := endian.get_u32(data[at:], .Little); return int(v) }
@(private = "file")
mods_zip_u64 :: proc(data: []byte, at: int) -> int { v, _ := endian.get_u64(data[at:], .Little); return int(min(v, u64(max(int)))) }

// The entries from the central directory (Zip64 included), or from the local
// headers when the archive has no usable central directory.
@(private = "file")
mods_zip_entries :: proc(data: []byte, scratch: runtime.Allocator) -> (entries: [dynamic]Zip_Entry, reason: string) {
	entries = make([dynamic]Zip_Entry, scratch)
	if len(data) < 22 || data[0] != 'P' || data[1] != 'K' { return entries, mods_describe_data(data, scratch) }
	eocd := -1
	for i := len(data)-22; i >= max(0, len(data)-22-65535); i -= 1 {
		if mods_zip_u32(data, i) == 0x06054b50 { eocd = i; break }
	}
	central := eocd >= 0
	count, cd_offset := 0, 0
	if central {
		count, cd_offset = mods_zip_u16(data, eocd+10), mods_zip_u32(data, eocd+16)
		// Zip64: the real values are in the Zip64 end record.
		if (count == 0xffff || cd_offset == 0xffffffff) && eocd >= 20 && mods_zip_u32(data, eocd-20) == 0x07064b50 {
			z := mods_zip_u64(data, eocd-20+8)
			if z >= 0 && z+56 <= len(data) && mods_zip_u32(data, z) == 0x06064b50 {
				count, cd_offset = mods_zip_u64(data, z+32), mods_zip_u64(data, z+48)
			}
		}
		if count > MOD_ZIP_MAX_ENTRIES { return entries, "too many files in the zip" }
		if cd_offset < 0 || cd_offset >= len(data) { central = false }
	}
	if central {
		pos := cd_offset
		for _ in 0..<count {
			if pos+46 > len(data) || mods_zip_u32(data, pos) != 0x02014b50 { central = false; break }
			entry := Zip_Entry{method = mods_zip_u16(data, pos+10), comp_size = mods_zip_u32(data, pos+20), full_size = mods_zip_u32(data, pos+24), local = mods_zip_u32(data, pos+42)}
			name_len, extra_len, comment_len := mods_zip_u16(data, pos+28), mods_zip_u16(data, pos+30), mods_zip_u16(data, pos+32)
			if pos+46+name_len+extra_len > len(data) { central = false; break }
			entry.name = string(data[pos+46:][:name_len])
			// Zip64 extra field: the 0xffffffff values follow in order.
			extra := data[pos+46+name_len:][:extra_len]
			for e := 0; e+4 <= len(extra); {
				id, size := mods_zip_u16(extra, e), mods_zip_u16(extra, e+2)
				if id == 1 {
					at := e+4
					if entry.full_size == 0xffffffff && at+8 <= len(extra) { entry.full_size = mods_zip_u64(extra, at); at += 8 }
					if entry.comp_size == 0xffffffff && at+8 <= len(extra) { entry.comp_size = mods_zip_u64(extra, at); at += 8 }
					if entry.local == 0xffffffff && at+8 <= len(extra) { entry.local = mods_zip_u64(extra, at) }
				}
				e += 4 + size
			}
			append(&entries, entry)
			pos += 46 + name_len + extra_len + comment_len
		}
	}
	if central && len(entries) > 0 { return entries, "" }
	// No usable central directory: walk the local headers.
	clear(&entries)
	for pos := 0; pos+30 <= len(data) && len(entries) < MOD_ZIP_MAX_ENTRIES; {
		if mods_zip_u32(data, pos) != 0x04034b50 { break }
		flags := mods_zip_u16(data, pos+6)
		entry := Zip_Entry{method = mods_zip_u16(data, pos+8), comp_size = mods_zip_u32(data, pos+18), full_size = mods_zip_u32(data, pos+22), local = pos}
		name_len, extra_len := mods_zip_u16(data, pos+26), mods_zip_u16(data, pos+28)
		if pos+30+name_len > len(data) || (flags & 8) != 0 { break } // sizes only after the data: cannot walk on
		entry.name = string(data[pos+30:][:name_len])
		append(&entries, entry)
		pos += 30 + name_len + extra_len + entry.comp_size
	}
	if len(entries) == 0 { return entries, "damaged zip (no file list)" }
	return entries, ""
}

@(private = "file")
mods_zip_extract :: proc(data: []byte, target: string, scratch: runtime.Allocator) -> string {
	entries, reason := mods_zip_entries(data, scratch)
	if len(reason) > 0 { return reason }
	total, written := 0, 0
	for entry in entries {
		name := entry.name
		if strings.has_suffix(name, "/") || len(mods_key(name, scratch)) == 0 { continue }
		if strings.contains(name, "..") || strings.contains(name, ":") || strings.has_prefix(name, "/") || strings.has_prefix(name, "\\") { continue }
		if entry.full_size > MOD_ZIP_MAX_ENTRY || entry.comp_size < 0 { continue }
		total += entry.full_size
		if total > MOD_ZIP_MAX_TOTAL { return "the mod is larger than 1 GB unpacked" }

		lh := entry.local
		if lh < 0 || lh+30 > len(data) || mods_zip_u32(data, lh) != 0x04034b50 { continue }
		start := lh + 30 + mods_zip_u16(data, lh+26) + mods_zip_u16(data, lh+28)
		if start+entry.comp_size > len(data) { continue }
		raw := data[start:][:entry.comp_size]

		contents: []byte
		switch entry.method {
		case 0: contents = raw
		case 8:
			buffer: bytes.Buffer
			if zlib.inflate(raw, &buffer, true, entry.full_size) != nil { bytes.buffer_destroy(&buffer); continue }
			contents = slice.clone(bytes.buffer_to_bytes(&buffer), scratch)
			bytes.buffer_destroy(&buffer)
		case: continue // Other compression methods are skipped.
		}
		out := strings.concatenate({target, "/", name}, scratch)
		when ODIN_OS == .Windows { out, _ = strings.replace_all(out, "/", "\\", scratch) }
		slash := max(strings.last_index_byte(out, '/'), strings.last_index_byte(out, '\\'))
		if slash > 0 { _ = os.make_directory_all(out[:slash]) }
		if os.write_entire_file(out, contents) == nil { written += 1 }
	}
	if written == 0 { return "no textures, models, sounds or images in this mod" }
	return ""
}

// Writes and unpacks a Krunker mod archive into `directory` without touching
// g_mods, so it can run on the download thread. mods_init afterwards only
// re-indexes (the unpack marker matches). Returns "" or why it failed.
mods_prepare :: proc(directory: string, zip: []byte, link: string) -> string {
	if len(zip) < 22 || zip[0] != 'P' || zip[1] != 'K' { return mods_describe_data(zip) }
	mods_remove_files(directory)
	if err := os.make_directory_all(directory); err != nil && !os.is_dir(directory) { return "could not create the mods folder" }
	target := strings.concatenate({directory, "/", MOD_ACTIVE_ZIP}, context.temp_allocator)
	if os.write_entire_file(target, zip) != nil { return "could not save the zip" }
	name := strings.concatenate({directory, "/", MOD_ACTIVE_NAME}, context.temp_allocator)
	_ = os.write_entire_file(name, transmute([]byte)link)
	unpacked := strings.concatenate({directory, "/", MOD_UNPACK_DIR, "/", MOD_ACTIVE_ZIP[:len(MOD_ACTIVE_ZIP)-4]}, context.temp_allocator)
	reason := mods_unpack_zip(target, unpacked, i64(len(zip)), context.temp_allocator)
	if len(reason) > 0 { mods_remove_files(directory) } // keep the previous state clean
	return reason
}

// Replaces the loaded mod with `zip` (a Krunker mod archive). Call mods_init
// afterwards to use it.
mods_install :: proc(zip: []byte, link: string) -> bool {
	directory := len(g_mods.directory) > 0 ? strings.clone(g_mods.directory, context.temp_allocator) : mods_directory(context.temp_allocator)
	mods_remove_files(directory)
	if err := os.make_directory_all(directory); err != nil && !os.is_dir(directory) { return false }
	target := strings.concatenate({directory, "/", MOD_ACTIVE_ZIP}, context.temp_allocator)
	if os.write_entire_file(target, zip) != nil { return false }
	name := strings.concatenate({directory, "/", MOD_ACTIVE_NAME}, context.temp_allocator)
	_ = os.write_entire_file(name, transmute([]byte)link)
	delete(g_mods.active)
	g_mods.active = strings.clone(link)
	return true
}

// Removes the loaded mod; call mods_init afterwards to use the game's files.
mods_remove :: proc() {
	directory := len(g_mods.directory) > 0 ? strings.clone(g_mods.directory, context.temp_allocator) : mods_directory(context.temp_allocator)
	mods_remove_files(directory)
	delete(g_mods.active)
	g_mods.active = ""
}

@(private = "file")
mods_remove_files :: proc(directory: string) {
	if !os.is_dir(directory) { return }
	_ = os.remove_all(strings.concatenate({directory, "/", MOD_UNPACK_DIR}, context.temp_allocator))
	_ = os.remove(strings.concatenate({directory, "/", MOD_ACTIVE_ZIP}, context.temp_allocator))
	_ = os.remove(strings.concatenate({directory, "/", MOD_ACTIVE_NAME}, context.temp_allocator))
}
