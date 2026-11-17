package main

import "core:strings"
import "core:testing"

when ODIN_TEST {
	// The SPIR-V build (tools/build-spirv.*) reads the Batch_Object layout
	// from spirv/basic_defines.glsl; it must match what the GL path generates
	// from the struct.
	@(test)
	basic_spirv_defines_match_layout :: proc(t: ^testing.T) {
		BASIC_SPIRV_DEFINES :: #load("spirv/basic_defines.glsl", string)
		generated := basic_shader_defines(false, false, context.temp_allocator)
		file, _ := strings.replace_all(BASIC_SPIRV_DEFINES, "\r\n", "\n", context.temp_allocator)
		testing.expectf(t, strings.trim_space(file) == strings.trim_space(generated),
			"src/client/spirv/basic_defines.glsl is out of date; it must read:\n%s", generated)
	}
}
