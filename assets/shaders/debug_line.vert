#version 450 core
// Developer line overlay (debug_hitboxes.odin): world-space lines with a
// colour each, drawn with the world camera.
layout (location = 0) in vec3 a_position;
layout (location = 1) in vec4 a_color;

// The per-draw uniform block (GPU_BINDING_DRAW); VULKAN is predefined when
// compiling to SPIR-V.
#ifdef VULKAN
layout (std140, set = 0, binding = 1) uniform Draw {
#else
layout (std140, binding = 1) uniform Draw {
#endif
    mat4 view_proj;
};

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
