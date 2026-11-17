package main

import "core:fmt"
import "core:strings"
import gl "vendor:OpenGL"
import shared "../shared"

// Programs compiled so far this session (diagnostics and tests).
g_shader_compiles: int

// `defines` (for example a "#define BATCHED" line) is inserted after the #version line.
shader_compile :: proc(vertex_shader_path, fragment_shader_path: string, defines := "") -> u32 {
	g_shader_compiles += 1
	vertex_shader, v_ok := shared.read_file(vertex_shader_path)
	fragment_shader, f_ok := shared.read_file(fragment_shader_path)

	if !v_ok || !f_ok {
		return 0
	}

	defer delete(vertex_shader)
	defer delete(fragment_shader)

	v_src := shader_insert_defines(string(vertex_shader), defines)
	f_src := shader_insert_defines(string(fragment_shader), defines)
	defer if len(defines) > 0 {
		delete(v_src)
		delete(f_src)
	}

	vert := gl.CreateShader(gl.VERTEX_SHADER)
	frag := gl.CreateShader(gl.FRAGMENT_SHADER)

	v_cstr := cstring(raw_data(v_src))
	f_cstr := cstring(raw_data(f_src))
	// read_file returns bytes without a terminating NUL. Passing explicit
	// lengths prevents GL from compiling memory beyond the source buffer.
	v_length := i32(len(v_src))
	f_length := i32(len(f_src))

	gl.ShaderSource(vert, 1, &v_cstr, &v_length)
	gl.CompileShader(vert)

	status: i32
	gl.GetShaderiv(vert, gl.COMPILE_STATUS, &status)

	if status == 0 {
		error: [512]u8
		gl.GetShaderInfoLog(vert, 512, nil, &error[0])
		fmt.printf("vertex shader compile error (%s):\n %s \n", vertex_shader_path, cstring(&error[0]))

		gl.DeleteShader(vert)
		gl.DeleteShader(frag)
		return 0
	}

	gl.ShaderSource(frag, 1, &f_cstr, &f_length)
	gl.CompileShader(frag)

	gl.GetShaderiv(frag, gl.COMPILE_STATUS, &status)

	if status == 0 {
		error: [512]u8
		gl.GetShaderInfoLog(frag, 512, nil, &error[0])
		fmt.printf("fragment shader compile error (%s):\n %s \n", fragment_shader_path, cstring(&error[0]))

		gl.DeleteShader(vert)
		gl.DeleteShader(frag)
		return 0
	}

	program := gl.CreateProgram()

	gl.AttachShader(program, vert)
	gl.AttachShader(program, frag)

	gl.LinkProgram(program)

	gl.DeleteShader(vert)
	gl.DeleteShader(frag)

	gl.GetProgramiv(program, gl.LINK_STATUS, &status)

	if status == 0 {
		error: [512]u8
		gl.GetProgramInfoLog(program, 512, nil, &error[0])
		fmt.printf("shader link error (%s, %s):\n %s \n", vertex_shader_path, fragment_shader_path, cstring(&error[0]))

		gl.DeleteProgram(program)
		return 0
	}

	return program
}

shader_insert_defines :: proc(source, defines: string) -> string {
	if len(defines) == 0 {
		return source
	}
	line_end := strings.index_byte(source, '\n')
	if line_end < 0 {
		return strings.concatenate({source, "\n", defines})
	}
	return strings.concatenate({source[:line_end + 1], defines, source[line_end + 1:]})
}

// The HUD and menu program (ui.vert / ui.frag). `dir` ends with a slash.
shader_compile_ui :: proc(dir, vertex_name, fragment_name: string) -> u32 {
	vert := strings.concatenate({dir, vertex_name}, context.temp_allocator)
	frag := strings.concatenate({dir, fragment_name}, context.temp_allocator)
	return shader_compile(vert, frag)
}
