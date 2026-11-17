#version 450 core
// World geometry. Variants (shader_compile inserts the #defines, see
// basic_shader_defines in materials.odin): BATCHED draws many static map
// objects in one call; SHADOW_DEPTH_PASS renders a shadow map. The
// BATCH_SLOT_* / BATCH_FLAG_* numbers are always defined, generated from the
// Odin Batch_Object layout.
//
// Every draw reads its object as one Batch_Object record of vec4s: a per-draw
// uniform block for single objects, a storage buffer indexed per vertex for
// batches. Both variants decode the record with the same code below, so they
// produce bit-identical results.
//
// Portability (Intel/AMD): the batched inputs avoid integer vertex attributes,
// structs and matrices in the storage buffer, and integer bit patterns stored
// in floats. Every value is an exact float in a flat vec4 array.
layout (location = 0) in vec3 v_pos;
layout (location = 1) in vec2 v_tex_coord;

layout (location = 0) out vec2 tex_coord;
layout (location = 1) flat out int face_idx;
layout (location = 2) out vec3 world_pos;
// The object's Batch_Object fields, read once per vertex and passed on
// unchanged (flat).
layout (location = 3) flat out vec4 b_color;
layout (location = 4) flat out vec4 b_emissive;
layout (location = 5) flat out vec4 b_face_scale; // xyz face scale, w texture scale
layout (location = 6) flat out vec4 b_tex_row0;
layout (location = 7) flat out vec4 b_tex_row1;
layout (location = 8) flat out vec4 b_params; // x face mask, y BATCH_FLAG_* bits, z alpha_test

// Resource bindings (VULKAN is predefined when compiling to SPIR-V). GL keeps uniform blocks, storage buffers and texture
// units in separate namespaces (gpu.odin GPU_BINDING_* / GPU_UNIT_*); Vulkan
// numbers them all in one descriptor set.
#ifdef VULKAN
// Set 0 changes per pass (gpu_vk.odin), set 1 per material texture.
#define BINDING_PASS set = 0, binding = 0
#define BINDING_DRAW set = 0, binding = 1
#define BINDING_OBJECTS set = 0, binding = 2
#define BINDING_SHADOW_MAP set = 0, binding = 4
#define BINDING_PLAYER_SHADOW_MAP set = 0, binding = 5
#define BINDING_TEX set = 1, binding = 0
#define VERTEX_ID gl_VertexIndex
#else
#define BINDING_PASS binding = 0
#define BINDING_DRAW binding = 1
#define BINDING_OBJECTS binding = 0
#define BINDING_TEX binding = 0
#define BINDING_SHADOW_MAP binding = 1
#define BINDING_PLAYER_SHADOW_MAP binding = 2
#define VERTEX_ID gl_VertexID
#endif
#define SHADOW_CASCADES 3
#define MAX_MAP_LIGHTS 16
// Per-pass values (Basic_Pass_Uniforms in materials.odin). Must stay
// identical in basic.vert and basic.frag.
layout (std140, BINDING_PASS) uniform Pass {
    mat4 camera_world_inverse;
    mat4 camera_projection;
    mat4 uShadowMatrices[SHADOW_CASCADES]; // world -> uv (xy) and depth (z)
    mat4 uPlayerShadowMatrix;
    // Sharp: cascade i's uv = cascade 0's uv * xy + zw (same light view and depth).
    vec4 uCascadeScaleOffset[SHADOW_CASCADES];
    vec4 uShadowBiasTexel[SHADOW_CASCADES]; // x depth bias, y shadow.radius (1) / mapSize
    vec4 uMapLightPosition[MAX_MAP_LIGHTS]; // xyz, kind (0 point, 1 spot, 2 directional)
    vec4 uMapLightColor[MAX_MAP_LIGHTS]; // rgb * intensity, distance
    vec4 uMapLightDirection[MAX_MAP_LIGHTS]; // spot axis or direction to light, decay
    vec4 uMapLightCone[MAX_MAP_LIGHTS]; // cos(angle), cos(angle * (1 - penumbra))
    vec4 uVisualImage; // brightness, gamma, contrast, saturation
    vec3 uAmbientColor;
    float uAmbientIntensity;
    vec3 uLightColor;
    float uLightIntensity;
    vec3 uLightDir;
    float world_uv_scale;
    vec3 uFogColor;
    float uFogNear;
    vec3 uCameraPosition;
    float uFogFar;
    vec3 uNightLowTint;
    float uShadowNormalBias;
    vec3 uNightUnlitTint;
    float uPlayerShadowBias;
    vec2 uVisualLighting; // ambient and sunlight multipliers
    float uPlayerShadowTexel;
    int uLightingMode;
    bool uShadowEnabled;
    int uShadowLayers;
    bool uShadowSoft;
    int uShadowSoftKernel;
    bool uPlayerShadowEnabled;
    int uMapLightCount;
};

// Batched and per-object draws of coincident faces must store the same depth
// (draw order resolves the tie), so the position math may not be refactored
// differently per program: invariant + precise.
invariant gl_Position;

#ifdef BATCHED
// Small integers as floats: exact below 2^24.
layout (location = 2) in float v_face_idx;
layout (location = 3) in float v_object;
// BATCH_OBJECT_VEC4S vec4s per object (map_batch.odin Batch_Object).
layout (std430, BINDING_OBJECTS) readonly buffer Batch_Objects {
    vec4 objects[];
};
#define OBJECT(slot) objects[object_base + (slot)]
#elif defined(VULKAN)
// This draw's object (one Batch_Object) in the frame's uniform ring, which
// stays bound for the whole frame; the draw passes its vec4 index as a push
// constant instead of rebinding a descriptor set per draw.
layout (std430, BINDING_DRAW) readonly buffer Draw_Ring {
    vec4 draw_ring[];
};
layout (push_constant) uniform Draw_Index {
    uint draw_vec4;
};
#define OBJECT(slot) draw_ring[draw_vec4 + (slot)]
#else
// This draw's object (one Batch_Object).
layout (std140, BINDING_DRAW) uniform Draw {
    vec4 draw_object[BATCH_OBJECT_VEC4S];
};
#define OBJECT(slot) draw_object[slot]
#endif

void main() {
    tex_coord = v_tex_coord;
#ifdef BATCHED
    int object_base = int(v_object + 0.5) * BATCH_OBJECT_VEC4S;
#endif
    mat4 m_transform = mat4(
        OBJECT(BATCH_SLOT_TRANSFORM + 0),
        OBJECT(BATCH_SLOT_TRANSFORM + 1),
        OBJECT(BATCH_SLOT_TRANSFORM + 2),
        OBJECT(BATCH_SLOT_TRANSFORM + 3));
    b_color = OBJECT(BATCH_SLOT_COLOR);
    b_emissive = OBJECT(BATCH_SLOT_EMISSIVE);
    b_face_scale = OBJECT(BATCH_SLOT_FACE_SCALE);
    b_tex_row0 = OBJECT(BATCH_SLOT_TEX_ROW0);
    b_tex_row1 = OBJECT(BATCH_SLOT_TEX_ROW1);
    b_params = OBJECT(BATCH_SLOT_PARAMS);

#ifdef BATCHED
    // Computed on the CPU with the per-object rule below.
    face_idx = int(v_face_idx + 0.5);
#else
    if ((int(b_params.y + 0.5) & BATCH_FLAG_RAMP) != 0) {
        if (VERTEX_ID < 4) face_idx = 0;
        else if (VERTEX_ID < 8) face_idx = 1;
        else if (VERTEX_ID - 8 < 6) face_idx = 2;
        else face_idx = 3;
    } else {
        // Cube geometry uses four unique indexed vertices per face.
        face_idx = VERTEX_ID / 4;
    }
#endif

    // Map cubes (create_cube_geo: x, z in -0.5..0.5, y in 0..1; faces front,
    // back, left, right, top, bottom). Where one box's edge runs past a
    // neighbour's corner (a T-junction), the two surfaces meet only to within
    // rounding and the background shows through sub-pixel cracks. Each face
    // grows SEAL_EDGE world units along its own plane, never out of it, so
    // faces lying on it (planes, decals) still tie in depth as before.
    vec3 local = v_pos;
    if ((int(b_params.y + 0.5) & BATCH_FLAG_SEAL_EDGES) != 0) {
        const float SEAL_EDGE = 0.002;
        vec3 in_plane = face_idx < 2 ? vec3(1.0, 1.0, 0.0) : (face_idx < 4 ? vec3(0.0, 1.0, 1.0) : vec3(1.0, 0.0, 1.0));
        vec3 outward = sign(v_pos - vec3(0.0, 0.5, 0.0)) * in_plane;
        vec3 axis_scale = vec3(length(m_transform[0].xyz), length(m_transform[1].xyz), length(m_transform[2].xyz));
        local += outward * SEAL_EDGE / max(axis_scale, vec3(1e-6));
    }
    precise vec3 p_world = vec3(m_transform * vec4(local, 1.0));
    world_pos = p_world;

    precise vec4 p_clip = camera_projection * camera_world_inverse * vec4(p_world, 1.0);
#ifdef VULKAN
    // The matrices are GL's (clip z in -w..w); Vulkan clips z to 0..w. The
    // stored depth, (z/w + 1) / 2, is then GL's with the default depth range,
    // so shadow-map depths and comparisons match GL exactly.
    p_clip.z = (p_clip.z + p_clip.w) * 0.5;
#endif
    gl_Position = p_clip;
#if defined(BATCHED) && defined(SHADOW_DEPTH_PASS)
    // Batches mix casters with receive-only objects (ramps, planes): move the
    // latter outside the clip volume so the shadow map never sees them.
    if ((int(b_params.y + 0.5) & BATCH_FLAG_CAST_SHADOW) == 0) gl_Position = vec4(2.0, 2.0, 2.0, 1.0);
#endif
}
