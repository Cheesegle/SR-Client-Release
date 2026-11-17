#version 450 core
// The batched interface renderer (ui.odin): one UI_Vertex per corner, with the
// element's values repeated on its vertices. Positions arrive in clip space.
layout (location = 0) in vec2 v_pos;
layout (location = 1) in vec2 v_local;  // 0..1 across the element, y up
layout (location = 2) in vec2 v_uv;     // texture coordinate
layout (location = 3) in vec4 v_color;
layout (location = 4) in vec4 v_radii;  // bottom left, bottom right, top left, top right
layout (location = 5) in vec4 v_params; // aspect, r_clip, stroke width, kind

layout (location = 0) out vec2 tex_coord;
layout (location = 1) out vec2 uv;
layout (location = 2) flat out vec4 color;
layout (location = 3) flat out vec4 radii;
layout (location = 4) flat out vec4 params;

void main() {
    tex_coord = v_local;
    uv = v_uv;
    color = v_color;
    radii = v_radii;
    params = v_params;
    gl_Position = vec4(v_pos, 0.0, 1.0);
}
