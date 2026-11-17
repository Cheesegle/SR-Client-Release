#version 450 core
// BATCHED (injected by shader_compile) draws many static map objects in one
// call. Each vertex keeps its object's model-space position and original UV;
// the per-object values come from an SSBO instead of uniforms. All arithmetic
// below is shared, so both variants produce bit-identical results.
//
// Portability (Intel/AMD): the batched inputs avoid integer vertex attributes,
// structs and matrices in the storage buffer, and integer bit patterns stored
// in floats. Every value is an exact float in a flat vec4 array whose slot
// numbers (BATCH_*) are generated from the Odin Batch_Object layout.
layout (location = 0) in vec3 v_pos;
layout (location = 1) in vec2 v_tex_coord;

out vec2 tex_coord;
flat out int face_idx;
out vec3 world_pos;

uniform mat4 camera_world_inverse;
uniform mat4 camera_projection;

// Batched and per-object draws of coincident faces must store the same depth
// (draw order resolves the tie), so the position math may not be refactored
// differently per program: invariant + precise.
invariant gl_Position;

#ifdef BATCHED
// Small integers as floats: exact below 2^24.
layout (location = 2) in float v_face_idx;
layout (location = 3) in float v_object;
// Per-object values, read once per vertex and passed on unchanged (flat).
flat out vec4 b_color;
flat out vec4 b_emissive;
flat out vec4 b_face_scale; // xyz face scale, w texture scale
flat out vec4 b_tex_row0;
flat out vec4 b_tex_row1;
flat out vec4 b_params; // x face mask, y BATCH_FLAG_* bits, z alpha_test

// BATCH_OBJECT_VEC4S vec4s per object (map_batch.odin Batch_Object).
layout (std430, binding = 0) readonly buffer Batch_Objects {
    vec4 objects[];
};
#else
uniform bool is_ramp;
uniform mat4 transform;
#endif

void main() {
    tex_coord = v_tex_coord;
#ifdef BATCHED
    int base = int(v_object + 0.5) * BATCH_OBJECT_VEC4S;
    mat4 m_transform = mat4(
        objects[base + BATCH_SLOT_TRANSFORM + 0],
        objects[base + BATCH_SLOT_TRANSFORM + 1],
        objects[base + BATCH_SLOT_TRANSFORM + 2],
        objects[base + BATCH_SLOT_TRANSFORM + 3]);
#else
    mat4 m_transform = transform;
#endif
    precise vec3 p_world = vec3(m_transform * vec4(v_pos, 1.0));
    world_pos = p_world;

#ifdef BATCHED
    // Computed on the CPU with the per-object rule below.
    face_idx = int(v_face_idx + 0.5);
    b_color = objects[base + BATCH_SLOT_COLOR];
    b_emissive = objects[base + BATCH_SLOT_EMISSIVE];
    b_face_scale = objects[base + BATCH_SLOT_FACE_SCALE];
    b_tex_row0 = objects[base + BATCH_SLOT_TEX_ROW0];
    b_tex_row1 = objects[base + BATCH_SLOT_TEX_ROW1];
    b_params = objects[base + BATCH_SLOT_PARAMS];
#else
    if (is_ramp) {
        if (gl_VertexID < 4) face_idx = 0;
        else if (gl_VertexID < 8) face_idx = 1;
        else if (gl_VertexID - 8 < 6) face_idx = 2;
        else face_idx = 3;
    } else {
		// Cube geometry uses four unique indexed vertices per face.
		face_idx = gl_VertexID / 4;
    }
#endif

    precise vec4 p_clip = camera_projection * camera_world_inverse * vec4(p_world, 1.0);
    gl_Position = p_clip;
#if defined(BATCHED) && defined(SHADOW_DEPTH_PASS)
    // Batches mix casters with receive-only objects (ramps, planes): move the
    // latter outside the clip volume so the shadow map never sees them.
    if ((int(b_params.y + 0.5) & BATCH_FLAG_CAST_SHADOW) == 0) gl_Position = vec4(2.0, 2.0, 2.0, 1.0);
#endif
}
