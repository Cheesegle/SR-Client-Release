package main

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import gl "vendor:OpenGL"
import stbi "vendor:stb/image"
import shared "../shared"

// NOTE: obj loading needs a cstring; keep it simple & allocate per call
load_obj_model :: proc(path: string, transform_y: bool) -> ^Geometry {
	if cached, ok := g_geometry_cache[path]; ok {
		cached.ref_count += 1
		cached.last_used = resource_touch()
		return cached
	}

	obj_data, ok := shared.read_file(path)
	if !ok {
		fmt.eprintf("Failed to read obj: %s\n", path)
		return nil
	}
	defer delete(obj_data)

	vertices := parse_obj(obj_data, transform_y)
	if vertices == nil {
		return nil
	}
	defer delete(vertices)

	indices := make([]u32, len(vertices))
	defer delete(indices)
	for i in 0 ..< len(vertices) {
		indices[i] = u32(i)
	}

	geometry := create_geometry(vertices, indices)
	geometry.cache_key = strings.clone(path)
	geometry.transform_y = transform_y
	geometry.ref_count = 1
	geometry.last_used = resource_touch()

	g_geometry_cache[geometry.cache_key] = geometry
	resource_trim_geometry_cache()

	return geometry
}

OBJ_Index :: struct {
	position: int,
	texcoord: int,
}

// Minimal OBJ parser (positions + independent texcoords, triangulated faces).
parse_obj :: proc(data: []byte, transform_y: bool) -> []Vertex {
	positions: [dynamic]shared.Vec3
	texcoords: [dynamic]shared.Vec2
	out: [dynamic]Vertex

	text := string(data)
	lines := strings.split_lines(text)
	defer delete(lines)

	bounds_min := shared.Vec3{9999.0, 9999.0, 9999.0}

	for line in lines {
		fields := strings.fields(line)
		if len(fields) == 0 {
			continue
		}

		switch fields[0] {
		case "v":
			if len(fields) >= 4 {
				append(&positions, shared.Vec3{
					strconv_f32(fields[1]),
					strconv_f32(fields[2]),
					strconv_f32(fields[3]),
				})
			}
		case "vt":
			if len(fields) >= 3 {
				append(&texcoords, shared.Vec2{
					strconv_f32(fields[1]),
					strconv_f32(fields[2]),
				})
			}
		case "f":
			// face indices are 1-based; support v or v/vt or v//vn
			if len(fields) >= 4 {
				face_idx := make([]OBJ_Index, len(fields) - 1)
				defer delete(face_idx)

				for i in 1 ..< len(fields) {
					parts := strings.split(fields[i], "/")

					if len(parts) > 0 {
						face_idx[i - 1].position = atoi_safe(parts[0])
					}
					if len(parts) > 1 && len(parts[1]) > 0 {
						face_idx[i - 1].texcoord = atoi_safe(parts[1])
					}

					delete(parts)
				}

				// triangulate fan
				for i := 1; i + 1 < len(face_idx); i += 1 {
					v0 := get_vertex(positions, texcoords, face_idx[0], &bounds_min)
					v1 := get_vertex(positions, texcoords, face_idx[i], &bounds_min)
					v2 := get_vertex(positions, texcoords, face_idx[i + 1], &bounds_min)

					append(&out, v0, v1, v2)
				}
			}
		}
	}

	delete(positions)
	delete(texcoords)

	if transform_y {
		for i in 0 ..< len(out) {
			out[i].position.y -= bounds_min.y
		}
	}

	return out[:]
}

get_vertex :: proc(
	positions: [dynamic]shared.Vec3,
	texcoords: [dynamic]shared.Vec2,
	index: OBJ_Index,
	bounds_min: ^shared.Vec3,
) -> Vertex {
	vertex := Vertex{}

	position_index := resolve_obj_index(index.position, len(positions))
	if position_index >= 0 && position_index < len(positions) {
		pos := positions[position_index]
		vertex.position = pos

		if pos.x < bounds_min.x {
			bounds_min.x = pos.x
		}
		if pos.y < bounds_min.y {
			bounds_min.y = pos.y
		}
		if pos.z < bounds_min.z {
			bounds_min.z = pos.z
		}
	}

	texcoord_index := resolve_obj_index(index.texcoord, len(texcoords))
	if texcoord_index >= 0 && texcoord_index < len(texcoords) {
		vertex.tex_coord = texcoords[texcoord_index]
	}

	return vertex
}

resolve_obj_index :: proc(index, count: int) -> int {
	if index > 0 {
		return index - 1
	}
	if index < 0 {
		return count + index
	}

	return -1
}

strconv_f32 :: proc(s: string) -> f32 {
	f, _ := strconv_parse_f32(s)
	return f
}

strconv_parse_f32 :: proc(s: string) -> (f32, bool) {
	if len(s) == 0 {
		return 0, false
	}

	// use fmt/parse for accuracy
	val, ok := parse_float(s)
	return val, ok
}

parse_float :: proc(s: string) -> (f32, bool) {
	// simple fallback: use the standard library via strconv
	// (implemented as a tiny helper to avoid pulling heavy deps)
	val: f32
	neg := false
	idx := 0

	if idx < len(s) && (s[idx] == '-' || s[idx] == '+') {
		neg = s[idx] == '-'
		idx += 1
	}

	int_part: f32
	has_digit := false

	for idx < len(s) && s[idx] >= '0' && s[idx] <= '9' {
		int_part = int_part * 10 + f32(s[idx] - '0')
		idx += 1
		has_digit = true
	}

	frac: f32
	scale := 1.0

	if idx < len(s) && s[idx] == '.' {
		idx += 1

		for idx < len(s) && s[idx] >= '0' && s[idx] <= '9' {
			frac = frac * 10 + f32(s[idx] - '0')
			scale *= 10
			idx += 1
			has_digit = true
		}
	}

	if !has_digit {
		return 0, false
	}

	val = int_part + frac / f32(scale)

	if idx < len(s) && (s[idx] == 'e' || s[idx] == 'E') {
		idx += 1
		exp_neg := false

		if idx < len(s) && (s[idx] == '-' || s[idx] == '+') {
			exp_neg = s[idx] == '-'
			idx += 1
		}

		exp: i32
		for idx < len(s) && s[idx] >= '0' && s[idx] <= '9' {
			exp = exp * 10 + i32(s[idx] - '0')
			idx += 1
		}

		if exp_neg {
			exp = -exp
		}

		power := f32(1.0)
		if exp > 0 {
			for i in 0 ..< exp {
				power *= 10
			}
		} else {
			for i in 0 ..< -exp {
				power /= 10
			}
		}

		val *= power
	}

	if neg {
		val = -val
	}

	return val, true
}

atoi_safe :: proc(s: string) -> int {
	if len(s) == 0 {
		return 0
	}

	n := 0
	neg := false
	idx := 0

	if s[idx] == '-' {
		neg = true
		idx += 1
	}

	for idx < len(s) && s[idx] >= '0' && s[idx] <= '9' {
		n = n * 10 + int(s[idx] - '0')
		idx += 1
	}

	if neg {
		n = -n
	}

	return n
}

create_cube_geo :: proc() -> ^Geometry {
	if g_cube_geometry != nil {
		return g_cube_geometry
	}

	// FRONT/BACK/LEFT/RIGHT/TOP/BOTTOM quads (position + texcoord)
	cube_vertices := [?]Vertex{
		// FRONT
		{{-0.5, 0.0, 0.5}, {0.0, 0.0}},
		{{0.5, 1.0, 0.5}, {1.0, 1.0}},
		{{-0.5, 1.0, 0.5}, {0.0, 1.0}},
		{{0.5, 0.0, 0.5}, {1.0, 0.0}},
		// BACK
		{{0.5, 0.0, -0.5}, {0.0, 0.0}},
		{{-0.5, 1.0, -0.5}, {1.0, 1.0}},
		{{0.5, 1.0, -0.5}, {0.0, 1.0}},
		{{-0.5, 0.0, -0.5}, {1.0, 0.0}},
		// LEFT
		{{-0.5, 0.0, -0.5}, {0.0, 0.0}},
		{{-0.5, 1.0, 0.5}, {1.0, 1.0}},
		{{-0.5, 1.0, -0.5}, {0.0, 1.0}},
		{{-0.5, 0.0, 0.5}, {1.0, 0.0}},
		// RIGHT
		{{0.5, 0.0, 0.5}, {0.0, 0.0}},
		{{0.5, 1.0, -0.5}, {1.0, 1.0}},
		{{0.5, 1.0, 0.5}, {0.0, 1.0}},
		{{0.5, 0.0, -0.5}, {1.0, 0.0}},
		// TOP
		{{-0.5, 1.0, 0.5}, {0.0, 0.0}},
		{{0.5, 1.0, -0.5}, {1.0, 1.0}},
		{{-0.5, 1.0, -0.5}, {0.0, 1.0}},
		{{0.5, 1.0, 0.5}, {1.0, 0.0}},
		// BOTTOM
		{{-0.5, 0.0, -0.5}, {0.0, 0.0}},
		{{0.5, 0.0, 0.5}, {1.0, 1.0}},
		{{-0.5, 0.0, 0.5}, {0.0, 1.0}},
		{{0.5, 0.0, -0.5}, {1.0, 0.0}},
	}

	cube_indices := [?]u32{
		0, 1, 2, 0, 3, 1, // FRONT
		4, 5, 6, 4, 7, 5, // BACK
		8, 9, 10, 8, 11, 9, // LEFT
		12, 13, 14, 12, 15, 13, // RIGHT
		16, 17, 18, 16, 19, 17, // TOP
		20, 21, 22, 20, 23, 21, // BOTTOM
	}

	g_cube_geometry = create_geometry(cube_vertices[:], cube_indices[:])
	g_cube_geometry.permanent = true
	return g_cube_geometry
}

create_plane_geo :: proc() -> ^Geometry {
	if g_plane_geometry != nil {
		return g_plane_geometry
	}

	plane_vertices := [?]Vertex{
		{{-0.5, 1.0, 0.5}, {0.0, 0.0}},
		{{0.5, 1.0, -0.5}, {1.0, 1.0}},
		{{-0.5, 1.0, -0.5}, {0.0, 1.0}},
		{{0.5, 1.0, 0.5}, {1.0, 0.0}},
	}

	plane_indices := [?]u32{0, 1, 2, 0, 3, 1}

	g_plane_geometry = create_geometry(plane_vertices[:], plane_indices[:])
	g_plane_geometry.permanent = true
	return g_plane_geometry
}

create_ramp_geo :: proc() -> ^Geometry {
	if g_ramp_geometry != nil {
		return g_ramp_geometry
	}

	ramp_vertices := [?]Vertex{
		// TOP
		{{-0.5, 0.0, 0.5}, {0.0, 0.0}},
		{{0.5, 1.0, -0.5}, {1.0, 1.0}},
		{{-0.5, 1.0, -0.5}, {0.0, 1.0}},
		{{0.5, 0.0, 0.5}, {1.0, 0.0}},
		// BOTTOM
		{{-0.5, 0.0, -0.5}, {0.0, 0.0}},
		{{0.5, 0.0, 0.5}, {1.0, 1.0}},
		{{-0.5, 0.0, 0.5}, {0.0, 1.0}},
		{{0.5, 0.0, -0.5}, {1.0, 0.0}},
		// LEFT
		{{-0.5, 0.0, -0.5}, {0.0, 0.0}},
		{{-0.5, 0.0, 0.5}, {1.0, 0.0}},
		{{-0.5, 1.0, -0.5}, {0.0, 1.0}},
		// RIGHT
		{{0.5, 0.0, 0.5}, {0.0, 0.0}},
		{{0.5, 0.0, -0.5}, {1.0, 0.0}},
		{{0.5, 1.0, -0.5}, {0.0, 1.0}},
		// BACK
		{{0.5, 0.0, -0.5}, {0.0, 0.0}},
		{{-0.5, 1.0, -0.5}, {1.0, 1.0}},
		{{0.5, 1.0, -0.5}, {0.0, 1.0}},
		{{-0.5, 0.0, -0.5}, {1.0, 0.0}},
	}

	ramp_indices := [?]u32{
		0, 1, 2, 0, 3, 1, // TOP
		4, 5, 6, 4, 7, 5, // BOTTOM
		8, 9, 10, // LEFT
		11, 12, 13, // RIGHT
		14, 15, 16, 14, 17, 15, // BACK
	}

	g_ramp_geometry = create_geometry(ramp_vertices[:], ramp_indices[:])
	g_ramp_geometry.permanent = true
	return g_ramp_geometry
}

// Krunker's SPHERE prefab: generateSphere -> THREE.SphereGeometry(1, 12, 8)
// scaled by size/2 and moved to y + height/2 (addSphere). Built here as a
// unit-diameter sphere resting on y = 0, like the cube, so the object's
// position and scale place it exactly as Krunker does. Same vertex order and
// UVs as three.js.
SPHERE_WIDTH_SEGMENTS :: 12
SPHERE_HEIGHT_SEGMENTS :: 8

// Krunker's CYLINDER prefab: generateCylinder -> THREE.CylinderGeometry with
// radiusTop/radiusBottom 1, height 1, `sides || 12` radial segments and both
// caps, scaled by (min(w, l)/2, h, min(w, l)/2). Built here like the sphere:
// unit diameter, resting on y = 0, so the object's position is the base and
// its rotation pivots there (Burg's cart wheels and axles, rotated -90 deg
// around z, line up only with that pivot). Side UVs wrap once around (u) and
// run up the height (v); caps use three.js's radial cap UVs.
CYLINDER_SIDES :: 12

create_cylinder_geo :: proc() -> ^Geometry {
	if g_cylinder_geometry != nil {
		return g_cylinder_geometry
	}

	vertices: [dynamic]Vertex
	defer delete(vertices)
	indices: [dynamic]u32
	defer delete(indices)

	// Side: two rings (top first, as three.js does), one extra seam column.
	for row in 0 ..= 1 {
		y: f32 = row == 0 ? 1 : 0
		for ix in 0 ..= CYLINDER_SIDES {
			u := f32(ix) / CYLINDER_SIDES
			theta := u * 2 * math.PI
			append(&vertices, Vertex{{0.5 * math.sin(theta), y, 0.5 * math.cos(theta)}, {u, 1 - f32(row)}})
		}
	}
	for ix in 0 ..< CYLINDER_SIDES {
		a := u32(ix)
		b := u32(CYLINDER_SIDES + 1 + ix)
		c := u32(CYLINDER_SIDES + 1 + ix + 1)
		d := u32(ix + 1)
		append(&indices, a, b, d, b, c, d)
	}

	// Caps: a centre per segment and a rim, as three.js generateCap.
	for top in ([2]bool{true, false}) {
		y: f32 = top ? 1 : 0
		sign: f32 = top ? 1 : -1
		centre_start := u32(len(vertices))
		for _ in 1 ..= CYLINDER_SIDES {
			append(&vertices, Vertex{{0, y, 0}, {0.5, 0.5}})
		}
		rim_start := u32(len(vertices))
		for ix in 0 ..= CYLINDER_SIDES {
			theta := f32(ix) / CYLINDER_SIDES * 2 * math.PI
			cos_t, sin_t := math.cos(theta), math.sin(theta)
			append(&vertices, Vertex{{0.5 * sin_t, y, 0.5 * cos_t}, {0.5 * cos_t + 0.5, 0.5 * sin_t * sign + 0.5}})
		}
		for ix in 0 ..< u32(CYLINDER_SIDES) {
			centre, rim := centre_start + ix, rim_start + ix
			if top { append(&indices, rim, rim + 1, centre) } else { append(&indices, rim + 1, rim, centre) }
		}
	}

	g_cylinder_geometry = create_geometry(vertices[:], indices[:])
	g_cylinder_geometry.permanent = true
	return g_cylinder_geometry
}

create_sphere_geo :: proc() -> ^Geometry {
	if g_sphere_geometry != nil {
		return g_sphere_geometry
	}

	vertices: [(SPHERE_WIDTH_SEGMENTS + 1) * (SPHERE_HEIGHT_SEGMENTS + 1)]Vertex
	for iy in 0 ..= SPHERE_HEIGHT_SEGMENTS {
		v := f32(iy) / SPHERE_HEIGHT_SEGMENTS
		for ix in 0 ..= SPHERE_WIDTH_SEGMENTS {
			u := f32(ix) / SPHERE_WIDTH_SEGMENTS
			phi, theta := u * 2 * math.PI, v * math.PI
			vertices[iy * (SPHERE_WIDTH_SEGMENTS + 1) + ix] = {
				{-0.5 * math.cos(phi) * math.sin(theta), 0.5 + 0.5 * math.cos(theta), 0.5 * math.sin(phi) * math.sin(theta)},
				{u, 1 - v},
			}
		}
	}

	indices: [dynamic]u32
	defer delete(indices)
	for iy in 0 ..< SPHERE_HEIGHT_SEGMENTS {
		for ix in 0 ..< SPHERE_WIDTH_SEGMENTS {
			a := u32(iy * (SPHERE_WIDTH_SEGMENTS + 1) + ix + 1)
			b := u32(iy * (SPHERE_WIDTH_SEGMENTS + 1) + ix)
			c := u32((iy + 1) * (SPHERE_WIDTH_SEGMENTS + 1) + ix)
			d := u32((iy + 1) * (SPHERE_WIDTH_SEGMENTS + 1) + ix + 1)
			if iy != 0 { append(&indices, a, b, d) }
			if iy != SPHERE_HEIGHT_SEGMENTS - 1 { append(&indices, b, c, d) }
		}
	}

	g_sphere_geometry = create_geometry(vertices[:], indices[:])
	g_sphere_geometry.permanent = true
	return g_sphere_geometry
}

// Uploads the mesh and keeps a CPU copy of both arrays (geometry.vertices and
// .indices) for map batching. Indices must be in range of `vertices`.
create_geometry :: proc(vertices: []Vertex, indices: []u32) -> ^Geometry {
	geometry := new(Geometry)
	geometry_upload(geometry, vertices, indices)
	geometry.ref_count = 1
	return geometry
}

// (Re)builds the geometry's CPU copies and GPU buffers from `vertices` and
// `indices`; a live mod reload replaces a model's data this way.
geometry_upload :: proc(geometry: ^Geometry, vertices: []Vertex, indices: []u32) {
	gpu_vertex_input_destroy(&geometry.input)
	gpu_buffer_destroy(&geometry.vertex_buffer)
	gpu_buffer_destroy(&geometry.index_buffer)
	delete(geometry.vertices)
	delete(geometry.indices)
	geometry.vertices = make([]Vertex, len(vertices))
	geometry.indices = make([]u32, len(indices))
	copy(geometry.vertices, vertices)
	copy(geometry.indices, indices)

	geometry.vertex_buffer = gpu_buffer_create(.Vertex, slice.to_bytes(geometry.vertices))
	geometry.index_buffer = gpu_buffer_create(.Index, slice.to_bytes(geometry.indices))
	geometry.input = gpu_vertex_input_create(.Basic, geometry.vertex_buffer, geometry.index_buffer)
	geometry.index_count = i32(len(indices))
	geometry_set_bounds(geometry, vertices)
}

geometry_set_bounds :: proc(geometry: ^Geometry, vertices: []Vertex) {
	if len(vertices) == 0 {
		return
	}
	geometry.bounds_min = vertices[0].position
	geometry.bounds_max = vertices[0].position
	for vertex in vertices[1:] {
		geometry.bounds_min = {min(geometry.bounds_min.x, vertex.position.x), min(geometry.bounds_min.y, vertex.position.y), min(geometry.bounds_min.z, vertex.position.z)}
		geometry.bounds_max = {max(geometry.bounds_max.x, vertex.position.x), max(geometry.bounds_max.y, vertex.position.y), max(geometry.bounds_max.z, vertex.position.z)}
	}
	geometry.has_bounds = true
}

create_ladder_geo :: proc(height: f32) -> ^Geometry {
	steps := int(height / 6.0)

	vertices: [dynamic]Vertex
	indices: [dynamic]u32
	defer delete(vertices)
	defer delete(indices)

	// two rails using the cube
	for i in 0 ..< 2 {
		v_offset := len(vertices)

		rails := [?]Vertex{
			// FRONT
			{{-0.5, 0.0, 0.5}, {0.0, 0.0}},
			{{0.5, 1.0, 0.5}, {1.0, 1.0}},
			{{-0.5, 1.0, 0.5}, {0.0, 1.0}},
			{{0.5, 0.0, 0.5}, {1.0, 0.0}},
			// BACK
			{{0.5, 0.0, -0.5}, {0.0, 0.0}},
			{{-0.5, 1.0, -0.5}, {1.0, 1.0}},
			{{0.5, 1.0, -0.5}, {0.0, 1.0}},
			{{-0.5, 0.0, -0.5}, {1.0, 0.0}},
			// LEFT
			{{-0.5, 0.0, -0.5}, {0.0, 0.0}},
			{{-0.5, 1.0, 0.5}, {1.0, 1.0}},
			{{-0.5, 1.0, -0.5}, {0.0, 1.0}},
			{{-0.5, 0.0, 0.5}, {1.0, 0.0}},
			// RIGHT
			{{0.5, 0.0, 0.5}, {0.0, 0.0}},
			{{0.5, 1.0, -0.5}, {1.0, 1.0}},
			{{0.5, 1.0, 0.5}, {0.0, 1.0}},
			{{0.5, 0.0, -0.5}, {1.0, 0.0}},
			// TOP
			{{-0.5, 1.0, 0.5}, {0.0, 0.0}},
			{{0.5, 1.0, -0.5}, {1.0, 1.0}},
			{{-0.5, 1.0, -0.5}, {0.0, 1.0}},
			{{0.5, 1.0, 0.5}, {1.0, 0.0}},
			// BOTTOM
			{{-0.5, 0.0, -0.5}, {0.0, 0.0}},
			{{0.5, 0.0, 0.5}, {1.0, 1.0}},
			{{-0.5, 0.0, 0.5}, {0.0, 1.0}},
			{{0.5, 0.0, -0.5}, {1.0, 0.0}},
		}

		rail_indices := [?]u32{
			0, 1, 2, 0, 3, 1, 4, 5, 6, 4, 7, 5, 8, 9, 10, 8, 11, 9, 12, 13, 14, 12, 15, 13, 16, 17, 18, 16, 19, 17, 20, 21, 22, 20, 23, 21,
		}

		for v in rails {
			scaled := v
			scaled.position.x *= shared.GAME_CONSTANTS.ladder_scale * 2.0
			scaled.position.z *= shared.GAME_CONSTANTS.ladder_scale * 2.0
			scaled.position.y *= height + 2.0
			scaled.position.x += shared.GAME_CONSTANTS.ladder_width * (i == 1 ? 1.0 : -1.0)

			append(&vertices, scaled)
		}

		for idx in rail_indices {
			append(&indices, u32(v_offset) + idx)
		}
	}

	for i in 0 ..< steps {
		v_offset := len(vertices)

		step_vertices := [?]Vertex{
			{{-0.5, 1.0, 0.5}, {0.0, 0.0}},
			{{0.5, 1.0, -0.5}, {1.0, 1.0}},
			{{-0.5, 1.0, -0.5}, {0.0, 1.0}},
			{{0.5, 1.0, 0.5}, {1.0, 0.0}},
		}

		for v in step_vertices {
			scaled := v
			scaled.position.y -= 1.0
			scaled.position.x *= shared.GAME_CONSTANTS.ladder_width * 2.0
			scaled.position.z *= shared.GAME_CONSTANTS.ladder_scale * 2.0

			// rotate ~90deg about x
			tmp_y := scaled.position.y
			tmp_z := scaled.position.z
			scaled.position.y = tmp_y * math.cos(PI * 0.5) + tmp_z * -math.sin(PI * 0.5)
			scaled.position.z = tmp_y * math.sin(PI * 0.5) + tmp_z * math.cos(PI * 0.5)

			scaled.position.y += f32(i + 1) * 6.0

			append(&vertices, scaled)
		}

		append(&indices, u32(v_offset), u32(v_offset) + 1, u32(v_offset) + 2, u32(v_offset), u32(v_offset) + 3, u32(v_offset) + 1)
	}

	geometry := create_geometry(vertices[:], indices[:])
	return geometry
}

PI: f32 = 3.14159265358979323846

// texture loading with cache
load_texture :: proc(path: string) -> Gpu_Texture {
	if cached, ok := g_texture_cache[path]; ok {
		cached.ref_count += 1
		cached.last_used = resource_touch()
		return cached.id
	}

	c_path := strings.clone_to_cstring(shared.mod_resolve(path))
	defer delete(c_path)

	stbi.set_flip_vertically_on_load(1)

	w, h, channels: i32
	data := stbi.load(c_path, &w, &h, &channels, 4)
	shared.asset_trace(path, data != nil)

	if data == nil {
		return 0
	}
	defer stbi.image_free(data)

	// Mips are built but not sampled through this texture's own filter (sharp,
	// no mip selection); the world pass's graphics sampler does use them.
	texture_id := gpu_texture_create({
		width = w, height = h, format = .RGBA8, mipmaps = true,
		sampler = {filter = .Nearest, wrap = .Repeat},
	}, data[:int(w) * int(h) * 4])
	if texture_id == 0 {
		return 0
	}

	entry := new(Texture_Cache_Entry)
	entry.id = texture_id
	entry.width = w
	entry.height = h
	entry.cache_key = strings.clone(path)
	entry.ref_count = 1
	entry.last_used = resource_touch()

	g_texture_cache[entry.cache_key] = entry
	g_texture_by_id[texture_id] = entry
	resource_trim_texture_cache()

	return texture_id
}

resource_touch :: proc() -> u64 {
	g_resource_clock += 1
	return g_resource_clock
}

geometry_release :: proc(geometry: ^Geometry) {
	if geometry == nil || geometry.permanent {
		return
	}

	if geometry.ref_count > 0 {
		geometry.ref_count -= 1
	}
	geometry.last_used = resource_touch()

	if len(geometry.cache_key) == 0 {
		geometry_destroy(geometry)
	} else {
		resource_trim_geometry_cache()
	}
}

texture_release :: proc(texture_id: Gpu_Texture) {
	if texture_id == 0 {
		return
	}

	entry, ok := g_texture_by_id[texture_id]
	if !ok {
		return
	}

	if entry.ref_count > 0 {
		entry.ref_count -= 1
	}
	entry.last_used = resource_touch()
	resource_trim_texture_cache()
}

geometry_destroy :: proc(geometry: ^Geometry) {
	if geometry == nil {
		return
	}

	gpu_vertex_input_destroy(&geometry.input)
	gpu_buffer_destroy(&geometry.vertex_buffer)
	gpu_buffer_destroy(&geometry.index_buffer)
	delete(geometry.vertices)
	delete(geometry.indices)
	free(geometry)
}

resource_trim_texture_cache :: proc(force: bool = false) {
	for force || len(g_texture_cache) > MAX_CACHED_TEXTURES {
		oldest: ^Texture_Cache_Entry
		for _, entry in g_texture_cache {
			if entry.ref_count == 0 && (oldest == nil || entry.last_used < oldest.last_used) {
				oldest = entry
			}
		}

		if oldest == nil {
			break
		}

		delete_key(&g_texture_cache, oldest.cache_key)
		delete_key(&g_texture_by_id, oldest.id)
		gpu_texture_destroy(&oldest.id)
		delete(oldest.cache_key)
		free(oldest)
	}
}

resource_trim_geometry_cache :: proc(force: bool = false) {
	for force || len(g_geometry_cache) > MAX_CACHED_GEOMETRIES {
		oldest: ^Geometry
		for _, geometry in g_geometry_cache {
			if geometry.ref_count == 0 && (oldest == nil || geometry.last_used < oldest.last_used) {
				oldest = geometry
			}
		}

		if oldest == nil {
			break
		}

		delete_key(&g_geometry_cache, oldest.cache_key)
		key := oldest.cache_key
		oldest.cache_key = ""
		geometry_destroy(oldest)
		delete(key)
	}
}

resource_cache_stats :: proc() -> (textures, geometries: int, estimated_texture_bytes: u64) {
	textures = len(g_texture_cache)
	geometries = len(g_geometry_cache)
	for _, entry in g_texture_cache {
		estimated_texture_bytes += u64(entry.width) * u64(entry.height) * 4
	}
	return
}

resource_print_stats :: proc(label: string) {
	textures, geometries, texture_bytes := resource_cache_stats()
	fmt.printf(
		"[Assets] %s: %d textures (~%.1f MiB RGBA), %d OBJ geometries\n",
		label,
		textures,
		f64(texture_bytes) / (1024.0 * 1024.0),
		geometries,
	)
}

resource_cache_fini :: proc() {
	resource_trim_texture_cache(true)
	resource_trim_geometry_cache(true)
	// Textures still referenced (HUD icons, menu portraits, kill feed icons
	// keep theirs for the whole session) go too: nothing draws after this.
	for _, entry in g_texture_cache {
		id := entry.id
		gpu_texture_destroy(&id)
		delete(entry.cache_key)
		free(entry)
	}
	delete(g_texture_cache)
	delete(g_texture_by_id)
	delete(g_geometry_cache)
	g_texture_cache = nil
	g_texture_by_id = nil
	g_geometry_cache = nil
	// Contexts can be destroyed and recreated by renderer tests. Cached GL
	// bindings from the old context must never suppress binds in the new one.
	g_active_texture = 0
	g_active_shader = 0

	if g_cube_geometry != nil {
		geometry_destroy(g_cube_geometry)
		g_cube_geometry = nil
	}
	if g_plane_geometry != nil {
		geometry_destroy(g_plane_geometry)
		g_plane_geometry = nil
	}
	if g_ramp_geometry != nil {
		geometry_destroy(g_ramp_geometry)
		g_ramp_geometry = nil
	}
	if g_sphere_geometry != nil {
		geometry_destroy(g_sphere_geometry)
		g_sphere_geometry = nil
	}
	if g_cylinder_geometry != nil {
		geometry_destroy(g_cylinder_geometry)
		g_cylinder_geometry = nil
	}
	gpu_texture_destroy(&g_blank_texture)
	gpu_texture_destroy(&g_impact_texture)

	gpu_program_destroy(&basic_shader_program)
	gpu_program_destroy(&basic_batched_shader_program)
	g_map_batch_shader_layout_reason = ""
	shadow_placeholders_fini()
	gpu_uniforms_fini()
	gpu_program_destroy(&g_ui_program)
}
