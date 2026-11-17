package main

import "core:encoding/json"
import "core:math"
import "core:math/linalg"
import "core:strings"
import gl "vendor:OpenGL"
import glfw "vendor:glfw"
import menuui "../menu"
import shared "../shared"

// Krunker's "Shadows" and "Lighting" settings, reproduced from Krunker's client
// .
//
// Shadows (settings list, renderer):
//   * One shadow-casting light: the map's sky light, a THREE.DirectionalLight
//     placed at lightD along the sun angles and aimed at the world origin
//     (sceneInit). Its shadow camera is orthographic with
//     left/right = -/+shadWidth and bottom/top = -/+shadLength, computed once
//     from the extent of the map's cubes. It does not
//     follow the player.
//   * mapSize = shadowR (default 1024), or 4096 with High-Res Shadows. The
//     camera's far plane is shadowD (default 1200), bias -0.0004, normalBias
//     shadowNB clamped to 0..5.
//   * renderer.shadowMap.type is BasicShadowMap (one nearest depth compare),
//     or PCFShadowMap with Soft Shadows: five Vogel-disk taps rotated by
//     interleaved gradient noise, one texel radius, each a hardware 2x2
//     compare (lines 69376-69400 and 69566).
//   * shadow.autoUpdate = Dynamic Shadows. Off (the default), the map is
//     rendered into the shadow map only when the scene changes; on, every
//     frame. Players only cast with Dynamic Shadows (castShadow =
//     dynamicShadows); everything receives.
//   * The shadow pass draws back faces of single-sided materials
//     (shadowSide map), so front faces are culled here.
//
// Lighting (settings list, getMat):
//   0 Low      MeshBasicMaterial: unlit.
//   1 Normal   MeshLambertMaterial (the default): what SR Client already did.
//   2 High     MeshPhongMaterial (specular 0x111111, shininess 30), plus the
//              map's POINT_LIGHT and SPOT_LIGHT objects.
//   3 Physical MeshStandardMaterial (roughness 1, metalness 0), plus
//              DIRECTIONAL_LIGHT objects. RECTAREA_LIGHT objects are not
//              drawn here: no shipped map has one.
//   Map lights also need Krunker's Map Details setting, which defaults to on
//   and which SR Client does not have.

Shadow_Caster :: enum u8 {
	NONE,
	STATIC,  // Map geometry: always in the shadow map.
	DYNAMIC, // Players: only with Dynamic Shadows.
}

SHADOW_HIGH_RES :: 4096
SHADOW_BIAS :: -0.0004
SHADOW_NEAR :: 0.5 // THREE.DirectionalLightShadow camera default.
MAX_MAP_LIGHTS :: 16

// Raw prefab IDs (Krunker's object list, crate variants excluded).
PREFAB_POINT_LIGHT :: 53
PREFAB_DIRECTIONAL_LIGHT :: 65
PREFAB_RECTAREA_LIGHT :: 66
PREFAB_SPOT_LIGHT :: 67

Map_Light_Kind :: enum i32 { POINT, SPOT, DIRECTIONAL }

Map_Light :: struct {
	kind:          Map_Light_Kind,
	position:      shared.Vec3,
	target:        shared.Vec3,
	color:         shared.Vec3, // Already multiplied by intensity.
	distance:      f32,
	decay:         f32,
	cone_cos:      f32,
	penumbra_cos:  f32,
}

Render_Quality :: struct {
	shadows:         bool, // The sun's map(s) exist and receivers should sample them.
	soft_shadows:    bool,
	dynamic_shadows: bool,
	player_shadows:  bool, // The small player map was drawn this frame.
	lighting:        menuui.Lighting_Quality,
	mode:            menuui.Shadow_Quality,
}

// What scene_render uses for this frame. The default (no shadows, Normal
// lighting) is the renderer as it was before these settings, so code that
// renders without going through client_update_graphics is unchanged.
g_render_quality := Render_Quality{lighting = .NORMAL}

// SR Client's shadow maps.
//
// * Sun map(s): one 2D depth array. Krunker mode has a single layer: Krunker's
//   whole-map shadow camera, unchanged. Sharp mode has SHADOW_CASCADES layers,
//   each an orthographic square around a point near the camera. Static map
//   casters only; a layer is redrawn when the map changes or when the camera
//   leaves the middle of that cascade, never every frame.
// * Player map: a small separate map for players (Dynamic Shadows) and for
//   your own body (Self shadow), fitted every frame to the casters within
//   PLAYER_SHADOW_RADIUS of the camera. Receivers take the darker of the two
//   maps. The sun map is never copied or redrawn for moving casters.
SHADOW_CASCADES :: 3
CASCADE_SIZE :: 2048
// Cascade radii (world units; a player is 11 tall). The first covers the
// ground around you, the second a typical room or street, the last reaches
// the fog (clamped to CASCADE_FAR_MIN..CASCADE_FAR_MAX).
CASCADE_NEAR_RADIUS :: 40
CASCADE_MID_RADIUS :: 160
CASCADE_FAR_MIN :: 400
CASCADE_FAR_MAX :: 1000
// A cascade is redrawn when the camera has moved this fraction of its radius
// from the cascade's centre; until then it is reused as is.
CASCADE_RECENTER :: 0.25
PLAYER_SHADOW_SIZE :: 1024
// Players further than this from the camera do not cast. At 200 units a
// player is ~60 px tall at 1080p and 100 degrees FOV and their shadow is a
// few pixels wide; the radius keeps the map's texels small (the fitted square
// is at most 400 units across: under 0.4 units per texel, 3x finer than a
// 1024 map over a typical 1200-unit Krunker map).
PLAYER_SHADOW_RADIUS :: 200

Shadow_Cascade :: struct {
	valid:           bool,
	center:          shared.Vec3, // World point the cascade was fitted around.
	radius:          f32,
	cx, cy:          f32, // Light-space centre of the square (texel-snapped).
	view_projection: shared.Mat4,
	shadow_matrix:   shared.Mat4,
	bias:            f32, // In the layer's [0, 1] depth.
}

Shadow_State :: struct {
	program:          u32, // basic.vert/frag with SHADOW_DEPTH_PASS.
	uniforms:         Shader_Uniforms,
	batched_program:  u32, // The same with BATCHED, for the static map batches.
	batched_uniforms: Shader_Uniforms,
	// Sun map(s).
	texture:          u32, // DEPTH_COMPONENT24 2D array, `layers` layers.
	fbos:             [SHADOW_CASCADES]u32,
	layers:           int,
	size:             i32,
	soft:             bool,
	mode:             menuui.Shadow_Quality,
	cascades:         [SHADOW_CASCADES]Shadow_Cascade,
	light_key:        shared.Mat4, // Sun view; a change invalidates every layer.
	world_bias:       f32,         // Krunker's bias in world units.
	// Player map.
	player_fbo:       u32,
	player_texture:   u32,
	player_matrix:    shared.Mat4,
	player_bias:      f32,
	// Map data.
	map_inst:         ^shared.Map,
	half_width:       f32,
	half_length:      f32,
	map_lo, map_hi:   shared.Vec3, // Rough map bounds, for the cascades' depth range.
	lights:           [MAX_MAP_LIGHTS]Map_Light,
	light_count:      int,
	dirty:            bool,
	// Counters (tests, benchmark).
	renders:          int, // Sun-map layer renders.
	player_renders:   int, // Player-map renders.
	casters_drawn:    int, // Draw calls in the last player-map render.
}

g_shadow: Shadow_State
// Benchmark switch: Krunker mode with Sharp's cheaper 4-tap soft filter.
g_shadow_soft_kernel_override: bool
// Set by client_render_world around the viewmodel pass: the viewmodel keeps
// the sun's shadows but never samples the player map (no self-shadow acne).
g_shadow_viewmodel_pass: bool
// Extra player-map casters this frame (your body for Self shadow).
g_shadow_extra_casters: []^Mesh

json_truthy :: proc(value: json.Value) -> bool {
	#partial switch v in value {
	case json.Boolean: return bool(v)
	case json.Integer: return v != 0
	case json.Float: return v != 0
	case json.String: return len(v) > 0
	case json.Null: return false
	case json.Object, json.Array: return true
	}
	return false
}

// shadWidth/shadLength: the cube extent from the map loader, divided by 2.5
// and rounded (Krunker starts the min/max at zero and skips cubes with `l` or
// `col` set).
shadow_map_extent :: proc(map_inst: ^shared.Map) -> (half_width, half_length: f32) {
	min_x, max_x, min_z, max_z: f32
	for object in map_inst.objects {
		if object.prefab != .CUBE { continue }
		if raw, ok := object.raw_data.(json.Object); ok {
			if json_truthy(raw["l"]) || json_truthy(raw["col"]) { continue }
		}
		min_x = min(min_x, object.position.x - object.scale.x)
		max_x = max(max_x, object.position.x + object.scale.x)
		min_z = min(min_z, object.position.z - object.scale.z)
		max_z = max(max_z, object.position.z + object.scale.z)
	}
	return math.round(abs(max_z - min_z) / 2.5), math.round(abs(max_x - min_x) / 2.5)
}

@(private = "file")
shadow_object_color :: proc(map_inst: ^shared.Map, raw: json.Object) -> shared.Vec3 {
	color := shared.Vec4{242.0 / 255.0, 248.0 / 255.0, 252.0 / 255.0, 1} // "#f2f8fc"
	if hex, ok := raw["c"].(json.String); ok {
		shared.parse_hex_color(hex, &color)
	} else if index_value, has_index := raw["ci"]; has_index {
		index := int(shared.get_json_f32(index_value))
		if index >= 0 && index < len(map_inst.colors) { color = map_inst.colors[index] }
	}
	return {color.x, color.y, color.z}
}

@(private = "file")
shadow_json_f32 :: proc(raw: json.Object, key: string, fallback: f32) -> f32 {
	value, ok := raw[key]
	if !ok || !json_is_number(value) { return fallback }
	parsed := shared.get_json_f32(value)
	return parsed != 0 ? parsed : fallback // Krunker: parseFloat(x) || default.
}

// Map light objects (map loader; clamps).
map_lights_collect :: proc(map_inst: ^shared.Map, lights: ^[MAX_MAP_LIGHTS]Map_Light) -> int {
	count := 0
	for object in map_inst.objects {
		if count >= MAX_MAP_LIGHTS { break }
		id := int(object.prefab)
		if id != PREFAB_POINT_LIGHT && id != PREFAB_SPOT_LIGHT && id != PREFAB_DIRECTIONAL_LIGHT { continue }
		raw, ok := object.raw_data.(json.Object)
		if !ok { continue }
		light := Map_Light{position = object.position}
		intensity := clamp(shadow_json_f32(raw, "li", 1), 0, 15)
		light.color = shadow_object_color(map_inst, raw) * intensity
		if target, has_target := raw["lt"].(json.Array); has_target && len(target) >= 3 {
			light.target = {shared.get_json_f32(target[0]), shared.get_json_f32(target[1]), shared.get_json_f32(target[2])}
		}
		switch id {
		case PREFAB_POINT_LIGHT:
			light.kind = .POINT
			light.position.y += 2.5
			light.distance = clamp(shadow_json_f32(raw, "lds", 0), 0, 1000)
			light.decay = clamp(shadow_json_f32(raw, "ld", 1), 0.1, 2)
		case PREFAB_SPOT_LIGHT:
			light.kind = .SPOT
			light.position.y += 2
			distance: f32 = 50
			if value, has := raw["lds"]; has && json_is_number(value) { distance = shared.get_json_f32(value) }
			light.distance = clamp(distance, 0, 1000)
			light.decay = clamp(shadow_json_f32(raw, "ld", 1), 0.1, 2)
			angle := clamp(shadow_json_f32(raw, "la", 45), 1, 90) * math.PI / 180
			penumbra := clamp(shadow_json_f32(raw, "lp", 0), 0, 1)
			light.cone_cos = math.cos(angle)
			light.penumbra_cos = math.cos(angle * (1 - penumbra))
		case PREFAB_DIRECTIONAL_LIGHT:
			light.kind = .DIRECTIONAL
			light.position.y += 2
		}
		lights[count] = light
		count += 1
	}
	return count
}

// Lights visible at this lighting level: point and spot from High, directional
// from Physical.
map_light_enabled :: proc(light: Map_Light, lighting: menuui.Lighting_Quality) -> bool {
	switch light.kind {
	case .POINT, .SPOT: return lighting >= .HIGH
	case .DIRECTIONAL: return lighting == .PHYSICAL
	}
	return false
}

sun_position :: proc(config: shared.Lighting_Config) -> shared.Vec3 {
	ax := -config.sun_angle_x * math.PI / 180.0
	ay := -config.sun_angle_y * math.PI / 180.0
	d := config.light_distance
	return {d * math.cos(ax), d * math.sin(ax) * math.sin(ay), d * math.sin(ax) * math.cos(ay)}
}

// THREE.Matrix4.lookAt for a camera at `eye` looking at the origin, then the
// inverse (the view matrix).
shadow_view_matrix :: proc(eye: shared.Vec3) -> shared.Mat4 {
	up := shared.Vec3{0, 1, 0}
	z := eye
	if linalg.length2(z) == 0 { z.z = 1 }
	z = linalg.normalize(z)
	x := linalg.cross(up, z)
	if linalg.length2(x) == 0 {
		if abs(up.z) == 1 { z.x += 0.0001 } else { z.z += 0.0001 }
		z = linalg.normalize(z)
		x = linalg.cross(up, z)
	}
	x = linalg.normalize(x)
	y := linalg.cross(z, x)
	return shared.Mat4{
		x.x, x.y, x.z, -linalg.dot(x, eye),
		y.x, y.y, y.z, -linalg.dot(y, eye),
		z.x, z.y, z.z, -linalg.dot(z, eye),
		0, 0, 0, 1,
	}
}

// THREE.Matrix4.makeOrthographic (OpenGL clip space, z in -1..1).
shadow_ortho_matrix :: proc(left, right, top, bottom, near, far: f32) -> shared.Mat4 {
	w := 1 / (right - left)
	h := 1 / (top - bottom)
	p := 1 / (far - near)
	return shared.Mat4{
		2 * w, 0, 0, -(right + left) * w,
		0, 2 * h, 0, -(top + bottom) * h,
		0, 0, -2 * p, -(far + near) * p,
		0, 0, 0, 1,
	}
}

shadow_map_size :: proc(config: shared.Lighting_Config, high_res: bool) -> i32 {
	if high_res { return SHADOW_HIGH_RES }
	size := config.shadow_resolution > 0 ? config.shadow_resolution : shared.SHADOW_DEFAULT_RESOLUTION
	// Query once: a glGet every frame makes threaded drivers sync with the GPU.
	@(static) max_size: i32
	if max_size == 0 { gl.GetIntegerv(gl.MAX_TEXTURE_SIZE, &max_size) }
	return clamp(size, 1, max(max_size, 1))
}

// The sky light exists only when the map has a light colour (sceneInit tests
// `light` for truthiness, so 0 / black disables it).
sun_casts_light :: proc(config: shared.Lighting_Config) -> bool {
	return config.light_color != {} && config.light_intensity > 0
}

@(private = "file")
shadow_program_init :: proc() -> bool {
	if g_shadow.program != 0 { return true }
	vert := shared.concat(shared.assets_path(), "shaders/basic.vert")
	frag := shared.concat(shared.assets_path(), "shaders/basic.frag")
	defer { delete(vert); delete(frag) }
	g_shadow.program = shader_compile(vert, frag, "#define SHADOW_DEPTH_PASS\n")
	if g_shadow.program == 0 { return false }
	g_shadow.uniforms = cache_uniforms(g_shadow.program)
	// Optional: without it the static map is drawn object by object.
	// The portable batch layout's slot #defines (map_batch_shader_defines).
	batched_defines := strings.concatenate({map_batch_shader_defines(context.temp_allocator), "#define SHADOW_DEPTH_PASS\n"}, context.temp_allocator)
	g_shadow.batched_program = shader_compile(vert, frag, batched_defines)
	if g_shadow.batched_program != 0 { g_shadow.batched_uniforms = cache_uniforms(g_shadow.batched_program) }
	return true
}

@(private = "file")
shadow_texture_params :: proc(texture: u32, soft: bool) {
	filter := i32(soft ? gl.LINEAR : gl.NEAREST)
	gl.TextureParameteri(texture, gl.TEXTURE_MIN_FILTER, filter)
	gl.TextureParameteri(texture, gl.TEXTURE_MAG_FILTER, filter)
	gl.TextureParameteri(texture, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TextureParameteri(texture, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	gl.TextureParameteri(texture, gl.TEXTURE_COMPARE_MODE, gl.COMPARE_REF_TO_TEXTURE)
	gl.TextureParameteri(texture, gl.TEXTURE_COMPARE_FUNC, gl.LEQUAL)
}

@(private = "file")
shadow_sun_target_init :: proc(size: i32, layers: int, soft: bool, mode: menuui.Shadow_Quality) {
	if g_shadow.texture != 0 && g_shadow.size == size && g_shadow.layers == layers && g_shadow.mode == mode {
		if g_shadow.soft != soft {
			// The filter is a texture parameter; no redraw needed.
			shadow_texture_params(g_shadow.texture, soft)
			if g_shadow.player_texture != 0 { shadow_texture_params(g_shadow.player_texture, soft) }
			g_shadow.soft = soft
		}
		return
	}
	shadow_release_target()
	gl.CreateTextures(gl.TEXTURE_2D_ARRAY, 1, &g_shadow.texture)
	gl.TextureStorage3D(g_shadow.texture, 1, gl.DEPTH_COMPONENT24, size, size, i32(layers))
	shadow_texture_params(g_shadow.texture, soft)
	for layer in 0 ..< layers {
		gl.CreateFramebuffers(1, &g_shadow.fbos[layer])
		gl.NamedFramebufferTextureLayer(g_shadow.fbos[layer], gl.DEPTH_ATTACHMENT, g_shadow.texture, 0, i32(layer))
		gl.NamedFramebufferDrawBuffer(g_shadow.fbos[layer], gl.NONE)
		gl.NamedFramebufferReadBuffer(g_shadow.fbos[layer], gl.NONE)
	}
	g_shadow.size, g_shadow.layers, g_shadow.soft, g_shadow.mode = size, layers, soft, mode
	g_shadow.cascades = {}
	g_shadow.dirty = true
}

@(private = "file")
shadow_player_target_init :: proc(soft: bool) {
	if g_shadow.player_texture != 0 { return }
	gl.CreateTextures(gl.TEXTURE_2D, 1, &g_shadow.player_texture)
	gl.TextureStorage2D(g_shadow.player_texture, 1, gl.DEPTH_COMPONENT24, PLAYER_SHADOW_SIZE, PLAYER_SHADOW_SIZE)
	shadow_texture_params(g_shadow.player_texture, soft)
	gl.CreateFramebuffers(1, &g_shadow.player_fbo)
	gl.NamedFramebufferTexture(g_shadow.player_fbo, gl.DEPTH_ATTACHMENT, g_shadow.player_texture, 0)
	gl.NamedFramebufferDrawBuffer(g_shadow.player_fbo, gl.NONE)
	gl.NamedFramebufferReadBuffer(g_shadow.player_fbo, gl.NONE)
}

shadow_release_target :: proc() {
	for &fbo in g_shadow.fbos {
		if fbo != 0 { gl.DeleteFramebuffers(1, &fbo) }
		fbo = 0
	}
	if g_shadow.texture != 0 { gl.DeleteTextures(1, &g_shadow.texture) }
	if g_shadow.player_fbo != 0 { gl.DeleteFramebuffers(1, &g_shadow.player_fbo) }
	if g_shadow.player_texture != 0 { gl.DeleteTextures(1, &g_shadow.player_texture) }
	g_shadow.texture, g_shadow.player_fbo, g_shadow.player_texture = 0, 0, 0
	g_shadow.size, g_shadow.layers = 0, 0
	g_shadow.cascades = {}
}

// Map change: the shadow maps and the light list belong to the old map.
shadow_release_map :: proc() {
	shadow_release_target()
	g_shadow.map_inst = nil
	g_shadow.light_count = 0
	g_shadow.dirty = true
}

// Shutdown: everything, including the depth programs.
shadow_fini :: proc() {
	shadow_release_map()
	for program in ([2]u32{g_shadow.program, g_shadow.batched_program}) {
		if program == 0 { continue }
		gl.DeleteProgram(program)
		if g_active_shader == program { g_active_shader = 0 }
	}
	g_shadow = {}
	g_render_quality = {lighting = .NORMAL}
}

shadow_mark_dirty :: proc() { g_shadow.dirty = true }

// Rough map bounds from every object (position +- scale), padded: the depth
// range of the Sharp cascades must hold every caster along the light.
@(private = "file")
shadow_map_bounds :: proc(map_inst: ^shared.Map) -> (lo, hi: shared.Vec3) {
	first := true
	for object in map_inst.objects {
		if object == nil { continue }
		a := object.position - object.scale
		b := object.position + object.scale
		if first {
			lo, hi, first = a, b, false
		} else {
			lo = {min(lo.x, a.x), min(lo.y, a.y), min(lo.z, a.z)}
			hi = {max(hi.x, b.x), max(hi.y, b.y), max(hi.z, b.z)}
		}
	}
	pad := shared.Vec3{64, 64, 64}
	return lo - pad, hi + pad
}

// Frustum planes of any view-projection matrix (Gribb/Hartmann).
frustum_from_matrix :: proc(m: shared.Mat4) -> Frustum {
	row :: proc(m: shared.Mat4, i: int) -> shared.Vec4 { return {m[i, 0], m[i, 1], m[i, 2], m[i, 3]} }
	r0, r1, r2, r3 := row(m, 0), row(m, 1), row(m, 2), row(m, 3)
	f: Frustum
	f.planes = {r3 + r0, r3 - r0, r3 + r1, r3 - r1, r3 + r2, r3 - r2}
	for &plane in f.planes {
		length := math.sqrt(plane.x * plane.x + plane.y * plane.y + plane.z * plane.z)
		if length > 0 { plane /= length }
	}
	return f
}

UV_FROM_CLIP :: shared.Mat4{
	0.5, 0, 0, 0.5,
	0, 0.5, 0, 0.5,
	0, 0, 0.5, 0.5,
	0, 0, 0, 1,
}

// Light-space depth range [near, far] (positive distances along the light)
// that holds the box lo..hi.
@(private = "file")
shadow_depth_range :: proc(view: shared.Mat4, lo, hi: shared.Vec3) -> (near, far: f32) {
	near, far = max(f32), -max(f32)
	for i in 0 ..< 8 {
		corner := shared.Vec4{(i & 1) != 0 ? hi.x : lo.x, (i & 2) != 0 ? hi.y : lo.y, (i & 4) != 0 ? hi.z : lo.z, 1}
		d := -(view * corner).z
		near, far = min(near, d), max(far, d)
	}
	return near, far
}

// Sharp cascade radii for this map: the last reaches the fog.
cascade_radii :: proc(config: shared.Lighting_Config) -> [SHADOW_CASCADES]f32 {
	far := clamp(config.fog_distance, CASCADE_FAR_MIN, CASCADE_FAR_MAX)
	return {CASCADE_NEAR_RADIUS, CASCADE_MID_RADIUS, far}
}

// Fits cascade `index` around `center`: an orthographic square of the given
// radius in light space, its centre snapped to whole texels so a redraw after
// the camera moves samples the same texel grid (no shimmering).
cascade_fit :: proc(view: shared.Mat4, center: shared.Vec3, radius: f32, near, far: f32, world_bias: f32) -> (cascade: Shadow_Cascade, projection: shared.Mat4) {
	c := view * shared.Vec4{center.x, center.y, center.z, 1}
	texel := 2 * radius / CASCADE_SIZE
	cx := math.floor(c.x / texel) * texel
	cy := math.floor(c.y / texel) * texel
	projection = shadow_ortho_matrix(cx - radius, cx + radius, cy + radius, cy - radius, near, far)
	cascade = Shadow_Cascade{valid = true, center = center, radius = radius, cx = cx, cy = cy}
	cascade.view_projection = projection * view
	cascade.shadow_matrix = UV_FROM_CLIP * cascade.view_projection
	cascade.bias = -world_bias / max(far - near, 1)
	return
}

// Called once per frame before the world pass. Decides what this frame draws
// and renders what is out of date. With Shadows off (or nothing to shadow) it
// does no GL work at all.
// `framebuffer` and `viewport` are restored after a shadow-map render; they are
// passed in because reading them back with glGet stalls threaded drivers.
shadow_prepare :: proc(scene: ^Scene, map_inst: ^shared.Map, quality: menuui.Quality_Settings, framebuffer: u32 = 0, viewport: [4]i32 = {}, camera_position := shared.Vec3{}) {
	lighting := menuui.Lighting_Quality(clamp(quality.lighting, 0, 3))
	mode := menuui.Shadow_Quality(clamp(quality.shadow_quality, 0, 1))
	g_render_quality = {lighting = lighting, mode = mode}
	if map_inst == nil { return }
	if g_shadow.map_inst != map_inst {
		shadow_release_target()
		g_shadow.map_inst = map_inst
		g_shadow.half_width, g_shadow.half_length = shadow_map_extent(map_inst)
		g_shadow.map_lo, g_shadow.map_hi = shadow_map_bounds(map_inst)
		g_shadow.light_count = map_lights_collect(map_inst, &g_shadow.lights)
		g_shadow.dirty = true
	}
	config := g_lighting_config
	// Low lighting is MeshBasicMaterial, which never shows shadows; skip the
	// pass instead of rendering a map nobody samples.
	if !quality.shadows || lighting == .LOW || !sun_casts_light(config) || g_shadow.half_width <= 0 || g_shadow.half_length <= 0 {
		return
	}
	if !shadow_program_init() { return }

	krunker_far := f32(config.shadow_distance > 0 ? config.shadow_distance : shared.SHADOW_DEFAULT_DISTANCE)
	// Krunker's bias is -0.0004 of its shadow camera's depth range; the other
	// maps use the same distance in world units.
	g_shadow.world_bias = -SHADOW_BIAS * (krunker_far - SHADOW_NEAR)
	view := shadow_view_matrix(sun_position(config))
	if view != g_shadow.light_key {
		g_shadow.light_key = view
		g_shadow.dirty = true
	}

	pass := Shadow_Pass{framebuffer = framebuffer, viewport = viewport}
	if mode == .KRUNKER {
		shadow_sun_target_init(shadow_map_size(config, quality.high_res_shadows), 1, quality.soft_shadows, mode)
		projection := shadow_ortho_matrix(-g_shadow.half_width, g_shadow.half_width, g_shadow.half_length, -g_shadow.half_length, SHADOW_NEAR, krunker_far)
		cascade := Shadow_Cascade{valid = true, view_projection = projection * view, bias = SHADOW_BIAS}
		cascade.shadow_matrix = UV_FROM_CLIP * cascade.view_projection
		if g_shadow.dirty || !g_shadow.cascades[0].valid || cascade.view_projection != g_shadow.cascades[0].view_projection {
			g_shadow.cascades[0] = cascade
			shadow_render_layer(scene, &pass, 0, view, projection)
		}
	} else {
		shadow_sun_target_init(CASCADE_SIZE, SHADOW_CASCADES, quality.soft_shadows, mode)
		near, far := shadow_depth_range(view, g_shadow.map_lo, g_shadow.map_hi)
		near, far = near - 1, far + 1
		radii := cascade_radii(config)
		// Every out-of-date cascade is redrawn when the map changes; otherwise
		// at most one per frame, so walking never redraws all three at once.
		redrawn := false
		for index in 0 ..< SHADOW_CASCADES {
			cascade := &g_shadow.cascades[index]
			distance := linalg.length(camera_position - cascade.center)
			// Past half the radius (a teleport or respawn) the view could reach
			// the cascade's edge: redraw now. Ordinary movement is throttled.
			stale := g_shadow.dirty || !cascade.valid || cascade.radius != radii[index] || distance > radii[index] * 0.5
			moved := cascade.valid && distance > radii[index] * CASCADE_RECENTER
			if !stale && !(moved && !redrawn) { continue }
			projection: shared.Mat4
			cascade^, projection = cascade_fit(view, camera_position, radii[index], near, far, g_shadow.world_bias)
			shadow_render_layer(scene, &pass, index, view, projection)
			if !stale { redrawn = true }
		}
	}
	g_shadow.dirty = false
	shadow_end_pass(&pass)

	g_render_quality.shadows = true
	g_render_quality.soft_shadows = quality.soft_shadows
	g_render_quality.dynamic_shadows = quality.dynamic_shadows
	g_render_quality.player_shadows = shadow_render_players(scene, &pass, view, quality, camera_position)
	shadow_end_pass(&pass)
}

// GL state of one shadow pass sequence; restored by shadow_end_pass.
Shadow_Pass :: struct {
	framebuffer: u32,
	viewport:    [4]i32,
	active:      bool,
}

@(private = "file")
shadow_begin_target :: proc(pass: ^Shadow_Pass, fbo: u32, size: i32, cull_front: bool) {
	pass.active = true
	gl.BindFramebuffer(gl.FRAMEBUFFER, fbo)
	gl.Viewport(0, 0, size, size)
	gl.Enable(gl.DEPTH_TEST)
	gl.DepthMask(gl.TRUE)
	gl.Disable(gl.BLEND)
	gl.PolygonMode(gl.FRONT_AND_BACK, gl.FILL)
	gl.Clear(gl.DEPTH_BUFFER_BIT)
	if cull_front {
		gl.Enable(gl.CULL_FACE)
		gl.CullFace(gl.FRONT)
	} else {
		gl.Disable(gl.CULL_FACE)
	}
	gl.ActiveTexture(gl.TEXTURE0)
}

@(private = "file")
shadow_end_pass :: proc(pass: ^Shadow_Pass) {
	if !pass.active { return }
	pass.active = false
	gl.Disable(gl.CULL_FACE)
	gl.CullFace(gl.BACK)
	gl.BindFramebuffer(gl.FRAMEBUFFER, pass.framebuffer)
	gl.Viewport(pass.viewport[0], pass.viewport[1], pass.viewport[2], pass.viewport[3])
}

@(private = "file")
shadow_bind_program :: proc(program: u32, u: ^Shader_Uniforms, view, projection: shared.Mat4) {
	gl.UseProgram(program)
	g_active_shader = program
	view_matrix, projection_matrix := view, projection
	gl.UniformMatrix4fv(u.camera_world_inverse, 1, gl.FALSE, &view_matrix[0, 0])
	gl.UniformMatrix4fv(u.camera_projection, 1, gl.FALSE, &projection_matrix[0, 0])
	gl.Uniform1f(u.world_uv_scale, shared.GAME_CONSTANTS.world_uv_scale)
	gl.Uniform1i(u.tex, 0)
}

// One mesh through the per-object depth program (already bound), unless its
// bounds are outside the light frustum.
@(private = "file")
shadow_draw_mesh :: proc(mesh: ^Mesh, vao: ^u32, frustum: ^Frustum) -> bool {
	if mesh.material == nil || mesh.material.vtable != &basic_material_vtable || mesh.geometry == nil { return false }
	mesh_update_transform_matrix(mesh)
	if frustum != nil && mesh.geometry.has_bounds {
		lo, hi := mesh_world_bounds(mesh)
		if !frustum_aabb_visible(frustum, lo, hi) { return false }
	}
	if vao^ != mesh.geometry.vao {
		gl.BindVertexArray(mesh.geometry.vao)
		vao^ = mesh.geometry.vao
	}
	// basic_material_update_uniforms writes through u_basic.
	saved := u_basic
	u_basic = g_shadow.uniforms
	basic_material_update_uniforms(mesh.material)
	u_basic = saved
	gl.UniformMatrix4fv(g_shadow.uniforms.transform, 1, gl.FALSE, &mesh.transform_matrix[0, 0])
	gl.DrawElements(gl.TRIANGLES, mesh.geometry.index_count, gl.UNSIGNED_INT, nil)
	g_draw_stats.draw_calls += 1
	return true
}

// A batch the world pass draws as one call: merged, every member visible and
// unmoved since the build (the same test as scene_draw_batches).
@(private = "file")
shadow_batch_whole :: proc(set: ^Map_Batch_Set, batch: ^Map_Batch) -> bool {
	if batch.single { return false }
	for mesh in set.members[batch.member_start:][:batch.member_count] {
		if !mesh.visible || mesh.transform != mesh.last_transform { return false }
	}
	return true
}

// Static casters of one sun-map layer, culled to its light frustum. With
// batching on, merged map batches go through the batched depth program (one
// draw per batch; receive-only members are clipped away in basic.vert).
// Batches the world pass would split, single slots and every other static
// caster are drawn one by one.
@(private = "file")
shadow_render_layer :: proc(scene: ^Scene, pass: ^Shadow_Pass, layer: int, view, projection: shared.Mat4) {
	shadow_begin_target(pass, g_shadow.fbos[layer], g_shadow.size, true)
	frustum := frustum_from_matrix(projection * view)
	set := scene.batches
	batched := set != nil && scene.batching_enabled && g_shadow.batched_program != 0 && set.vao != 0
	vao: u32
	if batched {
		shadow_bind_program(g_shadow.batched_program, &g_shadow.batched_uniforms, view, projection)
		gl.BindVertexArray(set.vao)
		gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, 0, set.ssbo)
		for &batch in set.batches {
			if !shadow_batch_whole(set, &batch) || !frustum_aabb_visible(&frustum, batch.bounds_min, batch.bounds_max) { continue }
			basic_bind_texture(batch.key.texture)
			gl.DrawElements(gl.TRIANGLES, batch.index_count, gl.UNSIGNED_INT, rawptr(uintptr(batch.first_index) * size_of(u32)))
			g_draw_stats.draw_calls += 1
		}
	}
	shadow_bind_program(g_shadow.program, &g_shadow.uniforms, view, projection)
	if batched {
		for &batch in set.batches {
			if shadow_batch_whole(set, &batch) || !frustum_aabb_visible(&frustum, batch.bounds_min, batch.bounds_max) { continue }
			for mesh in set.members[batch.member_start:][:batch.member_count] {
				if mesh.visible && mesh.shadow_caster == .STATIC { shadow_draw_mesh(mesh, &vao, &frustum) }
			}
		}
	}
	for mesh in scene.meshes {
		if !mesh.visible || mesh.shadow_caster != .STATIC || batched && mesh.batched { continue }
		shadow_draw_mesh(mesh, &vao, &frustum)
	}
	g_shadow.renders += 1
}

// Player map: Dynamic Shadows casters within PLAYER_SHADOW_RADIUS of the
// camera, plus g_shadow_extra_casters (your body). The light frustum is the
// light-space box around those casters, grown to a multiple of 8 units and
// snapped to texels so it changes rarely; receivers past its far plane still
// compare (the shader clamps depth). Returns whether anything was drawn.
@(private = "file")
shadow_render_players :: proc(scene: ^Scene, pass: ^Shadow_Pass, view: shared.Mat4, quality: menuui.Quality_Settings, camera_position: shared.Vec3) -> bool {
	casters := make([dynamic]^Mesh, context.temp_allocator)
	if quality.dynamic_shadows {
		for mesh in scene.meshes {
			if !mesh.visible || mesh.shadow_caster != .DYNAMIC || mesh.geometry == nil || !mesh.geometry.has_bounds { continue }
			mesh_update_transform_matrix(mesh)
			lo, hi := mesh_world_bounds(mesh)
			if linalg.length((lo + hi) * 0.5 - camera_position) > PLAYER_SHADOW_RADIUS { continue }
			append(&casters, mesh)
		}
	}
	for mesh in g_shadow_extra_casters {
		if mesh != nil && mesh.visible && mesh.geometry != nil && mesh.geometry.has_bounds { append(&casters, mesh) }
	}
	if len(casters) == 0 { return false }

	lo := shared.Vec3{max(f32), max(f32), max(f32)}
	hi := -lo
	for mesh in casters {
		mesh_update_transform_matrix(mesh)
		a, b := mesh_world_bounds(mesh)
		for i in 0 ..< 8 {
			corner := shared.Vec4{(i & 1) != 0 ? b.x : a.x, (i & 2) != 0 ? b.y : a.y, (i & 4) != 0 ? b.z : a.z, 1}
			p := (view * corner).xyz
			lo = {min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z)}
			hi = {max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z)}
		}
	}
	half := max(hi.x - lo.x, hi.y - lo.y) * 0.5 + 1
	half = math.ceil(half / 8) * 8
	texel := 2 * half / PLAYER_SHADOW_SIZE
	cx := math.floor((lo.x + hi.x) * 0.5 / texel) * texel
	cy := math.floor((lo.y + hi.y) * 0.5 / texel) * texel
	// View space looks down -z: distances along the light are -z.
	near := -hi.z - 1
	far := -lo.z + 64
	projection := shadow_ortho_matrix(cx - half, cx + half, cy + half, cy - half, near, far)
	g_shadow.player_matrix = UV_FROM_CLIP * projection * view
	g_shadow.player_bias = -g_shadow.world_bias / (far - near)

	shadow_player_target_init(quality.soft_shadows)
	// No face culling: players are small closed meshes whose nearest surface
	// should touch the ground (no gap at the feet); the bias keeps them free of
	// acne on themselves.
	shadow_begin_target(pass, g_shadow.player_fbo, PLAYER_SHADOW_SIZE, false)
	shadow_bind_program(g_shadow.program, &g_shadow.uniforms, view, projection)
	vao: u32
	drawn := 0
	for mesh in casters {
		if shadow_draw_mesh(mesh, &vao, nil) { drawn += 1 }
	}
	g_shadow.casters_drawn = drawn
	g_shadow.player_renders += 1
	return drawn > 0
}

// 1x1 depth textures with depth comparison, bound to units 1 and 2 whenever
// no real shadow map is: basic.frag's shadow samplers are statically used, and
// a shadow sampler reading texture 0 (no depth format, no comparison) is
// undefined behaviour that drivers may warn about or mishandle even when the
// branch that samples it is never taken. Freed by shadow_placeholders_fini
// (resource_cache_fini) with the rest of the context's objects. They belong to
// the context that made them: tests destroy and recreate contexts, and a name
// from a dead context may already name another object in the new one.
g_shadow_placeholder_array, g_shadow_placeholder_2d: u32
g_shadow_placeholder_context: glfw.WindowHandle

@(private = "file")
shadow_placeholders_current :: proc() -> bool {
	current := glfw.GetCurrentContext()
	if current != g_shadow_placeholder_context {
		// The old context (and its textures) is gone or not current: forget them.
		g_shadow_placeholder_array, g_shadow_placeholder_2d = 0, 0
		g_shadow_placeholder_context = current
	}
	return current != nil
}

@(private = "file")
shadow_placeholder_texture :: proc(target: u32) -> u32 {
	texture: u32
	gl.CreateTextures(target, 1, &texture)
	far := f32(1) // Fully lit.
	if target == gl.TEXTURE_2D_ARRAY {
		gl.TextureStorage3D(texture, 1, gl.DEPTH_COMPONENT24, 1, 1, 1)
		gl.TextureSubImage3D(texture, 0, 0, 0, 0, 1, 1, 1, gl.DEPTH_COMPONENT, gl.FLOAT, &far)
	} else {
		gl.TextureStorage2D(texture, 1, gl.DEPTH_COMPONENT24, 1, 1)
		gl.TextureSubImage2D(texture, 0, 0, 0, 1, 1, gl.DEPTH_COMPONENT, gl.FLOAT, &far)
	}
	shadow_texture_params(texture, false)
	return texture
}

@(private = "file")
shadow_bind_placeholders :: proc(sun, player: bool) {
	if !(sun || player) || !shadow_placeholders_current() { return }
	if sun {
		if g_shadow_placeholder_array == 0 { g_shadow_placeholder_array = shadow_placeholder_texture(gl.TEXTURE_2D_ARRAY) }
		gl.BindTextureUnit(1, g_shadow_placeholder_array)
	}
	if player {
		if g_shadow_placeholder_2d == 0 { g_shadow_placeholder_2d = shadow_placeholder_texture(gl.TEXTURE_2D) }
		gl.BindTextureUnit(2, g_shadow_placeholder_2d)
	}
}

shadow_placeholders_fini :: proc() {
	if !shadow_placeholders_current() { return }
	if g_shadow_placeholder_array != 0 { gl.DeleteTextures(1, &g_shadow_placeholder_array) }
	if g_shadow_placeholder_2d != 0 { gl.DeleteTextures(1, &g_shadow_placeholder_2d) }
	g_shadow_placeholder_array, g_shadow_placeholder_2d = 0, 0
}

// Per-pass uniforms for basic.frag; called with the basic program bound.
shadow_update_pass_uniforms :: proc(u: ^Shader_Uniforms) {
	q := g_render_quality
	gl.Uniform1i(u.lighting_mode, i32(q.lighting))
	gl.Uniform1i(u.shadow_enabled, i32(q.shadows))
	sun_map := q.shadows && g_shadow.texture != 0
	player_map := sun_map && q.player_shadows && !g_shadow_viewmodel_pass && g_shadow.player_texture != 0
	shadow_bind_placeholders(!sun_map, !player_map)
	if q.shadows {
		layers := g_shadow.layers
		matrices: [SHADOW_CASCADES]shared.Mat4
		biases, texels: [SHADOW_CASCADES]f32
		for i in 0 ..< layers {
			matrices[i] = g_shadow.cascades[i].shadow_matrix
			biases[i] = g_shadow.cascades[i].bias
			texels[i] = 1 / f32(g_shadow.size)
		}
		gl.Uniform1i(u.shadow_layers, i32(layers))
		// Sharp cascades share the light view and depth range, so each one's uv
		// is cascade 0's uv scaled and offset: one matrix per pixel, not three.
		scale_offsets: [SHADOW_CASCADES][4]f32
		c0 := g_shadow.cascades[0]
		for i in 0 ..< layers {
			c := g_shadow.cascades[i]
			if layers == 1 || c.radius <= 0 { scale_offsets[i] = {1, 1, 0, 0}; continue }
			scale := c0.radius / c.radius
			scale_offsets[i] = {scale, scale, 0.5 - 0.5 * scale + (c0.cx - c.cx) / (2 * c.radius), 0.5 - 0.5 * scale + (c0.cy - c.cy) / (2 * c.radius)}
		}
		gl.Uniform4fv(u.cascade_scale_offset, i32(layers), &scale_offsets[0][0])
		gl.UniformMatrix4fv(u.shadow_matrices, i32(layers), gl.FALSE, &matrices[0][0, 0])
		gl.Uniform1fv(u.shadow_biases, i32(layers), &biases[0])
		gl.Uniform1fv(u.shadow_texels, i32(layers), &texels[0])
		gl.Uniform1i(u.shadow_soft, i32(q.soft_shadows))
		gl.Uniform1i(u.shadow_soft_kernel, q.mode == .SHARP || g_shadow_soft_kernel_override ? 1 : 0)
		gl.Uniform1f(u.shadow_normal_bias, g_lighting_config.shadow_normal_bias)
		if sun_map { gl.BindTextureUnit(1, g_shadow.texture) }
		player := q.player_shadows && !g_shadow_viewmodel_pass
		gl.Uniform1i(u.player_shadow_enabled, i32(player))
		if player {
			player_matrix := g_shadow.player_matrix
			gl.UniformMatrix4fv(u.player_shadow_matrix, 1, gl.FALSE, &player_matrix[0, 0])
			gl.Uniform1f(u.player_shadow_bias, g_shadow.player_bias)
			gl.Uniform1f(u.player_shadow_texel, 1.0 / PLAYER_SHADOW_SIZE)
			if player_map { gl.BindTextureUnit(2, g_shadow.player_texture) }
		}
	}
	count: i32
	if q.lighting >= .HIGH {
		for light in g_shadow.lights[:g_shadow.light_count] {
			if !map_light_enabled(light, q.lighting) { continue }
			direction := light.kind == .POINT ? shared.Vec3{} : linalg.normalize0(light.kind == .DIRECTIONAL ? light.position - light.target : light.target - light.position)
			gl.Uniform4f(u.map_light_position + count, light.position.x, light.position.y, light.position.z, f32(light.kind))
			gl.Uniform4f(u.map_light_color + count, light.color.x, light.color.y, light.color.z, light.distance)
			gl.Uniform4f(u.map_light_direction + count, direction.x, direction.y, direction.z, light.decay)
			gl.Uniform2f(u.map_light_cone + count, light.cone_cos, light.penumbra_cos)
			count += 1
		}
	}
	gl.Uniform1i(u.map_light_count, count)
}

// CPU copy of basic.frag's cascade selection (sun_visibility): the first
// cascade whose square holds `point` with a 2-texel margin and whose depth
// range holds it. -1 means no cascade (lit). Used by tests.
cascade_covering :: proc(cascades: []Shadow_Cascade, point: shared.Vec3) -> int {
	for cascade, index in cascades {
		if !cascade.valid { continue }
		c := cascade.shadow_matrix * shared.Vec4{point.x, point.y, point.z, 1}
		inset := min(min(c.x, 1 - c.x), min(c.y, 1 - c.y))
		if inset < 2.0 / CASCADE_SIZE || c.z + cascade.bias > 1 || c.z < 0 { continue }
		return index
	}
	return -1
}
