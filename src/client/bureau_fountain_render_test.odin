package main

import "base:runtime"
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
	FT_W :: 640
	FT_H :: 360

	@(private = "file")
	fountain_frame :: proc(client: ^Client, pixels: []u8) {
		gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
		gl.Viewport(0, 0, FT_W, FT_H)
		client_render_world(client)
		gl.PixelStorei(gl.PACK_ALIGNMENT, 1)
		ui_flush()
		gl.ReadPixels(0, 0, FT_W, FT_H, gl.RGB, gl.UNSIGNED_BYTE, raw_data(pixels))
	}

	// Bureau's fountain through the game's own frame path. Its top is two
	// SPHERE prefabs, which Krunker generates (addSphere -> generateSphere);
	// they must draw with the map's texture, filling their boxes. The frame is
	// written to bin/map-fixes/ (SR_SHOT_TAG names it, "after" by default).
	@(test)
	bureau_fountain_spheres_render :: proc(t: ^testing.T) {
		logger := context.logger
		context = runtime.default_context()
		context.logger = logger
		if !testing.expect(t, bool(glfw.Init())) do return
		defer glfw.Terminate()
		glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)
		glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 5)
		window := glfw.CreateWindow(FT_W, FT_H, "Bureau fountain", nil, nil)
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
		client.viewport_width, client.viewport_height = FT_W, FT_H
		client.visual_settings, client.quality_settings = menuui.DEFAULT_VISUAL_SETTINGS, menuui.DEFAULT_QUALITY_SETTINGS
		client.viewmodel_settings = menuui.DEFAULT_VIEWMODEL_SETTINGS
		client_graphics_init(client)
		defer { client_graphics_fini(client); resource_cache_fini() }
		client.scene = scene_init()
		client.fps_scene = scene_init()
		defer { scene_fini(client.fps_scene); scene_fini(client.scene) }
		map_inst, ok := shared.map_load_from_file("assets/maps/bureau.json")
		if !testing.expect(t, ok && map_inst != nil, "frontier.json must load") do return
		defer shared.map_destroy(map_inst)
		maps := []^shared.Map{map_inst}
		shared.game_configure(&client.game, &config.game, maps, nil, config.weapons, config.classes)
		shared.game_init(&client.game, 0, -1, true)
		defer shared.game_destroy(&client.game)
		client_load_current_map(client)
		defer client_unload_map(client)

		// The fountain in Bureau's south-west courtyard: a tile basin, a
		// translucent water cube and a column topped by two SPHERE prefabs
		// (objects 208 and 207) under a tile plate.
		spheres: [dynamic]^shared.Object
		defer delete(spheres)
		for object in map_inst.objects {
			if object.prefab == .SPHERE && abs(object.position.x + 219) < 1 && abs(object.position.z + 144) < 1 {
				append(&spheres, object)
			}
		}
		if !testing.expectf(t, len(spheres) == 2, "the Bureau fountain has two spheres, found %d", len(spheres)) do return

		pixels := make([]u8, FT_W * FT_H * 3)
		without := make([]u8, len(pixels))
		defer { delete(pixels); delete(without) }

		// Above the basin rim, looking at the column.
		client.camera.position, client.camera.rotation = {-219, 27, -127}, {-0.15, 0, 0}
		for _ in 0 ..< 2 { fountain_frame(client, pixels) }
		stbi.write_png(fmt.ctprintf("bin/map-fixes/bureau_fountain_%s.png", tag), FT_W, FT_H, 3, &pixels[(FT_H - 1) * FT_W * 3], -FT_W * 3)

		for object in spheres {
			if !testing.expectf(t, object.mesh != nil, "the fountain sphere at %v must have a mesh", object.position) do continue
			mesh := cast(^Mesh)object.mesh
			material := cast(^Basic_Material)mesh.material
			testing.expect(t, mesh.geometry == g_sphere_geometry && mesh.visible, "fountain spheres use Krunker's generated sphere")
			testing.expectf(t, mesh.transform.position == object.position && mesh.transform.scale == object.scale,
				"the sphere at %v must fill its box %v (got %v, %v)", object.position, object.scale, mesh.transform.position, mesh.transform.scale)
			// No `t` and tv=1: Krunker's WALL texture, variant 1 (wall_0_1).
			width: i32
			gl.BindTexture(gl.TEXTURE_2D, u32(material.texture))
			gl.GetTexLevelParameteriv(gl.TEXTURE_2D, 0, gl.TEXTURE_WIDTH, &width)
			testing.expectf(t, material.texture != 0 && width > 1, "the sphere at %v must use the map texture, not the white fallback", object.position)
			testing.expect(t, !material.base.transparent && material.color.w == 1, "fountain spheres are opaque")
		}
		testing.expect(t, object_sphere_collision_free(spheres[:]), "spheres are noCol in Krunker")

		// Sphere geometry: three.js SphereGeometry(1, 12, 8) in a unit box on y = 0.
		geometry := g_sphere_geometry
		if testing.expect(t, geometry != nil && geometry.index_count == 6 * SPHERE_WIDTH_SEGMENTS * (SPHERE_HEIGHT_SEGMENTS - 1), "sphere has 12x8 segments") {
			count := (SPHERE_WIDTH_SEGMENTS + 1) * (SPHERE_HEIGHT_SEGMENTS + 1)
			vertices := geometry.vertices
			testing.expect_value(t, len(vertices), count)
			lo, hi := shared.Vec3{1e9, 1e9, 1e9}, shared.Vec3{-1e9, -1e9, -1e9}
			for vertex in vertices {
				lo = {min(lo.x, vertex.position.x), min(lo.y, vertex.position.y), min(lo.z, vertex.position.z)}
				hi = {max(hi.x, vertex.position.x), max(hi.y, vertex.position.y), max(hi.z, vertex.position.z)}
				radius := vertex.position - {0, 0.5, 0}
				testing.expect(t, abs(radius.x * radius.x + radius.y * radius.y + radius.z * radius.z - 0.25) < 1e-4, "sphere vertices lie on the sphere")
			}
			testing.expectf(t, abs(lo.y) < 1e-5 && abs(hi.y - 1) < 1e-5 && abs(lo.x + 0.5) < 1e-5 && abs(hi.x - 0.5) < 1e-5, "sphere bounds %v..%v", lo, hi)
		}

		// The spheres must visibly draw: hide them and compare.
		for object in spheres { if object.mesh != nil do (cast(^Mesh)object.mesh).visible = false }
		fountain_frame(client, without)
		for object in spheres { if object.mesh != nil do (cast(^Mesh)object.mesh).visible = true }
		fountain_frame(client, pixels)
		changed := 0
		for i := 0; i < len(pixels); i += 3 {
			if max(abs(int(pixels[i]) - int(without[i])), abs(int(pixels[i + 1]) - int(without[i + 1])), abs(int(pixels[i + 2]) - int(without[i + 2]))) > 8 do changed += 1
		}
		fmt.printfln("[fountain] spheres cover %d px", changed)
		testing.expectf(t, changed > 2000, "the fountain spheres must be drawn (%d px changed)", changed)
		testing.expect(t, gl.GetError() == gl.NO_ERROR, "Bureau must render without OpenGL errors")
		client_clear_players(client)
		free_all(context.temp_allocator)
	}

	@(private = "file")
	object_sphere_collision_free :: proc(objects: []^shared.Object) -> bool {
		for object in objects { if object.collision_type != .NONE do return false }
		return true
	}
}
