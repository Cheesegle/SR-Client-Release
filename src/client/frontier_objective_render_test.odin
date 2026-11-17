package main

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:testing"
import gl "vendor:OpenGL"
import glfw "vendor:glfw"
import stbi "vendor:stb/image"
import menuui "../menu"
import shared "../shared"

when ODIN_TEST {
	SITE_W :: 640
	SITE_H :: 360

	@(private = "file")
	site_frame :: proc(client: ^Client, pixels: []u8) {
		gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
		gl.Viewport(0, 0, SITE_W, SITE_H)
		client_update_objective_visuals(client)
		client_render_world(client)
		gl.PixelStorei(gl.PACK_ALIGNMENT, 1)
		ui_flush()
		gl.ReadPixels(0, 0, SITE_W, SITE_H, gl.RGB, gl.UNSIGNED_BYTE, raw_data(pixels))
	}

	// Frontier's hardpoint sites through the game's own frame path: for each
	// uid in rotation order, the one visible marker is the capture volume of
	// that uid (same footprint, Krunker's five-unit perimeter at its floor),
	// and it draws where that volume is on screen. Frames are written to
	// bin/map-fixes/ (SR_SHOT_TAG names them, "after" by default).
	@(test)
	frontier_objective_markers_match_capture_volumes :: proc(t: ^testing.T) {
		logger := context.logger
		context = runtime.default_context()
		context.logger = logger
		if !testing.expect(t, bool(glfw.Init())) do return
		defer glfw.Terminate()
		glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)
		glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 5)
		window := glfw.CreateWindow(SITE_W, SITE_H, "Frontier sites", nil, nil)
		if !testing.expect(t, window != nil) do return
		defer glfw.DestroyWindow(window)
		glfw.MakeContextCurrent(window)
		gl.load_up_to(4, 5, glfw.gl_set_proc_address)
		gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
		os.make_directory("bin/map-fixes")
		tag := os.get_env("SR_SHOT_TAG", context.temp_allocator)
		if tag == "" do tag = "after"

		defer shadow_fini()
		config := shared.config_load_gameplay("assets/config/game.toml")
		defer shared.config_destroy_gameplay(config)

		client := new(Client)
		g_client = client
		defer { free(client); g_client = nil }
		client.render_batching = true
		client.camera = camera_init(menuui.DEFAULT_FOV * math.PI / 180)
		client.camera.near, client.camera.far = 0.1, 10000
		client.viewport_width, client.viewport_height = SITE_W, SITE_H
		client.visual_settings, client.quality_settings = menuui.DEFAULT_VISUAL_SETTINGS, menuui.DEFAULT_QUALITY_SETTINGS
		client.viewmodel_settings = menuui.DEFAULT_VIEWMODEL_SETTINGS
		client_graphics_init(client)
		defer { client_graphics_fini(client); resource_cache_fini() }
		client.scene = scene_init()
		client.fps_scene = scene_init()
		defer { scene_fini(client.fps_scene); scene_fini(client.scene) }
		map_inst, ok := shared.map_load_from_file("assets/maps/frontier.json")
		if !testing.expect(t, ok && map_inst != nil, "frontier.json must load") do return
		defer shared.map_destroy(map_inst)
		maps := []^shared.Map{map_inst}
		shared.game_configure(&client.game, &config.game, maps, nil, config.weapons, config.classes)
		shared.game_init(&client.game, 0, -1, true)
		defer shared.game_destroy(&client.game)
		client_load_current_map(client)
		defer client_unload_map(client)

		if !testing.expect(t, len(client.game.objective_indices) == 4, "Frontier has four sites") do return

		pixels := make([]u8, SITE_W * SITE_H * 3)
		defer delete(pixels)

		for step in 0 ..< 4 {
			state := &client.game.match.objective
			uid := state.active_zone
			testing.expectf(t, uid == i32(step), "rotation step %d must be on uid %d, got %d", step, step, uid)
			client_update_objective_visuals(client)

			// The site that should be active at this step: Krunker rotates
			// uid 0, 1, 2, 3 and uid is obi - 1 from the JSON.
			want: ^shared.Object
			for object in map_inst.objects {
				raw, is_object := object.raw_data.(json.Object)
				if object.objective && is_object && i32(shared.get_json_f32(raw["obi"])) - 1 == i32(step) do want = object
			}
			if !testing.expectf(t, want != nil, "no site has obi %d", step + 1) do return
			testing.expectf(t, want.objective_id == uid, "the site authored obi=%d at %v has uid %d", step + 1, want.position, want.objective_id)

			visible := 0
			for object in map_inst.objects {
				if !object.objective || object.mesh == nil do continue
				mesh := cast(^Mesh)object.mesh
				if !mesh.visible do continue
				visible += 1
				testing.expectf(t, object == want, "uid %d shows the marker of the site at %v instead of %v", uid, object.position, want.position)
				testing.expectf(t, mesh.transform.position == object.position && mesh.transform.scale == shared.Vec3{object.scale.x, 5, object.scale.z},
					"uid %d marker at %v size %v must cover the capture volume at %v size %v", uid, mesh.transform.position, mesh.transform.scale, object.position, object.scale)
			}
			testing.expectf(t, visible == 1, "uid %d: exactly one marker must be visible, got %d", uid, visible)

			// Marker alone (no world to occlude it), seen from straight above:
			// its pixels must fill the capture volume's projected footprint.
			marker_only := scene_init()
			for object in map_inst.objects {
				if object.objective && object.mesh != nil do scene_add_mesh(marker_only, cast(^Mesh)object.mesh)
			}
			top := camera_init(math.PI / 2)
			top.position = want.position + {0, 150, 0}
			top.rotation = {-math.PI / 2, 0, 0}
			camera_update_projection_matrix(&top, f32(SITE_W) / f32(SITE_H))
			camera_update_world_inverse_matrix(&top)
			gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
			gl.Viewport(0, 0, SITE_W, SITE_H)
			gl.ClearColor(0, 0, 0, 1)
			ui_flush()
			gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
			scene_render(marker_only, &top, SITE_W, SITE_H)
			gl.PixelStorei(gl.PACK_ALIGNMENT, 1)
			ui_flush()
			gl.ReadPixels(0, 0, SITE_W, SITE_H, gl.RGB, gl.UNSIGNED_BYTE, raw_data(pixels))
			scene_fini(marker_only)
			lo := [2]f32{SITE_W, SITE_H}
			hi := [2]f32{0, 0}
			for corner in 0 ..< 8 {
				p := want.position + {
					(corner & 1 == 0 ? -0.5 : 0.5) * want.scale.x,
					corner & 2 == 0 ? 0 : 5,
					(corner & 4 == 0 ? -0.5 : 0.5) * want.scale.z,
				}
				clip := top.projection_matrix * top.world_inverse_matrix * [4]f32{p.x, p.y, p.z, 1}
				screen := [2]f32{(clip.x / clip.w * 0.5 + 0.5) * SITE_W, (clip.y / clip.w * 0.5 + 0.5) * SITE_H}
				lo, hi = {min(lo.x, screen.x), min(lo.y, screen.y)}, {max(hi.x, screen.x), max(hi.y, screen.y)}
			}
			inside, outside := 0, 0
			marker_lo := [2]f32{SITE_W, SITE_H}
			marker_hi := [2]f32{0, 0}
			for y in 0 ..< SITE_H {
				for x in 0 ..< SITE_W {
					i := (y * SITE_W + x) * 3
					if max(pixels[i], pixels[i + 1], pixels[i + 2]) <= 8 do continue
					px := [2]f32{f32(x) + 0.5, f32(y) + 0.5}
					marker_lo, marker_hi = {min(marker_lo.x, px.x), min(marker_lo.y, px.y)}, {max(marker_hi.x, px.x), max(marker_hi.y, px.y)}
					if px.x >= lo.x - 1 && px.x <= hi.x + 1 && px.y >= lo.y - 1 && px.y <= hi.y + 1 { inside += 1 } else { outside += 1 }
				}
			}
			fmt.printfln("[sites] uid %d site %v: marker %v..%v, capture volume %v..%v (%d px inside, %d outside)", uid, want.position, marker_lo, marker_hi, lo, hi, inside, outside)
			testing.expectf(t, inside > 200 && outside == 0, "uid %d: the marker must be drawn inside the capture footprint (%d inside, %d outside)", uid, inside, outside)
			testing.expectf(t, abs(marker_lo.x - lo.x) < 3 && abs(marker_hi.x - hi.x) < 3 && abs(marker_lo.y - lo.y) < 3 && abs(marker_hi.y - hi.y) < 3,
				"uid %d: the marker %v..%v must span the capture footprint %v..%v", uid, marker_lo, marker_hi, lo, hi)

			// In the world, from the site's +z edge: written for checking by eye.
			client.camera.position = want.position + {0, 16, want.scale.z * 0.5 - 2}
			client.camera.rotation = {-0.45, 0, 0}
			for _ in 0 ..< 2 { site_frame(client, pixels) }
			stbi.write_png(fmt.ctprintf("bin/map-fixes/frontier_site_uid%d_%s.png", uid, tag), SITE_W, SITE_H, 3, &pixels[(SITE_H - 1) * SITE_W * 3], -SITE_W * 3)

			shared.game_rotate_objective(&client.game)
		}
		testing.expect(t, gl.GetError() == gl.NO_ERROR, "Frontier sites must render without OpenGL errors")
		client_clear_players(client)
		free_all(context.temp_allocator)
	}
}
