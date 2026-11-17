package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:testing"
import gl "vendor:OpenGL"
import glfw "vendor:glfw"
import menuui "../menu"
import shared "../shared"

when ODIN_TEST {
	SHADING_BASELINE_PATH :: "src/client/testdata/shading_baseline_burg.rgb"
	SHADING_BASELINE_W :: 256
	SHADING_BASELINE_H :: 144

	// Two Burg views rendered side by side into one RGB image (bottom-up rows).
	shading_baseline_capture :: proc(client: ^Client) -> []u8 {
		w, h := i32(SHADING_BASELINE_W), i32(SHADING_BASELINE_H)
		pixels := make([]u8, int(w*h*3*2))
		views := [2][2]shared.Vec3{
			{{-90, 220, 180}, {-0.48, -0.1, 0}},
			{{40, 30, -60}, {-0.12, 2.4, 0}},
		}
		for view, i in views {
			camera := camera_init(DEFAULT_WEAPON_FOV)
			camera.position, camera.rotation = view[0], view[1]
			gl.Viewport(0, 0, w, h)
			ui_flush()
			gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
			scene_render(client.scene, &camera, f32(w), f32(h))
			ui_flush()
			gl.ReadPixels(0, 0, w, h, gl.RGB, gl.UNSIGNED_BYTE, raw_data(pixels[int(w*h*3)*i:]))
		}
		return pixels
	}

	shading_baseline_setup :: proc(t: ^testing.T, client: ^Client) -> (window: glfw.WindowHandle, ok: bool) {
		glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)
		glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 5)
		window = glfw.CreateWindow(SHADING_BASELINE_W, SHADING_BASELINE_H, "Shading baseline", nil, nil)
		if !testing.expect(t, window != nil) do return nil, false
		glfw.MakeContextCurrent(window)
		gl.load_up_to(4, 5, glfw.gl_set_proc_address)
		gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
		client.scene = scene_init()
		map_inst, map_ok := shared.map_load_from_file("assets/maps/burg.json")
		if !testing.expect(t, map_ok && map_inst != nil) do return window, false
		client.game.map_inst = map_inst
		client_load_current_map(client)
		return window, true
	}

	// The Krunker "Shadows" and "Lighting" settings must cost nothing and change
	// nothing when Shadows is off and Lighting is Normal: this compares the
	// frame against one captured from the renderer before those settings
	// existed. Build with -define:SHADING_BASELINE_WRITE=true to recapture.
	@(test)
	shading_off_matches_pre_shadow_baseline :: proc(t: ^testing.T) {
		context = runtime.default_context()
		if !testing.expect(t, bool(glfw.Init())) do return
		defer glfw.Terminate()
		client := Client{}
		g_client = &client
		old_lighting := g_lighting_config
		window, ok := shading_baseline_setup(t, &client)
		defer {
			client_unload_map(&client)
			if client.game.map_inst != nil { shared.map_destroy(client.game.map_inst) }
			if client.scene != nil { scene_fini(client.scene) }
			resource_cache_fini()
			g_client = nil
			g_lighting_config = old_lighting
			if window != nil { glfw.DestroyWindow(window) }
		}
		if !ok do return
		// The frame goes through the per-frame shadow step exactly as the client
		// does, with Shadows off and Lighting Normal.
		defer shadow_fini()
		renders := g_shadow.renders
		shadow_prepare(client.scene, client.game.map_inst, menuui.Quality_Settings{lighting = i32(menuui.Lighting_Quality.NORMAL)})
		testing.expect(t, g_shadow.renders == renders && g_shadow.texture == 0 && g_render_quality == Render_Quality{lighting = .NORMAL},
			"Shadows off must not allocate or render a shadow map")
		pixels := shading_baseline_capture(&client)
		defer delete(pixels)
		when #config(SHADING_BASELINE_WRITE, false) {
			os.make_directory("src/client/testdata")
			testing.expect(t, os.write_entire_file(SHADING_BASELINE_PATH, pixels) == nil, "could not write the shading baseline")
		} else {
			golden, err := os.read_entire_file_from_path(SHADING_BASELINE_PATH, context.allocator)
			if !testing.expect(t, err == nil && len(golden) == len(pixels), "missing shading baseline image") do return
			defer delete(golden)
			// Allow driver rounding noise only; any lighting change moves far more.
			differing, worst := 0, 0
			for value, i in pixels {
				diff := abs(int(value) - int(golden[i]))
				worst = max(worst, diff)
				if diff > 1 { differing += 1 }
			}
			testing.expect(t, differing == 0, fmt.tprintf("Shadows off and Lighting Normal must match the pre-shadow renderer (%d channels differ, worst %d)", differing, worst))
			// Krunker's default (Shadows on) must visibly change Burg.
			shadow_prepare(client.scene, client.game.map_inst, menuui.DEFAULT_QUALITY_SETTINGS)
			testing.expect(t, g_shadow.renders == renders + 1 && g_render_quality.shadows, "Shadows on must render Burg's shadow map once")
			shadowed := shading_baseline_capture(&client)
			defer delete(shadowed)
			changed := 0
			for value, i in shadowed { if abs(int(value) - int(golden[i])) > 8 { changed += 1 } }
			testing.expect(t, changed > 1000, fmt.tprintf("Shadows on must darken parts of Burg (%d channels changed)", changed))
			shadow_release_map()
			testing.expect(t, g_shadow.texture == 0 && g_shadow.fbos[0] == 0 && g_shadow.player_texture == 0, "unloading must free the shadow map")
		}
		testing.expect(t, gl.GetError() == gl.NO_ERROR)
	}
}
