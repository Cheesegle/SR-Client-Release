package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:testing"
import gl "vendor:OpenGL"
import glfw "vendor:glfw"
import shared "../shared"
import menuui "../menu"

when ODIN_TEST {
	@(test)
	scope_image_and_current_undergrowth_render :: proc(t: ^testing.T) {
		// Keep the runner's logger: testing.expect fails a test by logging.
		logger := context.logger
		context = runtime.default_context()
		context.logger = logger
		if !testing.expect(t, bool(glfw.Init())) do return
		defer glfw.Terminate()
		test_gpu := test_gpu_open(1280, 720, "Scope and Undergrowth")
		if !testing.expect(t, test_gpu.ok, "no GPU device for the test") do return
		defer test_gpu_close(&test_gpu, t)
		g_test_gpu = &test_gpu
		window := test_gpu.window
		ui := ui_init()
		client := Client{scene = scene_init(), ui = ui}
		g_client = &client
		old_lighting := g_lighting_config
		defer {
			client_unload_map(&client)
			shared.map_destroy(client.game.map_inst)
			scene_fini(client.scene)
			overlay_fini()
			ui_fini(ui)
			resource_cache_fini()
			g_client = nil
			g_lighting_config = old_lighting
		}
		map_inst, ok := shared.map_load_from_file("assets/maps/undergrowth.json")
		if !testing.expect(t, ok && map_inst != nil) do return
		client.game.map_inst = map_inst
		testing.expect(t, len(map_inst.objects) == 1371, "Undergrowth must use the current captured map")
		testing.expect(t, map_inst.objects[0].position == (shared.Vec3{-179, 67, 54}) && map_inst.objects[0].scale == (shared.Vec3{232, 2, 190}), "current map position and interned dimensions must load")
		client_load_current_map(&client)
		custom_meshes := 0
		for object in map_inst.objects {
			if object.mesh == nil { continue }
			mesh := cast(^Mesh)object.mesh
			if mesh.geometry != nil && len(mesh.geometry.cache_key) > 0 {
				if (cast(^Basic_Material)mesh.material).texture != 0 && object.prefab == .CUSTOM_ASSET { custom_meshes += 1 }
			}
		}
		testing.expect(t, custom_meshes == 16, "all current Undergrowth custom models must have textures")
		camera := camera_init(DEFAULT_WEAPON_FOV)
		camera.position = {60, 115, 210}
		camera.rotation = {-0.12, 0.3, 0}
		for dimensions in ([][2]i32{{1280, 720}, {1920, 1080}, {2560, 1600}}) {
			w, h := dimensions[0], dimensions[1]
			test_gpu_resize(w, h)
			gpu_set_target(test_gpu_current_target(), w, h)
			gpu_clear(color = true, depth = true)
			scene_render(client.scene, &camera, f32(w), f32(h))
			ui_update(ui, f32(w), f32(h))
			hud: menuui.HUD_Settings
			testing.expect(t, menuui.scope_value(hud, 0) == 0 && !hud.scope_borders, "SR hides the scope image and borders by default")
			menuui.scope_value_set(&hud, 0, 1)
			hud.scope_borders = true
			overlay_scope_render(ui, hud)
			testing.expect(t, scope_icon != 0, "the packaged default scope image must load")
			pixel: [3]u8
			test_read_rgb(0, h/2, 1, 1, &pixel[0])
			testing.expect(t, pixel == ([3]u8{}), "scope borders must mask the sides on wide screens")
			test_read_rgb(w/2, h/2, 1, 1, &pixel[0])
			testing.expect(t, pixel[0] < 20 && pixel[1] < 20 && pixel[2] < 20, "scope reticle must stay centered")
			testing.expect(t, test_gpu_no_error(), "map and scope must render without OpenGL errors")
			when #config(WEAPON_PREVIEW, false) {
				pixels := make([]u8, int(w*h*3))
				test_read_rgb(0, 0, w, h, raw_data(pixels))
				file := make([dynamic]u8)
				append(&file, ..transmute([]u8)fmt.tprintf("P6\n%d %d\n255\n", w, h))
				for row := h-1; row >= 0; row -= 1 { append(&file, ..pixels[row*w*3:(row+1)*w*3]) }
				testing.expect(t, os.write_entire_file(fmt.tprintf("bin/undergrowth_scope_%d.ppm", w), file[:]) == nil)
				delete(file)
				delete(pixels)
			}
		}
	}
}
