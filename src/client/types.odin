package main

import shared "../shared"

Geometry :: struct {
	input:         Gpu_Vertex_Input, // .Basic layout over the two buffers below
	vertex_buffer: Gpu_Buffer,
	index_buffer:  Gpu_Buffer,
	index_count:   i32,
	// CPU copies of the uploaded data (owned), read when building map batches
	// so nothing is ever read back from the GPU.
	vertices:      []Vertex,
	indices:       []u32,
	cache_key:   string,
	ref_count:   u32,
	last_used:   u64,
	permanent:   bool,
	transform_y: bool, // how the OBJ was parsed, for a live mod reload
	// Model-space bounds of the vertices, for frustum culling.
	bounds_min:  shared.Vec3,
	bounds_max:  shared.Vec3,
	has_bounds:  bool,
}

Texture_Cache_Entry :: struct {
	id:         Gpu_Texture,
	width:      i32,
	height:     i32,
	cache_key:  string,
	ref_count:  u32,
	last_used:  u64,
}

Vertex :: struct {
	position:  shared.Vec3,
	tex_coord: shared.Vec2,
}

Rotation_Order :: enum {
	INTRINSIC,
	EXTRINSIC,
}

Material_VTable :: struct {
	update_uniforms: proc(rawptr),
}

Material :: struct {
	vtable:      ^Material_VTable,
	wireframe:   bool,
	transparent: bool,
	no_depth_write: bool,
	program:     Gpu_Program,
}

Basic_Material :: struct {
	using base: Material,
	is_ramp: bool,
	is_ladder: bool,
	use_face_tex_scaling: bool,
	face_scale: shared.Vec3,
	face_mask: u32,
	texture_scale: f32,
	unlit: bool,
	no_fog: bool,
	color: shared.Vec4,
	emissive: shared.Vec4,
	alpha_test: f32,
	receive_shadow: bool, // Samples the sun shadow map when Shadows is on.
	// Map cube: each face grows a hair within its own plane (basic.vert), so
	// T-junctions between neighbouring boxes leave no sub-pixel cracks.
	seal_edges: bool,
	texture_repeat: shared.Vec2,
	texture_offset: shared.Vec2,
	base_texture_offset: shared.Vec2,
	texture_rotation: f32,
	texture: Gpu_Texture,
}

Mesh_Transform :: struct {
	parent:         ^Mesh_Transform,
	rotation_order: Rotation_Order,
	position:       shared.Vec3,
	rotation:       shared.Vec3,
	scale:          shared.Vec3,
}

Mesh :: struct {
	map_detail: Map_Detail,
	map_detail_visible: bool,
	transform: Mesh_Transform,
	// Root meshes can reuse their matrix until one of their public fields changes.
	last_transform: Mesh_Transform,
	transform_cached: bool,
	visible:   bool,
	shadow_caster: Shadow_Caster,
	geometry:  ^Geometry,
	transform_matrix:    shared.Mat4,
	camera_space_matrix: shared.Mat4, // temporary - used during scene depth sort
	material:  ^Material,
	// Drawn through the scene's map batches while batching is enabled.
	batched:   bool,
}

Color_Cube :: struct {
	transform:  Mesh_Transform,
	mesh_count: i32,
	meshes:     [dynamic]^Mesh,
}

Player_Crouched_Leg :: struct {
	anchor: Mesh_Transform,
	upper:  ^Mesh,
	joint:  ^Mesh,
	lower:  ^Color_Cube,
}

Player_Arm_Mesh :: struct {
	extender: ^Mesh, // first person
	upper:    ^Mesh, // third person
	joint:    ^Mesh,
	lower:    ^Color_Cube,
	anchor:   Mesh_Transform,
	// Melee poses animate this parent without replacing the generated arm rest transform.
	pivot:    Mesh_Transform,
}

Player_Arms :: struct {
	anchor: Mesh_Transform,
	left:   ^Player_Arm_Mesh,
	right:  ^Player_Arm_Mesh,
	weapon_left:  ^Mesh,
	weapon_right: ^Mesh,
	attachment:   ^Mesh,
	// Per weapon rig, so peers and weapon swaps keep independent barrel cycles.
	next_left_muzzle: bool,
}

Player_Mesh :: struct {
	anchor:            ^Mesh_Transform,
	body_anchor:       ^Mesh_Transform,
	upper_body_anchor: ^Mesh_Transform,
	head:              ^Color_Cube,
	body:              ^Color_Cube,
	legs:              [2]^Color_Cube,
	crouched_legs:     [2]^Player_Crouched_Leg,
	arms:              [dynamic]^Player_Arms,
}

Scene :: struct {
	mesh_count:         i32,
	meshes:             [dynamic]^Mesh,
	transparent_meshes: [dynamic]^Mesh,
	transparent_sort_scratch: [dynamic]^Mesh,
	// Static map geometry merged into a few draws (map_batch.odin).
	batches:            ^Map_Batch_Set,
	batching_enabled:   bool,
}

Camera :: struct {
	near: f32,
	far:  f32,
	fov:  f32,
	zoom: f32,
	position:            shared.Vec3,
	rotation:            shared.Vec3,
	projection_matrix:   shared.Mat4,
	world_inverse_matrix: shared.Mat4,
}

// Screen size and scale for the interface; what it draws is queued in
// g_ui_batch (ui.odin).
UI :: struct {
	width:         f32,
	height:        f32,
	scale:         f32,
	vignette:      Gpu_Texture, // The damage overlay texture.
}

Glyph_Cache_Entry :: struct {
	atlas:     [2]i32, // top-left texel in the glyph atlas (ui.odin)
	in_atlas:  bool,   // false for empty glyphs (space)
	size:      shared.Vec2,
	h_bearing: shared.Vec2,
	v_bearing: shared.Vec2,
	advance:   f32,
}

Impact_Marker :: struct {
	object_index: i32,
	mesh:     ^Mesh,
	position: shared.Vec3,
	lifetime: f32,
}

Tracer_Marker :: struct {
	mesh:            ^Mesh,
	is_yours:        bool,
	direction:       shared.Vec3,
	start_position:  shared.Vec3,
	travel_distance: f32,
	distance:        f32,
	segment_length:  f32,
	speed:           f32,
	lifetime:        f32,
	total_lifetime:  f32,
	fade_lifetime:   f32,
}

// Asset caches (keyed by path)
g_geometry_cache: map[string]^Geometry
g_texture_cache:  map[string]^Texture_Cache_Entry
g_texture_by_id:  map[Gpu_Texture]^Texture_Cache_Entry
g_glyph_caches:   [Font_Slot][256]^Glyph_Cache_Entry // per font, see ui_use_font

g_resource_clock: u64

MAX_CACHED_TEXTURES :: 128
MAX_CACHED_GEOMETRIES :: 64

g_cube_geometry:  ^Geometry
g_plane_geometry: ^Geometry
g_ramp_geometry:  ^Geometry
g_sphere_geometry: ^Geometry

g_blank_texture:  Gpu_Texture
g_active_texture: Gpu_Texture
g_active_shader:  u32
