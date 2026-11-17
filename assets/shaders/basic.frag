#version 450 core
#ifdef SHADOW_DEPTH_PASS
// Depth only: the colour is computed for the alpha test, never written out.
vec4 frag_color;
#else
layout (location = 0) out vec4 frag_color;
#endif

layout (location = 0) in vec2 tex_coord;
layout (location = 1) flat in int face_idx;
layout (location = 2) in vec3 world_pos;
// This object's Batch_Object fields from basic.vert (flat: copied bit for bit).
layout (location = 3) flat in vec4 b_color;
layout (location = 4) flat in vec4 b_emissive;
layout (location = 5) flat in vec4 b_face_scale; // xyz face scale, w texture scale
layout (location = 6) flat in vec4 b_tex_row0;
layout (location = 7) flat in vec4 b_tex_row1;
layout (location = 8) flat in vec4 b_params; // x face mask, y BATCH_FLAG_* bits, z alpha_test (exact floats)

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

// Krunker "Lighting" (uLightingMode): 0 Low (unlit), 1 Normal (Lambert),
// 2 High (Phong), 3 Physical (standard, roughness 1, metalness 0). See
// shadows.odin. Krunker "Shadows": the sun's orthographic shadow map(s) in one
// depth array (shadows.odin). Krunker mode: one layer, Krunker's whole-map
// camera. Sharp mode: SHADOW_CASCADES layers around the camera, nearest
// first. uShadowSoft selects PCFShadowMap (otherwise BasicShadowMap);
// uShadowSoftKernel 0 is Krunker's 5-tap Vogel PCF, 1 a 4-tap bilinear PCF.
// Players (Dynamic Shadows) and your own body (Self shadow) use a small map
// fitted to them every frame; receivers take the darker of the two.
// Night mode (night_mode.odin) dims the lights themselves; uNightLowTint
// multiplies lit materials under Lighting Low (unlit), uNightUnlitTint
// emissive (unlit) materials. White when night is off.
// Map POINT/SPOT/DIRECTIONAL_LIGHT objects light High and Physical.

layout (BINDING_TEX) uniform sampler2D tex;
layout (BINDING_SHADOW_MAP) uniform sampler2DArrayShadow uShadowMap;
layout (BINDING_PLAYER_SHADOW_MAP) uniform sampler2DShadow uPlayerShadowMap;

// three.js interleavedGradientNoise and vogelDiskSample, as used by its
// PCFShadowFilter.
float interleaved_gradient_noise(vec2 position) {
    return fract(52.9829189 * fract(dot(position, vec2(0.06711056, 0.00583715))));
}

vec2 vogel_disk_sample(int index, int count, float phi) {
    float r = sqrt((float(index) + 0.5) / float(count));
    float theta = float(index) * 2.399963229728653 + phi;
    return vec2(cos(theta), sin(theta)) * r;
}

// Soft filter tap offsets, in texels. Kernel 0 is Krunker's PCFShadowFilter
// (5 Vogel taps, rotated per pixel by noise). Kernel 1 is 4 bilinear taps on
// a 0.5-texel square: a 3x3-texel tent with no noise and no trigonometry.
int soft_tap_count() { return uShadowSoftKernel == 0 ? 5 : 4; }

vec2 soft_tap(int i, float phi) {
    if (uShadowSoftKernel == 0) return vogel_disk_sample(i, 5, phi);
    return vec2((i & 1) == 0 ? -0.5 : 0.5, (i & 2) == 0 ? -0.5 : 0.5);
}

float soft_phi() {
    return uShadowSoftKernel == 0 ? interleaved_gradient_noise(gl_FragCoord.xy) * 6.28318530718 : 0.0;
}

float sun_layer_visibility(vec3 coord, int layer) {
    if (!uShadowSoft) return texture(uShadowMap, vec4(coord.xy, float(layer), coord.z));
    float phi = soft_phi();
    int taps = soft_tap_count();
    float sum = 0.0;
    for (int i = 0; i < taps; i++) {
        vec2 offset = soft_tap(i, phi) * uShadowBiasTexel[layer].y;
        sum += texture(uShadowMap, vec4(coord.xy + offset, float(layer), coord.z));
    }
    return sum / float(taps);
}

vec3 sun_layer_coord(vec3 position, int layer) {
    vec4 coord = uShadowMatrices[layer] * vec4(position, 1.0);
    vec3 c = coord.xyz / coord.w;
    c.z += uShadowBiasTexel[layer].x;
    return c;
}

// Distance (in uv) from the cascade's border; negative outside.
float cascade_inset(vec3 c) {
    return min(min(c.x, 1.0 - c.x), min(c.y, 1.0 - c.y));
}

#define CASCADE_BLEND 0.08 // Outer band (in uv) blended into the next cascade.

float sun_visibility(vec3 position) {
    if (uShadowLayers == 1) {
        vec3 c = sun_layer_coord(position, 0);
        // Krunker: outside the shadow camera's frustum is lit.
        if (c.x < 0.0 || c.x > 1.0 || c.y < 0.0 || c.y > 1.0 || c.z > 1.0) return 1.0;
        return sun_layer_visibility(c, 0);
    }
    vec3 c0 = sun_layer_coord(position, 0);
    for (int layer = 0; layer < uShadowLayers; layer++) {
        vec3 c = vec3(c0.xy * uCascadeScaleOffset[layer].xy + uCascadeScaleOffset[layer].zw, c0.z);
        float inset = cascade_inset(c);
        // Keep a 2-texel margin for the soft filter's footprint.
        float margin = 2.0 * uShadowBiasTexel[layer].y;
        if (inset < margin || c.z > 1.0) continue;
        float visibility = sun_layer_visibility(c, layer);
        float blend = (inset - margin) / CASCADE_BLEND;
        if (blend >= 1.0 || layer + 1 >= uShadowLayers) return visibility;
        vec3 next = vec3(c0.xy * uCascadeScaleOffset[layer + 1].xy + uCascadeScaleOffset[layer + 1].zw, c0.z);
        if (cascade_inset(next) < 2.0 * uShadowBiasTexel[layer + 1].y) return visibility;
        return mix(sun_layer_visibility(next, layer + 1), visibility, blend);
    }
    return 1.0; // Past the last cascade (beyond the fog).
}

float player_visibility(vec3 position) {
    vec4 coord = uPlayerShadowMatrix * vec4(position, 1.0);
    vec3 c = coord.xyz / coord.w;
    if (c.x < 0.0 || c.x > 1.0 || c.y < 0.0 || c.y > 1.0 || c.z < 0.0) return 1.0;
    // Receivers past the fitted far plane are still behind every caster.
    c.z = min(c.z + uPlayerShadowBias, 1.0);
    if (!uShadowSoft) return texture(uPlayerShadowMap, c);
    float phi = soft_phi();
    int taps = soft_tap_count();
    float sum = 0.0;
    for (int i = 0; i < taps; i++) {
        sum += texture(uPlayerShadowMap, vec3(c.xy + soft_tap(i, phi) * uPlayerShadowTexel, c.z));
    }
    return sum / float(taps);
}

float sun_shadow(vec3 normal) {
    vec3 position = world_pos + normal * uShadowNormalBias;
    float visibility = sun_visibility(position);
    if (uPlayerShadowEnabled && visibility > 0.0) visibility = min(visibility, player_visibility(position));
    return visibility;
}

vec3 f_schlick(vec3 f0, float dot_vh) {
    float fresnel = exp2((-5.55473 * dot_vh - 6.98316) * dot_vh);
    return f0 * (1.0 - fresnel) + fresnel;
}

// Specular BRDF times pi (three.js scales Krunker's light intensities by pi,
// which cancels the 1/pi in each BRDF and in BRDF_Lambert).
vec3 specular_brdf(vec3 light_dir, vec3 view_dir, vec3 normal, float dot_nl) {
    vec3 half_dir = normalize(light_dir + view_dir);
    float dot_nh = clamp(dot(normal, half_dir), 0.0, 1.0);
    float dot_vh = clamp(dot(view_dir, half_dir), 0.0, 1.0);
    if (uLightingMode == 2) {
        // BRDF_BlinnPhong: specular 0x111111, shininess 30.
        return f_schlick(vec3(17.0 / 255.0), dot_vh) * (0.25 * (30.0 * 0.5 + 1.0) * pow(dot_nh, 30.0));
    }
    // BRDF_GGX with roughness 1 (alpha 1): D = 1/pi, V = 0.5 / (NdotL + NdotV).
    float dot_nv = clamp(dot(normal, view_dir), 0.0, 1.0);
    return f_schlick(vec3(0.04), dot_vh) * (0.5 / max(dot_nl + dot_nv, 1e-6));
}


void main() {
    int flags = int(b_params.y + 0.5);
    bool m_is_ramp = (flags & BATCH_FLAG_RAMP) != 0;
    bool m_is_ladder = (flags & BATCH_FLAG_LADDER) != 0;
    bool m_use_face_tex_scaling = (flags & BATCH_FLAG_FACE_TEX_SCALE) != 0;
    bool m_unlit = (flags & BATCH_FLAG_UNLIT) != 0;
    bool m_no_fog = (flags & BATCH_FLAG_NO_FOG) != 0;
    bool m_receive_shadow = (flags & BATCH_FLAG_RECEIVE_SHADOW) != 0;
    int m_face_mask = int(b_params.x + 0.5);
    float m_texture_scale = b_face_scale.w;
    vec3 m_face_scale = b_face_scale.xyz;
    vec4 m_color = b_color;
    vec4 m_emissive = b_emissive;
    float m_alpha_test = b_params.z;
    mat3 m_tex_transform = mat3(
        vec3(b_tex_row0.x, b_tex_row1.x, 0.0),
        vec3(b_tex_row0.y, b_tex_row1.y, 0.0),
        vec3(b_tex_row0.z, b_tex_row1.z, 1.0));

    if (face_idx < 6 && ((m_face_mask & (1 << face_idx)) == 0)) discard;
    vec2 scaled_tex_coord;

    if (m_use_face_tex_scaling) {
        vec2 scale = m_face_scale.xy;

        if (m_is_ramp) {
            switch (face_idx) {
                case 0:
                    scale = vec2(m_face_scale.x, sqrt(m_face_scale.z*m_face_scale.z + m_face_scale.y*m_face_scale.y));
                    break;
                case 1:
                    scale = m_face_scale.xz;
                    break;
                case 2:
                    scale = m_face_scale.zy;
                    break;
                case 3:
                    scale = m_face_scale.xy;
                    break;
            }
        } else if (m_is_ladder) {
            if (face_idx < 2) scale = m_face_scale.xy;
            else if (face_idx < 4) scale = m_face_scale.zy;
            else if (face_idx < 6) scale = m_face_scale.xz;
            else if (face_idx < 8) scale = m_face_scale.xy;
            else if (face_idx < 10) scale = m_face_scale.zy;
            else scale = m_face_scale.xz;
        } else {
            if (face_idx < 2) scale = m_face_scale.xy;
            else if (face_idx < 4) scale = m_face_scale.zy;
            else scale = m_face_scale.xz;
        }

        vec2 repeat_scale = (scale / world_uv_scale) * m_texture_scale;
        scaled_tex_coord = repeat_scale * tex_coord;
        scaled_tex_coord.x += 0.5f - repeat_scale.x * 0.5f;
    } else {
        scaled_tex_coord = tex_coord;
    }

    vec3 t_tex_coord = m_tex_transform * vec3(scaled_tex_coord, 1.0f);
    frag_color = texture(tex, t_tex_coord.xy) * mix(m_color, m_emissive, 0.0f);
    // Cutout foliage stays in the opaque pass, with holes in color and depth.
    if (frag_color.a < m_alpha_test) discard;
#ifdef SHADOW_DEPTH_PASS
    return;
#endif

    vec3 normal = normalize(cross(dFdx(world_pos), dFdy(world_pos)));
    float light_length = length(uLightDir);
    vec3 light_direction = light_length > 0.0001 ? uLightDir / light_length : vec3(0.0, 1.0, 0.0);
    float diffuse = max(dot(normal, light_direction), 0.0);
    float sun_diffuse = diffuse;
    if (uShadowEnabled && m_receive_shadow && diffuse > 0.0) diffuse *= sun_shadow(normal);
    vec3 lighting = uAmbientColor * uAmbientIntensity + uLightColor * (uLightIntensity * diffuse);
    vec3 extra_diffuse = vec3(0.0);
    vec3 specular = vec3(0.0);
    bool shaded = !m_unlit && uLightingMode != 0;
    if (shaded && uLightingMode >= 2) {
        vec3 view_dir = normalize(uCameraPosition - world_pos);
        specular = uLightColor * (uLightIntensity * diffuse) * specular_brdf(light_direction, view_dir, normal, sun_diffuse);
        for (int i = 0; i < uMapLightCount; i++) {
            vec3 to_light;
            float attenuation = 1.0;
            int kind = int(uMapLightPosition[i].w);
            if (kind == 2) {
                to_light = uMapLightDirection[i].xyz;
            } else {
                vec3 delta = uMapLightPosition[i].xyz - world_pos;
                float distance = length(delta);
                to_light = delta / max(distance, 1e-4);
                // three.js getDistanceAttenuation.
                attenuation = 1.0 / max(pow(distance, uMapLightDirection[i].w), 0.01);
                float cutoff = uMapLightColor[i].w;
                if (cutoff > 0.0) {
                    float ratio = distance / cutoff;
                    float falloff = clamp(1.0 - ratio * ratio * ratio * ratio, 0.0, 1.0);
                    attenuation *= falloff * falloff;
                }
                if (kind == 1) attenuation *= smoothstep(uMapLightCone[i].x, uMapLightCone[i].y, dot(to_light, -uMapLightDirection[i].xyz));
            }
            float dot_nl = max(dot(normal, to_light), 0.0);
            vec3 irradiance = uMapLightColor[i].rgb * (attenuation * dot_nl);
            extra_diffuse += irradiance;
            specular += irradiance * specular_brdf(to_light, view_dir, normal, dot_nl);
        }
        lighting += extra_diffuse;
    }
    // Three.js applies color management/tone mapping after accumulating light.
    // Keep the native path from saturating every textured face when the live
    // map's ambient and directional intensities sum above one.
    float peak_light = max(max(lighting.r, lighting.g), max(lighting.b, 1.0));
    lighting = (uAmbientColor * uAmbientIntensity * uVisualLighting.x + uLightColor * (uLightIntensity * diffuse * uVisualLighting.y)) / peak_light;
    if (shaded && uLightingMode >= 2) {
        lighting += extra_diffuse * (uVisualLighting.y / peak_light);
        specular *= uVisualLighting.y / peak_light;
    }
    // The map loader uses white as the neutral/default emissive value. Keep
    // that default neutral; explicit emissive materials need a separate
    // strength flag before they can be added without brightening every mesh.
    vec3 lit_rgb = frag_color.rgb * (shaded ? lighting : (m_unlit ? uNightUnlitTint : uNightLowTint)) + specular;
    float fog_span = max(0.001, uFogFar - uFogNear);
    float fog_amount = m_no_fog ? 0.0 : clamp((length(world_pos - uCameraPosition) - uFogNear) / fog_span, 0.0, 1.0);
    vec3 rgb = mix(lit_rgb, uFogColor, fog_amount);
    rgb = (rgb * uVisualImage.x - 0.5) * uVisualImage.z + 0.5;
    float luma = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
    rgb = mix(vec3(luma), rgb, uVisualImage.w);
    rgb = pow(clamp(rgb, 0.0, 1.0), vec3(1.0 / max(0.01, uVisualImage.y)));
    frag_color = vec4(rgb, frag_color.a);
}
