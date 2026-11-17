#version 450 core
// Developer line overlay (debug_hitboxes.odin): world-space lines with a
// colour each, drawn with the world camera.
layout (location = 0) in vec3 a_position;
layout (location = 1) in vec4 a_color;

// The per-draw block (GPU_BINDING_DRAW): a uniform block on GL; on Vulkan
// (VULKAN is predefined when compiling to SPIR-V) four vec4s in the frame's
// uniform ring at the index the draw pushes, as basic.vert reads its object.
#ifdef VULKAN
layout (std430, set = 0, binding = 1) readonly buffer Draw_Ring {
    vec4 draw_ring[];
};
layout (push_constant) uniform Draw_Index {
    uint draw_vec4;
};
#define view_proj mat4(draw_ring[draw_vec4], draw_ring[draw_vec4 + 1], draw_ring[draw_vec4 + 2], draw_ring[draw_vec4 + 3])
#else
layout (std140, binding = 1) uniform Draw {
    mat4 view_proj;
};
#endif

layout (location = 0) out vec4 v_color;

void main() {
    v_color = a_color;
    vec4 p_clip = view_proj * vec4(a_position, 1.0);
#ifdef VULKAN
    // GL clip depth (-w..w) to Vulkan's 0..w, as basic.vert does.
    p_clip.z = (p_clip.z + p_clip.w) * 0.5;
#endif
    gl_Position = p_clip;
}
