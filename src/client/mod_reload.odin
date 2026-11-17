package main

import "core:fmt"
import "core:strings"
import gl "vendor:OpenGL"
import stbi "vendor:stb/image"
import ma "vendor:miniaudio"
import shared "../shared"

// Live mod switching, like Krunker: after a mod is loaded or removed the mod
// index is rebuilt and every cached texture, model and sound whose file
// changed is reloaded in place. Textures keep their OpenGL id and models keep
// their buffers, so everything that already uses them (map, weapons, HUD)
// shows the new files on the next frame without a restart.

Mod_Snapshot :: struct {
	textures, geometries, sounds: map[string]string, // cache key -> file it was loaded from
}

@(private = "file")
mod_snapshot_add :: proc(into: ^map[string]string, key: string) {
	into[key] = strings.clone(shared.mod_resolve(key))
}

mod_snapshot_take :: proc(client: ^Client) -> Mod_Snapshot {
	snapshot: Mod_Snapshot
	for key in g_texture_cache { mod_snapshot_add(&snapshot.textures, key) }
	for key in g_geometry_cache { mod_snapshot_add(&snapshot.geometries, key) }
	if client.audio != nil { for key in client.audio.samples { mod_snapshot_add(&snapshot.sounds, key) } }
	return snapshot
}

mod_snapshot_free :: proc(snapshot: ^Mod_Snapshot) {
	for _, value in snapshot.textures { delete(value) }
	for _, value in snapshot.geometries { delete(value) }
	for _, value in snapshot.sounds { delete(value) }
	delete(snapshot.textures); delete(snapshot.geometries); delete(snapshot.sounds)
	snapshot^ = {}
}

// Reloads what resolves to a different file than when the snapshot was taken.
// Returns how many files were swapped.
mod_snapshot_apply :: proc(client: ^Client, snapshot: ^Mod_Snapshot) -> int {
	changed := 0
	for key, old in snapshot.textures {
		if shared.mod_resolve(key) == old { continue }
		if entry, ok := g_texture_cache[key]; ok && texture_reload_in_place(entry) { changed += 1 }
	}
	for key, old in snapshot.geometries {
		if shared.mod_resolve(key) == old { continue }
		if geometry, ok := g_geometry_cache[key]; ok && geometry_reload_in_place(geometry) { changed += 1 }
	}
	if client.audio != nil {
		for key, old in snapshot.sounds {
			if shared.mod_resolve(key) == old { continue }
			if sample, ok := client.audio.samples[key]; ok && audio_reload_sample(client.audio, key, sample) { changed += 1 }
		}
	}
	return changed
}

// Rebuilds the mod index and swaps the changed files. Cheap when nothing changed.
mods_reload_live :: proc(client: ^Client) -> int {
	snapshot := mod_snapshot_take(client)
	defer mod_snapshot_free(&snapshot)
	shared.mods_init()
	changed := mod_snapshot_apply(client, &snapshot)
	fmt.printfln("[Mods] live reload: %d files swapped", changed)
	return changed
}

texture_reload_in_place :: proc(entry: ^Texture_Cache_Entry) -> bool {
	c_path := strings.clone_to_cstring(shared.mod_resolve(entry.cache_key))
	defer delete(c_path)
	stbi.set_flip_vertically_on_load(1)
	w, h, channels: i32
	data := stbi.load(c_path, &w, &h, &channels, 4)
	if data == nil { return false }
	defer stbi.image_free(data)
	// Same handle, so everything using it shows the new pixels. A different
	// size cannot be swapped in place on every backend: it applies on restart.
	if w != entry.width || h != entry.height { return false }
	gpu_texture_update(entry.id, .RGBA8, 0, 0, w, h, data[:int(w)*int(h)*4])
	return true
}

geometry_reload_in_place :: proc(geometry: ^Geometry) -> bool {
	obj_data, ok := shared.read_file(geometry.cache_key)
	if !ok { return false }
	defer delete(obj_data)
	vertices := parse_obj(obj_data, geometry.transform_y)
	if vertices == nil || len(vertices) == 0 { delete(vertices); return false }
	defer delete(vertices)
	indices := make([]u32, len(vertices))
	defer delete(indices)
	for i in 0..<len(vertices) { indices[i] = u32(i) }
	// New buffers behind the same ^Geometry, so every mesh using it updates.
	fresh := create_geometry(vertices[:], indices[:])
	gpu_vertex_input_destroy(&geometry.input)
	gpu_buffer_destroy(&geometry.vertex_buffer)
	gpu_buffer_destroy(&geometry.index_buffer)
	delete(geometry.vertices)
	delete(geometry.indices)
	geometry.input, geometry.vertex_buffer, geometry.index_buffer = fresh.input, fresh.vertex_buffer, fresh.index_buffer
	geometry.vertices, geometry.indices, geometry.index_count = fresh.vertices, fresh.indices, fresh.index_count
	geometry.bounds_min, geometry.bounds_max, geometry.has_bounds = fresh.bounds_min, fresh.bounds_max, fresh.has_bounds
	free(fresh)
	return true
}

// Stops voices that play the sample, then decodes the new file into it.
audio_reload_sample :: proc(audio: ^Audio_System, path: string, sample: ^Audio_Sample) -> bool {
	for &voice in audio.voices {
		if voice.sample == sample { ma.sound_uninit(&voice.sound); voice.sample = nil }
	}
	if sample.ready { ma.sound_uninit(&sample.sound) }
	cpath := strings.clone_to_cstring(shared.mod_resolve(path))
	defer delete(cpath)
	sample.ready = ma.sound_init_from_file(&audio.engine, cpath, {.DECODE}, nil, nil, &sample.sound) == .SUCCESS
	return sample.ready
}
