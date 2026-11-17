package main

import "core:fmt"
import "core:math"
import "core:mem"
import gl "vendor:OpenGL"
import shared "../shared"

basic_shader_program: Gpu_Program
// Static map batches (map_batch.odin): same shader source with BATCHED defined.
basic_batched_shader_program: Gpu_Program

// Active map environment. It is updated when a map is loaded and consumed by
// the basic world material for every draw.
g_lighting_config: shared.Lighting_Config = shared.DEFAULT_LIGHTING_CONFIG

// std140 layout of the `Pass` uniform block in basic.vert and basic.frag
// (GPU_BINDING_PASS): everything shared by the draws of one pass. Field order
// and padding follow std140, so the struct is uploaded as is; the asserts pin
// the offsets the shader computes.
Basic_Pass_Uniforms :: struct {
	camera_world_inverse:  shared.Mat4,
	camera_projection:     shared.Mat4,
	shadow_matrices:       [SHADOW_CASCADES]shared.Mat4, // world -> uv (xy) and depth (z)
	player_shadow_matrix:  shared.Mat4,
	cascade_scale_offset:  [SHADOW_CASCADES][4]f32,
	shadow_bias_texel:     [SHADOW_CASCADES][4]f32, // x depth bias, y texel size
	map_light_position:    [MAX_MAP_LIGHTS][4]f32,
	map_light_color:       [MAX_MAP_LIGHTS][4]f32,
	map_light_direction:   [MAX_MAP_LIGHTS][4]f32,
	map_light_cone:        [MAX_MAP_LIGHTS][4]f32, // xy used
	visual_image:          [4]f32, // brightness, gamma, contrast, saturation
	ambient_color:         [3]f32,
	ambient_intensity:     f32,
	light_color:           [3]f32,
	light_intensity:       f32,
	light_dir:             [3]f32,
	world_uv_scale:        f32,
	fog_color:             [3]f32,
	fog_near:              f32,
	camera_position:       [3]f32,
	fog_far:               f32,
	night_low_tint:        [3]f32,
	shadow_normal_bias:    f32,
	night_unlit_tint:      [3]f32,
	player_shadow_bias:    f32,
	visual_lighting:       [2]f32, // ambient and sunlight multipliers
	player_shadow_texel:   f32,
	lighting_mode:         i32,
	shadow_enabled:        b32,
	shadow_layers:         i32,
	shadow_soft:           b32,
	shadow_soft_kernel:    i32,
	player_shadow_enabled: b32,
	map_light_count:       i32,
	_pad:                  [2]i32, // std140 rounds the block to 16 bytes
}
#assert(size_of(shared.Mat4) == 64)
#assert(offset_of(Basic_Pass_Uniforms, player_shadow_matrix) == 320)
#assert(offset_of(Basic_Pass_Uniforms, map_light_position) == 480)
#assert(offset_of(Basic_Pass_Uniforms, visual_image) == 1504)
#assert(offset_of(Basic_Pass_Uniforms, ambient_intensity) == 1532)
#assert(offset_of(Basic_Pass_Uniforms, visual_lighting) == 1632)
#assert(offset_of(Basic_Pass_Uniforms, lighting_mode) == 1644)
#assert(offset_of(Basic_Pass_Uniforms, shadow_enabled) == 1648)
#assert(offset_of(Basic_Pass_Uniforms, map_light_count) == 1668)
#assert(size_of(Basic_Pass_Uniforms) == 1680)

// Every basic program variant is compiled with these: the Batch_Object slot
// numbers and flag bits (map_batch.odin), plus the variant's own defines.
basic_shader_defines :: proc(batched, shadow_depth: bool, allocator := context.allocator) -> string {
	return fmt.aprintf(
		"%s%s#define BATCH_OBJECT_VEC4S %d\n#define BATCH_SLOT_TRANSFORM %d\n#define BATCH_SLOT_COLOR %d\n#define BATCH_SLOT_EMISSIVE %d\n#define BATCH_SLOT_FACE_SCALE %d\n#define BATCH_SLOT_TEX_ROW0 %d\n#define BATCH_SLOT_TEX_ROW1 %d\n#define BATCH_SLOT_PARAMS %d\n#define BATCH_FLAG_RAMP %d\n#define BATCH_FLAG_LADDER %d\n#define BATCH_FLAG_FACE_TEX_SCALE %d\n#define BATCH_FLAG_UNLIT %d\n#define BATCH_FLAG_NO_FOG %d\n#define BATCH_FLAG_RECEIVE_SHADOW %d\n#define BATCH_FLAG_CAST_SHADOW %d\n",
		batched ? "#define BATCHED\n" : "",
		shadow_depth ? "#define SHADOW_DEPTH_PASS\n" : "",
		BATCH_OBJECT_VEC4S,
		offset_of(Batch_Object, transform) / 16,
		offset_of(Batch_Object, color) / 16,
		offset_of(Batch_Object, emissive) / 16,
		offset_of(Batch_Object, face_scale) / 16,
		offset_of(Batch_Object, tex_row0) / 16,
		offset_of(Batch_Object, tex_row1) / 16,
		offset_of(Batch_Object, params) / 16,
		BATCH_FLAG_RAMP,
		BATCH_FLAG_LADDER,
		BATCH_FLAG_FACE_TEX_SCALE,
		BATCH_FLAG_UNLIT,
		BATCH_FLAG_NO_FOG,
		BATCH_FLAG_RECEIVE_SHADOW,
		BATCH_FLAG_CAST_SHADOW,
		allocator = allocator,
	)
}

// Compiles basic.vert/basic.frag as one variant. 0 when it fails.
basic_program_compile :: proc(batched, shadow_depth: bool) -> u32 {
	vert := shared.concat(shared.assets_path(), "shaders/basic.vert")
	frag := shared.concat(shared.assets_path(), "shaders/basic.frag")
	defines := basic_shader_defines(batched, shadow_depth)
	defer { delete(vert); delete(frag); delete(defines) }
	return shader_compile(vert, frag, defines)
}

// Per-draw data of a basic-material draw: the object as a Batch_Object (the
// record map batches store), pushed to the `Draw` block, plus its texture.
basic_material_push_draw :: proc(material: ^Basic_Material, transform: shared.Mat4) {
	object := batch_object_from_material(material, transform)
	gpu_uniform_push(GPU_BINDING_DRAW, mem.ptr_to_bytes(&object))
	basic_bind_texture(material.texture)
}

// Row-major UV transform. Map batches store the same rows, so both paths use
// bit-identical values.
basic_material_tex_transform :: proc(material: ^Basic_Material) -> [3][3]f32 {
	c := math.cos(material.texture_rotation)
	s := math.sin(material.texture_rotation)
	// Match THREE.Texture.setUvTransform with its default center (0, 0).
	// Krunker stores `tro` in degrees and applies it clockwise in UV space.
	m00 := material.texture_repeat.x * c
	m01 := material.texture_repeat.x * s
	m10 := -material.texture_repeat.y * s
	m11 := material.texture_repeat.y * c
	tx := material.texture_offset.x
	ty := material.texture_offset.y
	return [3][3]f32{
		{m00, m01, tx},
		{m10, m11, ty},
		{0, 0, 1},
	}
}

// Texture 0 means the untextured white material.
basic_bind_texture :: proc(texture: Gpu_Texture) {
	gpu_bind_color_texture(texture)
}

// The `Pass` block of a world pass seen from `camera`: camera, map
// environment, visual settings, shadows and map lights. Also binds the shadow
// maps (or their placeholders) the pass samples.
basic_pass_uniforms :: proc(camera: ^Camera) -> (pass: Basic_Pass_Uniforms) {
	pass.camera_world_inverse = camera.world_inverse_matrix
	pass.camera_projection = camera.projection_matrix
	pass.world_uv_scale = shared.GAME_CONSTANTS.world_uv_scale
	// Current Krunker uses an ambient light plus a directional sky/sun light.
	// Keep the same angle convention as the browser's sceneInit (degrees,
	// negated before conversion to radians).
	light_x := g_lighting_config.light_distance * math.cos(-g_lighting_config.sun_angle_x * math.PI / 180.0)
	light_y := g_lighting_config.light_distance * math.sin(-g_lighting_config.sun_angle_x * math.PI / 180.0) * math.sin(-g_lighting_config.sun_angle_y * math.PI / 180.0)
	light_z := g_lighting_config.light_distance * math.sin(-g_lighting_config.sun_angle_x * math.PI / 180.0) * math.cos(-g_lighting_config.sun_angle_y * math.PI / 180.0)
	pass.ambient_color = g_lighting_config.ambient_color.xyz
	pass.ambient_intensity = g_lighting_config.ambient_intensity
	pass.light_color = g_lighting_config.light_color.xyz
	pass.light_intensity = g_lighting_config.light_intensity
	pass.light_dir = {light_x, light_y, light_z}
	pass.fog_color = g_lighting_config.fog_color.xyz
	pass.fog_near = 1.0
	pass.fog_far = max(1.0, g_lighting_config.fog_distance)
	pass.camera_position = camera.position.xyz
	values := g_visual_settings.values
	pass.visual_image = {values[.BRIGHTNESS], values[.GAMMA], values[.CONTRAST], values[.SATURATION]}
	pass.visual_lighting = {values[.AMBIENT], values[.SUNLIGHT]}
	pass.night_low_tint = g_night_low_tint.xyz
	pass.night_unlit_tint = g_night_unlit_tint.xyz
	shadow_fill_pass_uniforms(&pass)
	return
}

flatten_mat3 :: proc(m: [3][3]f32) -> [9]f32 {
	return [9]f32{m[0][0], m[0][1], m[0][2], m[1][0], m[1][1], m[1][2], m[2][0], m[2][1], m[2][2]}
}

// Basic materials are drawn through basic_material_push_draw, not the vtable.
basic_material_vtable := Material_VTable{}

basic_material_init :: proc() -> ^Basic_Material {
	material := new(Basic_Material)
	material.base.vtable = &basic_material_vtable

	material.color = shared.Vec4{1.0, 1.0, 1.0, 1.0}

	material.texture_repeat = shared.Vec2{1.0, 1.0}
	material.face_mask = 0x3f
	material.texture_scale = 1.0

	if basic_shader_program == 0 {
		basic_shader_program = gpu_program_create_basic(false, false)
	}

	if basic_shader_program == 0 {
		free(material)
		return nil
	}

	material.base.program = basic_shader_program
	return material
}

// Compiled on first use. Returns 0 when the driver rejects it (for example no
// shader storage buffers); the map then keeps the per-object path. After a
// successful link, the driver's storage-buffer layout is checked against
// Batch_Object; a mismatch is kept in g_map_batch_shader_layout_reason.
basic_batched_program :: proc() -> Gpu_Program {
	if basic_batched_shader_program == 0 {
		basic_batched_shader_program = gpu_program_create_basic(true, false)
		if basic_batched_shader_program != 0 {
			g_map_batch_shader_layout_reason = map_batch_program_layout_reason(u32(basic_batched_shader_program))
		}
	}
	return basic_batched_shader_program
}
