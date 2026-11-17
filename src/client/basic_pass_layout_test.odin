package main

import "base:runtime"
import "core:fmt"
import "core:testing"
import gl "vendor:OpenGL"
import glfw "vendor:glfw"

when ODIN_TEST {
	// basic.vert/basic.frag's `Pass` block, as the driver lays it out, must match
	// Basic_Pass_Uniforms byte for byte: it is uploaded as is.
	@(test)
	basic_pass_block_matches_struct :: proc(t: ^testing.T) {
		logger := context.logger
		context = runtime.default_context()
		context.logger = logger
		if !testing.expect(t, bool(glfw.Init())) { return }
		defer glfw.Terminate()
		glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)
		glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 5)
		window := glfw.CreateWindow(16, 16, "Pass layout", nil, nil)
		if !testing.expect(t, window != nil, "hidden OpenGL window failed") { return }
		defer glfw.DestroyWindow(window)
		glfw.MakeContextCurrent(window)
		gl.load_up_to(4, 5, glfw.gl_set_proc_address)

		Member :: struct { name: string, offset: uintptr }
		members := [?]Member{
			{"camera_world_inverse", offset_of(Basic_Pass_Uniforms, camera_world_inverse)},
			{"camera_projection", offset_of(Basic_Pass_Uniforms, camera_projection)},
			{"uShadowMatrices[0]", offset_of(Basic_Pass_Uniforms, shadow_matrices)},
			{"uPlayerShadowMatrix", offset_of(Basic_Pass_Uniforms, player_shadow_matrix)},
			{"uCascadeScaleOffset[0]", offset_of(Basic_Pass_Uniforms, cascade_scale_offset)},
			{"uShadowBiasTexel[0]", offset_of(Basic_Pass_Uniforms, shadow_bias_texel)},
			{"uMapLightPosition[0]", offset_of(Basic_Pass_Uniforms, map_light_position)},
			{"uMapLightColor[0]", offset_of(Basic_Pass_Uniforms, map_light_color)},
			{"uMapLightDirection[0]", offset_of(Basic_Pass_Uniforms, map_light_direction)},
			{"uMapLightCone[0]", offset_of(Basic_Pass_Uniforms, map_light_cone)},
			{"uVisualImage", offset_of(Basic_Pass_Uniforms, visual_image)},
			{"uAmbientColor", offset_of(Basic_Pass_Uniforms, ambient_color)},
			{"uAmbientIntensity", offset_of(Basic_Pass_Uniforms, ambient_intensity)},
			{"uLightColor", offset_of(Basic_Pass_Uniforms, light_color)},
			{"uLightIntensity", offset_of(Basic_Pass_Uniforms, light_intensity)},
			{"uLightDir", offset_of(Basic_Pass_Uniforms, light_dir)},
			{"world_uv_scale", offset_of(Basic_Pass_Uniforms, world_uv_scale)},
			{"uFogColor", offset_of(Basic_Pass_Uniforms, fog_color)},
			{"uFogNear", offset_of(Basic_Pass_Uniforms, fog_near)},
			{"uCameraPosition", offset_of(Basic_Pass_Uniforms, camera_position)},
			{"uFogFar", offset_of(Basic_Pass_Uniforms, fog_far)},
			{"uNightLowTint", offset_of(Basic_Pass_Uniforms, night_low_tint)},
			{"uShadowNormalBias", offset_of(Basic_Pass_Uniforms, shadow_normal_bias)},
			{"uNightUnlitTint", offset_of(Basic_Pass_Uniforms, night_unlit_tint)},
			{"uPlayerShadowBias", offset_of(Basic_Pass_Uniforms, player_shadow_bias)},
			{"uVisualLighting", offset_of(Basic_Pass_Uniforms, visual_lighting)},
			{"uPlayerShadowTexel", offset_of(Basic_Pass_Uniforms, player_shadow_texel)},
			{"uLightingMode", offset_of(Basic_Pass_Uniforms, lighting_mode)},
			{"uShadowEnabled", offset_of(Basic_Pass_Uniforms, shadow_enabled)},
			{"uShadowLayers", offset_of(Basic_Pass_Uniforms, shadow_layers)},
			{"uShadowSoft", offset_of(Basic_Pass_Uniforms, shadow_soft)},
			{"uShadowSoftKernel", offset_of(Basic_Pass_Uniforms, shadow_soft_kernel)},
			{"uPlayerShadowEnabled", offset_of(Basic_Pass_Uniforms, player_shadow_enabled)},
			{"uMapLightCount", offset_of(Basic_Pass_Uniforms, map_light_count)},
		}

		// Every variant declares the same block; the batched shadow variant leaves
		// the most members unused, so check the plain colour one (all used) and
		// require the block size everywhere.
		for variant in ([4][2]bool{{false, false}, {true, false}, {false, true}, {true, true}}) {
			program := basic_program_compile(variant[0], variant[1])
			if !testing.expectf(t, program != 0, "basic program %v must compile", variant) { continue }
			defer gl.DeleteProgram(program)
			block := gl.GetProgramResourceIndex(program, gl.UNIFORM_BLOCK, "Pass")
			if !testing.expectf(t, block != gl.INVALID_INDEX, "variant %v must declare the Pass block", variant) { continue }
			props := [2]u32{gl.BUFFER_DATA_SIZE, gl.BUFFER_BINDING}
			values: [2]i32
			gl.GetProgramResourceiv(program, gl.UNIFORM_BLOCK, block, 2, &props[0], 2, nil, &values[0])
			testing.expectf(t, int(values[0]) == size_of(Basic_Pass_Uniforms), "variant %v: Pass is %d bytes, struct is %d", variant, values[0], size_of(Basic_Pass_Uniforms))
			testing.expectf(t, values[1] == GPU_BINDING_PASS, "variant %v: Pass is bound to %d", variant, values[1])
			if variant != {false, false} { continue }
			for member in members {
				index := gl.GetProgramResourceIndex(program, gl.UNIFORM, cstring(raw_data(fmt.tprintf("%s\x00", member.name))))
				if !testing.expectf(t, index != gl.INVALID_INDEX, "%s must be active", member.name) { continue }
				prop := u32(gl.OFFSET)
				offset := i32(-1)
				gl.GetProgramResourceiv(program, gl.UNIFORM, index, 1, &prop, 1, nil, &offset)
				testing.expectf(t, uintptr(offset) == member.offset, "%s: shader offset %d, struct offset %d", member.name, offset, member.offset)
			}
		}
		resource_cache_fini()
	}
}
