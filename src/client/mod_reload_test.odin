package main

import "base:runtime"
import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import gl "vendor:OpenGL"
import glfw "vendor:glfw"
import stbi "vendor:stb/image"
import shared "../shared"

// A stored (uncompressed) zip of the given files, enough for the mod loader.
@(private = "file")
test_zip :: proc(names: []string, contents: [][]byte) -> []byte {
	out: [dynamic]byte
	central: [dynamic]byte
	put16 :: proc(b: ^[dynamic]byte, v: int) { x: [2]byte; endian.put_u16(x[:], .Little, u16(v)); append(b, ..x[:]) }
	put32 :: proc(b: ^[dynamic]byte, v: int) { x: [4]byte; endian.put_u32(x[:], .Little, u32(v)); append(b, ..x[:]) }
	for name, i in names {
		data := contents[i]
		offset := len(out)
		put32(&out, 0x04034b50); put16(&out, 20); put16(&out, 0); put16(&out, 0); put16(&out, 0); put16(&out, 0)
		put32(&out, 0); put32(&out, len(data)); put32(&out, len(data)); put16(&out, len(name)); put16(&out, 0)
		append(&out, name); append(&out, ..data)
		put32(&central, 0x02014b50); put16(&central, 20); put16(&central, 20); put16(&central, 0); put16(&central, 0)
		put16(&central, 0); put16(&central, 0); put32(&central, 0); put32(&central, len(data)); put32(&central, len(data))
		put16(&central, len(name)); put16(&central, 0); put16(&central, 0); put16(&central, 0); put16(&central, 0)
		put32(&central, 0); put32(&central, offset); append(&central, name)
	}
	cd_offset := len(out)
	append(&out, ..central[:])
	put32(&out, 0x06054b50); put16(&out, 0); put16(&out, 0); put16(&out, len(names)); put16(&out, len(names))
	put32(&out, len(central)); put32(&out, cd_offset); put16(&out, 0)
	delete(central)
	return out[:]
}

@(private = "file")
test_png :: proc(path: string, size: i32) -> []byte {
	pixels := make([]u8, int(size*size*4), context.temp_allocator)
	for &p in pixels { p = 200 }
	stbi.write_png(strings.clone_to_cstring(path, context.temp_allocator), size, size, 4, &pixels[0], size*4)
	data, _ := os.read_entire_file_from_path(path, context.allocator)
	return data
}

// Loading and removing a mod swaps cached textures and models in place:
// same OpenGL texture id and same geometry, new contents, no restart.
@(test)
mods_apply_live_without_restart :: proc(t: ^testing.T) {
	context = runtime.default_context()
	if !testing.expect(t, bool(glfw.Init()), "GLFW initialization failed") do return
	defer glfw.Terminate()
	glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)
	glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
	glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
	glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 5)
	window := glfw.CreateWindow(64, 64, "Live mods", nil, nil)
	if !testing.expect(t, window != nil, "hidden OpenGL window failed") do return
	defer glfw.DestroyWindow(window)
	glfw.MakeContextCurrent(window)
	gl.load_up_to(4, 5, glfw.gl_set_proc_address)

	assets := shared.assets_path()
	texture_path := fmt.aprintf("%stextures/sr_live_mod_test.png", assets)
	model_path := fmt.aprintf("%smodels/sr_live_mod_test.obj", assets)
	defer { _ = os.remove(texture_path); _ = os.remove(model_path); delete(texture_path); delete(model_path) }
	original_png := test_png(texture_path, 4)
	defer delete(original_png)
	triangle := "v 0 0 0\nv 1 0 0\nv 0 1 0\nvt 0 0\nf 1/1 2/1 3/1\n"
	quad := "v 0 0 0\nv 1 0 0\nv 0 1 0\nv 1 1 0\nvt 0 0\nf 1/1 2/1 3/1\nf 2/1 4/1 3/1\n"
	_ = os.write_entire_file(model_path, transmute([]byte)triangle)

	shared.mods_init()
	defer { shared.mods_remove(); _ = os.remove_all(shared.g_mods.directory); shared.mods_shutdown() }
	client: Client
	texture := load_texture(texture_path)
	geometry := load_obj_model(model_path, false)
	if !testing.expect(t, texture != 0 && geometry != nil, "the test assets must load") do return
	entry := g_texture_by_id[texture]
	testing.expect_value(t, entry.width, i32(4))
	testing.expect_value(t, geometry.index_count, i32(3))

	scratch := fmt.aprintf("%stextures/sr_live_mod_scratch.png", assets)
	defer { _ = os.remove(scratch); delete(scratch) }
	mod_png := test_png(scratch, 8)
	defer delete(mod_png)
	zip := test_zip({"MyMod/textures/sr_live_mod_test.png", "MyMod/models/sr_live_mod_test.obj"}, {mod_png, transmute([]byte)quad})
	defer delete(zip)
	directory := strings.clone(shared.g_mods.directory)
	defer delete(directory)
	testing.expect_value(t, shared.mods_prepare(directory, zip, "https://example.invalid/mod.zip"), "")
	mods_reload_live(&client)
	testing.expect_value(t, g_texture_by_id[texture].width, i32(8))
	testing.expect_value(t, geometry.index_count, i32(6))
	testing.expect_value(t, load_texture(texture_path), texture) // same id
	testing.expect_value(t, shared.g_mods.active, "https://example.invalid/mod.zip")

	// Remove: the game's own files come back, still without a restart.
	snapshot := mod_snapshot_take(&client)
	shared.mods_remove()
	shared.mods_init()
	mod_snapshot_apply(&client, &snapshot)
	mod_snapshot_free(&snapshot)
	testing.expect_value(t, g_texture_by_id[texture].width, i32(4))
	testing.expect_value(t, geometry.index_count, i32(3))
}

// A mod's sound files replace SR's: a mod that blanks the hurt sound (an
// empty or undecodable takedmg file) makes getting shot silent, also when the
// mod is loaded while SR runs.
@(test)
mods_replace_sounds :: proc(t: ^testing.T) {
	context = runtime.default_context()
	audio := audio_create(nil, DEFAULT_AUDIO_SETTINGS, no_device = true)
	if audio == nil { return } // No audio backend on this machine.
	defer audio_destroy(audio)
	client: Client
	client.audio = audio
	shared.mods_init()
	defer { shared.mods_remove(); _ = os.remove_all(shared.g_mods.directory); shared.mods_shutdown() }
	path := fmt.tprintf("%ssound/takedmg_0.mp3", shared.assets_path())
	testing.expect(t, audio_play_effect(audio, "takedmg_0", .EFFECTS, 0.45), "the game's hurt sound plays without a mod")
	zip := test_zip({"Silent/Sound/takedmg_0.mp3", "Silent/sound/takedmg_1.mp3"}, {{}, {0, 1, 2, 3}})
	defer delete(zip)
	directory := strings.clone(shared.g_mods.directory)
	defer delete(directory)
	testing.expect_value(t, shared.mods_prepare(directory, zip, "https://example.invalid/silent.zip"), "")
	mods_reload_live(&client)
	testing.expect(t, shared.mod_resolve(path) != path, "the mod's takedmg_0 must replace the game's")
	testing.expect(t, !audio_play_effect(audio, "takedmg_0", .EFFECTS, 0.45), "a blank mod sound must be silent")
	testing.expect(t, !audio_play_effect(audio, "takedmg_1", .EFFECTS, 0.45), "a blank mod sound must be silent")
	client.audio = nil
}
