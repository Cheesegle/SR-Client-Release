package main

import "core:fmt"
import "core:math"
import "core:slice"
import gl "vendor:OpenGL"
import shared "../shared"

// Static map batching.
//
// Every opaque, static map object is merged into a few large vertex/index
// buffers, grouped by texture (plus wireframe and map-detail kind) and split
// into MAP_BATCH_CHUNK_SIZE XZ chunks for frustum culling. One draw call per
// visible batch replaces one draw call (and ~13 uniform uploads) per object.
//
// The picture must not change, so nothing is pre-transformed on the CPU: each
// vertex keeps its model-space position and original UV, plus its face index
// and an object index into a shader storage buffer that holds exactly the
// values the per-object path uploads as uniforms. basic.vert/basic.frag share
// all arithmetic between the two variants, so the GPU computes bit-identical
// positions, UVs, derivative normals and fog.

MAP_BATCH_CHUNK_SIZE :: f32(128)

// face_idx and object_index are whole numbers stored as f32 (exact below
// 2^24): float attributes are the one vertex format every driver gets right,
// unlike integer attributes set up with glVertexArrayAttribIFormat.
Batched_Vertex :: struct {
	position:     shared.Vec3,
	tex_coord:    shared.Vec2,
	face_idx:     f32,
	object_index: f32,
}

// Object indices must stay exact in an f32.
MAP_BATCH_MAX_OBJECTS :: 1 << 24

BATCH_FLAG_RAMP           :: 1
BATCH_FLAG_LADDER         :: 2
BATCH_FLAG_FACE_TEX_SCALE :: 4
BATCH_FLAG_UNLIT          :: 8
BATCH_FLAG_NO_FOG         :: 16
BATCH_FLAG_RECEIVE_SHADOW :: 32 // Basic_Material.receive_shadow
BATCH_FLAG_CAST_SHADOW    :: 64 // Mesh.shadow_caster == .STATIC (shadow depth pass)

// One object in the batched shader's storage buffer. basic.vert declares the
// buffer as a plain `vec4 objects[]` (std430 stride 16 on every driver; no
// struct, matrix or vec3 alignment rules involved) and reads field F of object
// i at objects[i * BATCH_OBJECT_VEC4S + BATCH_SLOT_F]. Those numbers are
// generated from this struct by map_batch_shader_defines, so the two sides
// cannot drift apart. Every field is a vec4 of plain floats; integers are
// stored as exact float values, never as bit patterns.
Batch_Object :: struct {
	transform:  shared.Mat4, // Column-major, as glUniformMatrix4fv uploads it.
	color:      shared.Vec4,
	emissive:   shared.Vec4,
	face_scale: shared.Vec4, // xyz face scale, w texture scale
	tex_row0:   shared.Vec4,
	tex_row1:   shared.Vec4,
	params:     shared.Vec4, // x face mask (0..63), y BATCH_FLAG_* bits (incl. receive/cast shadow), z alpha_test, w unused
}
#assert(size_of(Batch_Object) == 160)
#assert(size_of(Batch_Object) % 16 == 0)
BATCH_OBJECT_VEC4S :: size_of(Batch_Object) / 16

// The #defines basic.vert/basic.frag are compiled with for the BATCHED variants
// (colour pass, and the shadow depth pass with SHADOW_DEPTH_PASS added).
map_batch_shader_defines :: proc(allocator := context.allocator) -> string {
	return fmt.aprintf(
		"#define BATCHED\n#define BATCH_OBJECT_VEC4S %d\n#define BATCH_SLOT_TRANSFORM %d\n#define BATCH_SLOT_COLOR %d\n#define BATCH_SLOT_EMISSIVE %d\n#define BATCH_SLOT_FACE_SCALE %d\n#define BATCH_SLOT_TEX_ROW0 %d\n#define BATCH_SLOT_TEX_ROW1 %d\n#define BATCH_SLOT_PARAMS %d\n#define BATCH_FLAG_RECEIVE_SHADOW %d\n#define BATCH_FLAG_CAST_SHADOW %d\n",
		BATCH_OBJECT_VEC4S,
		offset_of(Batch_Object, transform) / 16,
		offset_of(Batch_Object, color) / 16,
		offset_of(Batch_Object, emissive) / 16,
		offset_of(Batch_Object, face_scale) / 16,
		offset_of(Batch_Object, tex_row0) / 16,
		offset_of(Batch_Object, tex_row1) / 16,
		offset_of(Batch_Object, params) / 16,
		BATCH_FLAG_RECEIVE_SHADOW,
		BATCH_FLAG_CAST_SHADOW,
		allocator = allocator,
	)
}

Map_Batch_Key :: struct {
	texture:   u32,
	wireframe: bool,
	detail:    Map_Detail,
	chunk_x:   i32,
	chunk_z:   i32,
}

Map_Batch :: struct {
	key:          Map_Batch_Key,
	single:       bool, // One mesh drawn individually, at this place in the order.
	first_index:  u32,
	index_count:  i32,
	bounds_min:   shared.Vec3,
	bounds_max:   shared.Vec3,
	member_start: int,
	member_count: int,
}

Map_Batch_Set :: struct {
	vao, vbo, ebo, ssbo: u32,
	program:      u32,
	batches:      [dynamic]Map_Batch,
	members:      [dynamic]^Mesh, // Grouped by slot, in draw order.
	vertex_count: int,
	index_count:  int,
	merged:       int, // Meshes merged into batch geometry.
	singles:      int, // Meshes drawn individually in the batch order.
	tie_excluded: int, // Eligible meshes moved to single slots to keep depth ties in order.
}

Draw_Stats :: struct {
	draw_calls:     int,
	batch_draws:    int,
	batches_culled: int,
	meshes_culled:  int,
}

// Reset by the caller (client_render_world, tests, bench) per frame.
g_draw_stats: Draw_Stats
// Benchmark switch: lets the batched path run with culling disabled.
g_render_culling := true

// Objects whose look or visibility changes after load stay on the per-object
// path: transparent meshes need per-frame sorting, objectives and score zones
// are transparent and toggled by match state, and animated/scrolling textures
// change their UV transform each frame.
map_batch_eligible :: proc(mesh: ^Mesh, object: ^shared.Object) -> bool {
	if mesh == nil || mesh.geometry == nil || mesh.geometry.index_count <= 0 || mesh.material == nil {
		return false
	}
	if mesh.material.vtable != &basic_material_vtable || mesh.material.transparent || mesh.material.no_depth_write {
		return false
	}
	if object != nil && (object.tex_anim != nil || object.objective || object.prefab == .OBJECTIVE || object.prefab == .SCORE_ZONE) {
		return false
	}
	// Authored-hidden objects are never drawn; parented meshes can move.
	return mesh.map_detail_visible && mesh.transform.parent == nil
}

// Mirrors the face index basic.vert derives from gl_VertexID.
batch_face_index :: proc(material: ^Basic_Material, vertex_id: int) -> u32 {
	if material.is_ramp {
		if vertex_id < 4 { return 0 }
		if vertex_id < 8 { return 1 }
		if vertex_id - 8 < 6 { return 2 }
		return 3
	}
	return u32(vertex_id / 4)
}

batch_object_from_material :: proc(material: ^Basic_Material, transform: shared.Mat4, caster := Shadow_Caster.NONE) -> Batch_Object {
	tex := basic_material_tex_transform(material)
	flags: i32
	if material.is_ramp { flags |= BATCH_FLAG_RAMP }
	if material.is_ladder { flags |= BATCH_FLAG_LADDER }
	if material.use_face_tex_scaling { flags |= BATCH_FLAG_FACE_TEX_SCALE }
	if material.unlit { flags |= BATCH_FLAG_UNLIT }
	if material.no_fog { flags |= BATCH_FLAG_NO_FOG }
	if material.receive_shadow { flags |= BATCH_FLAG_RECEIVE_SHADOW }
	if caster == .STATIC { flags |= BATCH_FLAG_CAST_SHADOW }
	return Batch_Object{
		transform  = transform,
		color      = material.color,
		emissive   = material.emissive,
		face_scale = {material.face_scale.x, material.face_scale.y, material.face_scale.z, material.texture_scale},
		tex_row0   = {tex[0][0], tex[0][1], tex[0][2], 0},
		tex_row1   = {tex[1][0], tex[1][1], tex[1][2], 0},
		params     = {f32(material.face_mask & 0x3f), f32(flags), material.alpha_test, 0},
	}
}

map_batch_chunk :: proc(center: shared.Vec3) -> (x, z: i32) {
	return i32(math.floor(center.x / MAP_BATCH_CHUNK_SIZE)), i32(math.floor(center.z / MAP_BATCH_CHUNK_SIZE))
}

// World-space box of a mesh's model-space bounds (the 8 transformed corners).
mesh_world_bounds :: proc(mesh: ^Mesh) -> (lo, hi: shared.Vec3) {
	g := mesh.geometry
	for i in 0 ..< 8 {
		corner := shared.Vec4{
			(i & 1) != 0 ? g.bounds_max.x : g.bounds_min.x,
			(i & 2) != 0 ? g.bounds_max.y : g.bounds_min.y,
			(i & 4) != 0 ? g.bounds_max.z : g.bounds_min.z,
			1,
		}
		p := (mesh.transform_matrix * corner).xyz
		if i == 0 {
			lo, hi = p, p
		} else {
			lo = {min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z)}
			hi = {max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z)}
		}
	}
	return
}

@(private = "file")
Geometry_Data :: struct {
	vertices: []Vertex,
	indices:  []u32,
}

@(private = "file")
geometry_read_back :: proc(geometry: ^Geometry) -> (data: Geometry_Data, ok: bool) {
	size: i32
	gl.GetNamedBufferParameteriv(geometry.vbo, gl.BUFFER_SIZE, &size)
	vertex_count := int(size) / size_of(Vertex)
	if vertex_count <= 0 || geometry.index_count <= 0 {
		return {}, false
	}
	data.vertices = make([]Vertex, vertex_count)
	data.indices = make([]u32, int(geometry.index_count))
	gl.GetNamedBufferSubData(geometry.vbo, 0, vertex_count * size_of(Vertex), raw_data(data.vertices))
	gl.GetNamedBufferSubData(geometry.ebo, 0, len(data.indices) * size_of(u32), raw_data(data.indices))
	for index in data.indices {
		if int(index) >= vertex_count {
			delete(data.vertices)
			delete(data.indices)
			return {}, false
		}
	}
	return data, true
}

@(private = "file")
Batch_Entry :: struct {
	mesh:     ^Mesh,
	lo, hi:   shared.Vec3,
	eligible: bool, // Can be merged into a batch.
	single:   bool, // Drawn individually, at its place in the batch order.
	key:      Map_Batch_Key,
	node:     int, // Draw-order slot; -1 leaves it to the ordinary mesh loop.
}

@(private = "file")
tie_near :: proc(a, b: f32) -> bool {
	return abs(a - b) <= 1e-4 * max(1, abs(a), abs(b))
}

// Coincident faces that point the same way and overlap with positive area.
map_batch_boxes_tie :: proc(a_lo, a_hi, b_lo, b_hi: shared.Vec3) -> bool {
	for axis in 0 ..< 3 {
		if !tie_near(a_lo[axis], b_lo[axis]) && !tie_near(a_hi[axis], b_hi[axis]) { continue }
		overlap := true
		for other in 0 ..< 3 {
			if other == axis { continue }
			if max(a_lo[other], b_lo[other]) >= min(a_hi[other], b_hi[other]) { overlap = false }
		}
		if overlap { return true }
	}
	return false
}

// Scene-ordered pairs (i < j) of opaque map meshes with coincident,
// same-facing, overlapping faces, where at least one can be batched.
@(private = "file")
map_batch_tie_pairs :: proc(entries: []Batch_Entry) -> [dynamic][2]int {
	pairs := make([dynamic][2]int)
	order := make([]int, len(entries))
	defer delete(order)
	for i in 0 ..< len(order) { order[i] = i }
	context.user_ptr = raw_data(entries)
	slice.sort_by(order, proc(a, b: int) -> bool {
		entries := cast([^]Batch_Entry)context.user_ptr
		return entries[a].lo.x < entries[b].lo.x
	})
	for oi in 0 ..< len(order) {
		a := &entries[order[oi]]
		for oj in oi + 1 ..< len(order) {
			b := &entries[order[oj]]
			// Sorted by lo.x: later boxes cannot overlap or share a face plane.
			if b.lo.x > a.hi.x && !tie_near(b.lo.x, a.hi.x) { break }
			if !a.eligible && !b.eligible { continue }
			if map_batch_boxes_tie(a.lo, a.hi, b.lo, b.hi) {
				append(&pairs, [2]int{min(order[oi], order[oj]), max(order[oi], order[oj])})
			}
		}
	}
	return pairs
}

// Opaque faces at equal depth resolve by draw order: GL_LESS keeps the first.
// Map authors stack coincident cubes on purpose (for example a face-masked
// overlay on a textured block), so batching must draw every such pair in
// scene order, as the per-object path does.
//
// Draw slots are batches (one per key) and single meshes. Slots are ordered
// topologically over the tied pairs. Tied meshes that cannot be batched get a
// single slot of their own. When the batches form a cycle, the members that
// block one batch are moved to single slots, choosing the batch that needs
// the fewest moves. Returns the slot count and the number of eligible meshes
// moved to single slots; entry.node is the slot's draw position.
@(private = "file")
map_batch_plan :: proc(entries: []Batch_Entry) -> (slots: int, extracted: int) {
	pairs := map_batch_tie_pairs(entries)
	defer delete(pairs)
	for pair in pairs {
		for index in pair {
			if !entries[index].eligible { entries[index].single = true }
		}
	}

	keyed := make(map[Map_Batch_Key]int)
	defer delete(keyed)
	node_keyed := make([dynamic]bool)
	defer delete(node_keyed)
	edges := make(map[[2]int]bool)
	defer delete(edges)
	out := make([dynamic][dynamic]int)
	defer {
		for list in out { delete(list) }
		delete(out)
	}
	indegree := make([dynamic]int)
	defer delete(indegree)
	emitted := make([dynamic]bool)
	defer delete(emitted)
	order := make([dynamic]int)
	defer delete(order)
	blockers := make([dynamic]int)
	defer delete(blockers)

	for {
		// Slots are numbered in scene order of their first member.
		clear(&keyed)
		clear(&node_keyed)
		for &entry in entries {
			entry.node = -1
			if entry.single {
				entry.node = len(node_keyed)
				append(&node_keyed, false)
			} else if entry.eligible {
				node, found := keyed[entry.key]
				if !found {
					node = len(node_keyed)
					keyed[entry.key] = node
					append(&node_keyed, true)
				}
				entry.node = node
			}
		}
		count := len(node_keyed)
		clear(&edges)
		for list in out { delete(list) }
		clear(&out)
		resize(&out, count)
		resize(&indegree, count)
		resize(&emitted, count)
		for i in 0 ..< count { indegree[i], emitted[i] = 0, false }
		for pair in pairs {
			edge := [2]int{entries[pair[0]].node, entries[pair[1]].node}
			if edge[0] == edge[1] || edge in edges { continue }
			edges[edge] = true
			append(&out[edge[0]], edge[1])
			indegree[edge[1]] += 1
		}

		// Kahn's algorithm, preferring the slot seen first in scene order.
		clear(&order)
		for len(order) < count {
			next := -1
			for node in 0 ..< count {
				if !emitted[node] && indegree[node] == 0 { next = node; break }
			}
			if next < 0 { break }
			emitted[next] = true
			append(&order, next)
			for v in out[next] { indegree[v] -= 1 }
		}
		if len(order) == count { break }

		// A cycle. Single slots alone cannot form one (their ties point
		// forward in scene order), so a batch is involved. Unblock the batch
		// with the fewest blocking members by moving them to single slots.
		resize(&blockers, count)
		for i in 0 ..< count { blockers[i] = 0 }
		for pair in pairs {
			u, v := entries[pair[0]].node, entries[pair[1]].node
			if u != v && !emitted[u] && !emitted[v] && node_keyed[v] { blockers[v] += 1 }
		}
		best := -1
		for node in 0 ..< count {
			if emitted[node] || !node_keyed[node] || blockers[node] == 0 { continue }
			if best < 0 || blockers[node] < blockers[best] { best = node }
		}
		assert(best >= 0)
		for pair in pairs {
			a, b := &entries[pair[0]], &entries[pair[1]]
			if b.node == best && a.node != best && !emitted[a.node] && !b.single {
				b.single = true
				extracted += 1
			}
		}
	}

	rank := make([]int, len(node_keyed))
	defer delete(rank)
	for node, position in order { rank[node] = position }
	for &entry in entries {
		if entry.node >= 0 { entry.node = rank[entry.node] }
	}
	return len(node_keyed), extracted
}

// Builds so far this session (diagnostics and tests).
g_map_batch_builds: int

// Builds the batches for every eligible map object. Meshes stay in the scene
// (bullet holes, map details and tests read them) and are marked `batched`
// when the batch pass draws them, merged or as a single slot.
map_batch_build :: proc(scene: ^Scene, map_inst: ^shared.Map) -> bool {
	g_map_batch_builds += 1
	map_batch_destroy(scene)
	if scene == nil || map_inst == nil {
		return false
	}
	program := basic_batched_program()
	if program == 0 {
		fmt.eprintln("[Render] Batched map shader unavailable; drawing map objects individually")
		return false
	}
	if g_map_batch_shader_layout_reason != "" {
		return false
	}

	// Every opaque map mesh takes part in the tie check; only eligible ones
	// can be merged.
	entries := make([dynamic]Batch_Entry)
	defer delete(entries)
	for object in map_inst.objects {
		if object == nil || object.mesh == nil { continue }
		mesh := cast(^Mesh)object.mesh
		if mesh.geometry == nil || !mesh.geometry.has_bounds || mesh.material == nil || mesh.material.transparent || mesh.material.no_depth_write || !mesh.map_detail_visible { continue }
		mesh_update_transform_matrix(mesh)
		entry := Batch_Entry{mesh = mesh, eligible = map_batch_eligible(mesh, object), node = -1}
		entry.lo, entry.hi = mesh_world_bounds(mesh)
		if entry.eligible {
			material := cast(^Basic_Material)mesh.material
			entry.key = Map_Batch_Key{texture = material.texture, wireframe = material.wireframe, detail = mesh.map_detail}
			entry.key.chunk_x, entry.key.chunk_z = map_batch_chunk((entry.lo + entry.hi) * 0.5)
		}
		append(&entries, entry)
	}
	slot_count, extracted := map_batch_plan(entries[:])

	// Slots in tie-safe order; members keep scene order.
	slotted := make([dynamic]Batch_Entry)
	defer delete(slotted)
	for entry in entries {
		if entry.node >= 0 { append(&slotted, entry) }
	}
	if len(slotted) == 0 {
		return false
	}
	slice.stable_sort_by(slotted[:], proc(a, b: Batch_Entry) -> bool { return a.node < b.node })

	geometry_data := make(map[^Geometry]Geometry_Data)
	defer {
		for _, data in geometry_data {
			delete(data.vertices)
			delete(data.indices)
		}
		delete(geometry_data)
	}

	set := new(Map_Batch_Set)
	set.program = program
	set.tie_excluded = extracted
	reserve(&set.batches, slot_count)
	vertices := make([dynamic]Batched_Vertex)
	defer delete(vertices)
	indices := make([dynamic]u32)
	defer delete(indices)
	objects := make([dynamic]Batch_Object)
	defer delete(objects)

	current := -1
	for entry in slotted {
		mesh := entry.mesh
		data: Geometry_Data
		if !entry.single {
			cached: bool
			data, cached = geometry_data[mesh.geometry]
			if !cached {
				ok: bool
				data, ok = geometry_read_back(mesh.geometry)
				if !ok {
					// Unreadable geometry: draw it on its own instead.
					append(&set.batches, Map_Batch{key = entry.key, single = true, bounds_min = entry.lo, bounds_max = entry.hi, member_start = len(set.members), member_count = 1})
					append(&set.members, mesh)
					current = -1
					continue
				}
				geometry_data[mesh.geometry] = data
			}
		}
		if entry.node != current || entry.single {
			current = entry.node
			append(&set.batches, Map_Batch{
				key          = entry.key,
				single       = entry.single,
				first_index  = u32(len(indices)),
				bounds_min   = entry.lo,
				bounds_max   = entry.hi,
				member_start = len(set.members),
			})
		}
		batch := &set.batches[len(set.batches) - 1]
		append(&set.members, mesh)
		batch.member_count += 1
		batch.bounds_min = {min(batch.bounds_min.x, entry.lo.x), min(batch.bounds_min.y, entry.lo.y), min(batch.bounds_min.z, entry.lo.z)}
		batch.bounds_max = {max(batch.bounds_max.x, entry.hi.x), max(batch.bounds_max.y, entry.hi.y), max(batch.bounds_max.z, entry.hi.z)}
		if entry.single {
			set.singles += 1
			continue
		}

		material := cast(^Basic_Material)mesh.material
		object_index := f32(len(objects))
		append(&objects, batch_object_from_material(material, mesh.transform_matrix, mesh.shadow_caster))
		set.merged += 1
		base := u32(len(vertices))
		for vertex, vertex_id in data.vertices {
			append(&vertices, Batched_Vertex{vertex.position, vertex.tex_coord, f32(batch_face_index(material, vertex_id)), object_index})
		}
		for t := 0; t + 2 < len(data.indices); t += 3 {
			// Faces are flat-shaded from the provoking (last) vertex. A masked
			// face is discarded by the shader, so leaving it out is identical.
			face := batch_face_index(material, int(data.indices[t + 2]))
			if face < 6 && material.face_mask & (u32(1) << face) == 0 { continue }
			append(&indices, base + data.indices[t], base + data.indices[t + 1], base + data.indices[t + 2])
		}
		batch.index_count = i32(u32(len(indices)) - batch.first_index)
	}

	max_block_size: i64
	gl.GetInteger64v(gl.MAX_SHADER_STORAGE_BLOCK_SIZE, &max_block_size)
	if len(objects) >= MAP_BATCH_MAX_OBJECTS || i64(len(objects) * size_of(Batch_Object)) > max_block_size {
		fmt.eprintf("[Render] Map batching skipped: %d objects exceed GL_MAX_SHADER_STORAGE_BLOCK_SIZE %d\n", len(objects), max_block_size)
		map_batch_set_free(set, members_alive = false)
		return false
	}
	when ODIN_TEST {
		// Simulates a driver that misreads the storage buffer.
		if g_map_batch_fault_inject {
			for &object in objects { object.transform = {} }
		}
	}

	for mesh in set.members {
		mesh.batched = true
	}
	set.vertex_count, set.index_count = len(vertices), len(indices)
	if len(vertices) > 0 && len(indices) > 0 {
		gl.CreateVertexArrays(1, &set.vao)
		gl.CreateBuffers(1, &set.vbo)
		gl.CreateBuffers(1, &set.ebo)
		gl.CreateBuffers(1, &set.ssbo)
		gl.NamedBufferStorage(set.vbo, len(vertices) * size_of(Batched_Vertex), raw_data(vertices), 0)
		gl.NamedBufferStorage(set.ebo, len(indices) * size_of(u32), raw_data(indices), 0)
		gl.NamedBufferStorage(set.ssbo, len(objects) * size_of(Batch_Object), raw_data(objects), 0)
		gl.VertexArrayVertexBuffer(set.vao, 0, set.vbo, 0, size_of(Batched_Vertex))
		gl.VertexArrayElementBuffer(set.vao, set.ebo)
		gl.VertexArrayAttribFormat(set.vao, 0, 3, gl.FLOAT, false, u32(offset_of(Batched_Vertex, position)))
		gl.VertexArrayAttribFormat(set.vao, 1, 2, gl.FLOAT, false, u32(offset_of(Batched_Vertex, tex_coord)))
		gl.VertexArrayAttribFormat(set.vao, 2, 1, gl.FLOAT, false, u32(offset_of(Batched_Vertex, face_idx)))
		gl.VertexArrayAttribFormat(set.vao, 3, 1, gl.FLOAT, false, u32(offset_of(Batched_Vertex, object_index)))
		for attrib in u32(0) ..< 4 {
			gl.EnableVertexArrayAttrib(set.vao, attrib)
			gl.VertexArrayAttribBinding(set.vao, attrib, 0)
		}
	}
	scene.batches = set
	return true
}


@(private = "file")
map_batch_set_free :: proc(set: ^Map_Batch_Set, members_alive := true) {
	if members_alive {
		for mesh in set.members {
			mesh.batched = false
		}
	}
	if set.vao != 0 { gl.DeleteVertexArrays(1, &set.vao) }
	if set.vbo != 0 { gl.DeleteBuffers(1, &set.vbo) }
	if set.ebo != 0 { gl.DeleteBuffers(1, &set.ebo) }
	if set.ssbo != 0 { gl.DeleteBuffers(1, &set.ssbo) }
	delete(set.batches)
	delete(set.members)
	free(set)
}

// Run before the member meshes are freed; at shutdown pass members_alive=false
// when they may already be gone.
map_batch_destroy :: proc(scene: ^Scene, members_alive := true) {
	if scene == nil || scene.batches == nil {
		return
	}
	map_batch_set_free(scene.batches, members_alive)
	scene.batches = nil
}

// --- Frustum culling ---------------------------------------------------------

Frustum :: struct {
	planes: [6]shared.Vec4, // xyz normal (pointing inside), w distance
}

// Gribb/Hartmann plane extraction from clip = projection * view.
frustum_from_camera :: proc(camera: ^Camera) -> Frustum {
	m := camera.projection_matrix * camera.world_inverse_matrix
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

// Conservative: a margin keeps boxes that only graze a plane.
FRUSTUM_MARGIN :: f32(1.0)

frustum_aabb_visible :: proc(f: ^Frustum, lo, hi: shared.Vec3) -> bool {
	for plane in f.planes {
		p := shared.Vec3{
			plane.x >= 0 ? hi.x : lo.x,
			plane.y >= 0 ? hi.y : lo.y,
			plane.z >= 0 ? hi.z : lo.z,
		}
		if plane.x * p.x + plane.y * p.y + plane.z * p.z + plane.w < -FRUSTUM_MARGIN {
			return false
		}
	}
	return true
}

frustum_sphere_visible :: proc(f: ^Frustum, center: shared.Vec3, radius: f32) -> bool {
	for plane in f.planes {
		if plane.x * center.x + plane.y * center.y + plane.z * center.z + plane.w < -(radius + FRUSTUM_MARGIN) {
			return false
		}
	}
	return true
}

// Bounding sphere of a mesh's geometry under its current transform matrix.
mesh_bounding_sphere :: proc(mesh: ^Mesh) -> (center: shared.Vec3, radius: f32, ok: bool) {
	g := mesh.geometry
	if g == nil || !g.has_bounds {
		return {}, 0, false
	}
	m := mesh.transform_matrix
	local_center := (g.bounds_min + g.bounds_max) * 0.5
	center = (m * shared.Vec4{local_center.x, local_center.y, local_center.z, 1}).xyz
	extent := (g.bounds_max - g.bounds_min) * 0.5
	local_radius := math.sqrt(extent.x * extent.x + extent.y * extent.y + extent.z * extent.z)
	scale: f32
	for c in 0 ..< 3 {
		column := shared.Vec3{m[0, c], m[1, c], m[2, c]}
		scale = max(scale, math.sqrt(column.x * column.x + column.y * column.y + column.z * column.z))
	}
	return center, local_radius * scale, true
}
