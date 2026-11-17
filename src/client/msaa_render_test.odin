package main

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:os"
import "core:testing"
import glfw "vendor:glfw"
import menuui "../menu"

when ODIN_TEST {
	@(test)
	msaa_settings_validate_and_migrate :: proc(t: ^testing.T) {
		for value in ([?]i32{-1, 1, 3, 16}) {
			testing.expectf(t, menuui.quality_settings_validate({msaa = value}).msaa == 0, "MSAA %d must fall back to off", value)
		}
		for value in menuui.MSAA_LEVELS { testing.expect(t, menuui.quality_settings_validate({msaa = value}).msaa == value) }
		testing.expect(t, client_supported_quality({msaa = 8}, 16, 4).msaa == 4 && client_supported_quality({msaa = 8}, 16, 1).msaa == 0,
			"MSAA choices must respect the GPU's sample counts")

		path := "bin/client-settings-msaa-test.json"
		defer os.remove(path)
		// The pre-0.26 on/off setting becomes 4x.
		testing.expect(t, os.write_entire_file(path, `{"version":1,"hud":{"anti_alias":true}}`) == nil)
		migrated := client_settings_load(path)
		testing.expect(t, migrated.quality.msaa == 4 && !migrated.hud.anti_alias, fmt.tprintf("anti_alias must migrate to 4x MSAA: %v", migrated.quality.msaa))
		settings := client_settings_defaults()
		settings.quality.msaa = 8
		testing.expect(t, client_settings_save(settings, path))
		testing.expect(t, client_settings_load(path).quality.msaa == 8, "the MSAA level must survive a restart")
	}

	// A rotated box on a dark background, drawn single-sampled and with 4x
	// MSAA: only pixels along its edges may differ, and some must.
	@(test)
	msaa_smooths_world_edges_only :: proc(t: ^testing.T) {
		logger := context.logger
		context = runtime.default_context()
		context.logger = logger
		if !testing.expect(t, bool(glfw.Init())) do return
		defer glfw.Terminate()
		W, H :: 128, 128
		test_gpu := test_gpu_open(W, H, "MSAA")
		if !testing.expect(t, test_gpu.ok, "no GPU device for the test") do return
		defer test_gpu_close(&test_gpu, t)
		g_test_gpu = &test_gpu
		if gpu_max_msaa_samples() < 4 { fmt.println("[msaa] the GPU has no 4x MSAA; skipped"); return }

		scene := scene_init()
		material := basic_material_init()
		material.no_fog = true
		box := mesh_init(create_cube_geo(), &material.base)
		box.transform.position, box.transform.scale = {0, -2, -8}, {4, 4, 4}
		box.transform.rotation = {0.3, 0.6, 0.2}
		scene_add_mesh(scene, box)
		defer {
			mesh_fini(box)
			scene_fini(scene)
			resource_cache_fini()
		}
		camera := camera_init(math.PI / 2)

		render :: proc(target: Gpu_Render_Target, scene: ^Scene, camera: ^Camera) {
			gpu_set_target(target, W, H)
			gpu_set_clear_color({0, 0, 0})
			gpu_clear(color = true, depth = true)
			scene_render(scene, camera, W, H)
		}
		single := make([]u8, W*H*3)
		resolved := make([]u8, W*H*3)
		defer { delete(single); delete(resolved) }
		render(test_gpu_current_target(), scene, &camera)
		test_read_rgb(0, 0, W, H, raw_data(single))

		msaa := gpu_render_target_create_msaa(W, H, 4)
		defer gpu_render_target_destroy(&msaa)
		if !testing.expect(t, msaa != 0, "the MSAA target must be created") do return
		render(msaa, scene, &camera)
		gpu_resolve(msaa, test_gpu_current_target(), W, H)
		gpu_set_target(test_gpu_current_target(), W, H)
		test_read_rgb(0, 0, W, H, raw_data(resolved))

		lit, differ, interior := 0, 0, 0
		for y in 1 ..< H-1 {
			for x in 1 ..< W-1 {
				i := (y*W + x) * 3
				if single[i] + single[i+1] + single[i+2] > 0 { lit += 1 }
				d := abs(int(single[i]) - int(resolved[i])) + abs(int(single[i+1]) - int(resolved[i+1])) + abs(int(single[i+2]) - int(resolved[i+2]))
				if d <= 3 { continue }
				differ += 1
				// An edge pixel has a neighbour of another colour in the
				// single-sampled image.
				edge := false
				for n in ([4]int{-3, 3, -W*3, W*3}) {
					j := i + n
					if abs(int(single[j]) - int(single[i])) + abs(int(single[j+1]) - int(single[i+1])) + abs(int(single[j+2]) - int(single[i+2])) > 3 { edge = true }
				}
				if !edge { interior += 1 }
			}
		}
		testing.expect(t, lit > 1000, fmt.tprintf("the box must be visible (%d lit pixels)", lit))
		testing.expect(t, differ > 40, fmt.tprintf("4x MSAA must change the box's edge pixels (%d changed)", differ))
		testing.expect(t, interior * 10 <= differ, fmt.tprintf("MSAA must only change edges (%d of %d changed pixels are inside faces)", interior, differ))
	}
}
