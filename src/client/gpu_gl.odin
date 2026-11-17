package main

// OpenGL 4.5 backend for the gpu_* interface (see gpu.odin). Creation and
// updates use direct state access, so they never disturb the texture bound
// for drawing.

import "core:math"
import gl "vendor:OpenGL"
import glfw "vendor:glfw"
import shared "../shared"


	@(private="file")
	gl_texture_formats :: proc(format: Gpu_Format) -> (internal, upload, type: u32) {
		switch format {
		case .RGBA8: return gl.RGBA8, gl.RGBA, gl.UNSIGNED_BYTE
		case .R8:    return gl.R8, gl.RED, gl.UNSIGNED_BYTE
		case .Depth: return gl.DEPTH_COMPONENT24, gl.DEPTH_COMPONENT, gl.FLOAT
		}
		return gl.RGBA8, gl.RGBA, gl.UNSIGNED_BYTE
	}

	@(private="file")
	gl_min_filter :: proc(sampler: Gpu_Sampler_Desc, mipmapped: bool) -> i32 {
		if sampler.mip_filter && mipmapped {
			return sampler.filter == .Linear ? gl.LINEAR_MIPMAP_LINEAR : gl.NEAREST_MIPMAP_NEAREST
		}
		return sampler.filter == .Linear ? gl.LINEAR : gl.NEAREST
	}

	@(private="file")
	gl_apply_texture_sampler :: proc(name: u32, sampler: Gpu_Sampler_Desc, mipmapped: bool) {
		wrap: i32 = sampler.wrap == .Repeat ? gl.REPEAT : gl.CLAMP_TO_EDGE
		gl.TextureParameteri(name, gl.TEXTURE_MIN_FILTER, gl_min_filter(sampler, mipmapped))
		gl.TextureParameteri(name, gl.TEXTURE_MAG_FILTER, sampler.filter == .Linear ? gl.LINEAR : gl.NEAREST)
		gl.TextureParameteri(name, gl.TEXTURE_WRAP_S, wrap)
		gl.TextureParameteri(name, gl.TEXTURE_WRAP_T, wrap)
		if sampler.compare {
			gl.TextureParameteri(name, gl.TEXTURE_COMPARE_MODE, gl.COMPARE_REF_TO_TEXTURE)
			gl.TextureParameteri(name, gl.TEXTURE_COMPARE_FUNC, gl.LEQUAL)
		}
	}

	// `pixels` holds level 0 (layer 0 of an array), tightly packed,
	// width*height*bytes-per-pixel bytes; nil leaves the contents undefined.
	// Returns 0 on bad dimensions.
	gl_gpu_texture_create :: proc(desc: Gpu_Texture_Desc, pixels: []u8 = nil) -> Gpu_Texture {
		if desc.width <= 0 || desc.height <= 0 || desc.layers < 0 { return 0 }
		levels: i32 = 1
		if desc.mipmaps {
			levels = i32(math.floor(math.log2(f32(max(desc.width, desc.height))))) + 1
		}
		internal, upload, type := gl_texture_formats(desc.format)

		name: u32
		if desc.layers > 0 {
			gl.CreateTextures(gl.TEXTURE_2D_ARRAY, 1, &name)
			gl.TextureStorage3D(name, levels, internal, desc.width, desc.height, desc.layers)
		} else {
			gl.CreateTextures(gl.TEXTURE_2D, 1, &name)
			gl.TextureStorage2D(name, levels, internal, desc.width, desc.height)
		}
		gl_apply_texture_sampler(name, desc.sampler, desc.mipmaps)
		if pixels != nil && len(pixels) >= int(desc.width) * int(desc.height) * gpu_format_bytes_per_pixel(desc.format) {
			gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1)
			if desc.layers > 0 {
				gl.TextureSubImage3D(name, 0, 0, 0, 0, desc.width, desc.height, 1, upload, type, raw_data(pixels))
			} else {
				gl.TextureSubImage2D(name, 0, 0, 0, desc.width, desc.height, upload, type, raw_data(pixels))
			}
			gl.PixelStorei(gl.UNPACK_ALIGNMENT, 4)
			if desc.mipmaps { gl.GenerateTextureMipmap(name) }
		}
		return Gpu_Texture(name)
	}

	// Replaces a width*height region of level 0 of a 2D texture. `format` must be
	// the format the texture was created with.
	gl_gpu_texture_update :: proc(texture: Gpu_Texture, format: Gpu_Format, x, y, width, height: i32, pixels: []u8) {
		if texture == 0 || len(pixels) < int(width) * int(height) * gpu_format_bytes_per_pixel(format) { return }
		_, upload, type := gl_texture_formats(format)
		gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1)
		gl.TextureSubImage2D(u32(texture), 0, x, y, width, height, upload, type, raw_data(pixels))
		gl.PixelStorei(gl.UNPACK_ALIGNMENT, 4)
	}

	// Changes how the texture filters (wrap, comparison and mip selection are
	// unchanged).
	gl_gpu_texture_set_filter :: proc(texture: Gpu_Texture, filter: Gpu_Filter) {
		if texture == 0 { return }
		value: i32 = filter == .Linear ? gl.LINEAR : gl.NEAREST
		gl.TextureParameteri(u32(texture), gl.TEXTURE_MIN_FILTER, value)
		gl.TextureParameteri(u32(texture), gl.TEXTURE_MAG_FILTER, value)
	}

	gl_gpu_texture_bind :: proc(unit: u32, texture: Gpu_Texture) {
		gl.BindTextureUnit(unit, u32(texture))
	}

	// Destroys the texture and zeroes the handle. Safe on 0.
	gl_gpu_texture_destroy :: proc(texture: ^Gpu_Texture) {
		if texture^ == 0 { return }
		// GL reuses names; a stale cache entry could skip binding a new texture.
		if g_active_texture == texture^ { g_active_texture = 0 }
		name := u32(texture^)
		gl.DeleteTextures(1, &name)
		texture^ = 0
	}

	gl_gpu_sampler_create :: proc(desc: Gpu_Sampler_Desc, anisotropy: f32 = 1) -> Gpu_Sampler {
		name: u32
		gl.CreateSamplers(1, &name)
		wrap: i32 = desc.wrap == .Repeat ? gl.REPEAT : gl.CLAMP_TO_EDGE
		gl.SamplerParameteri(name, gl.TEXTURE_MIN_FILTER, gl_min_filter(desc, true))
		gl.SamplerParameteri(name, gl.TEXTURE_MAG_FILTER, desc.filter == .Linear ? gl.LINEAR : gl.NEAREST)
		gl.SamplerParameteri(name, gl.TEXTURE_WRAP_S, wrap)
		gl.SamplerParameteri(name, gl.TEXTURE_WRAP_T, wrap)
		if desc.compare {
			gl.SamplerParameteri(name, gl.TEXTURE_COMPARE_MODE, gl.COMPARE_REF_TO_TEXTURE)
			gl.SamplerParameteri(name, gl.TEXTURE_COMPARE_FUNC, gl.LEQUAL)
		}
		sampler := Gpu_Sampler(name)
		if anisotropy > 1 { gl_gpu_sampler_set_anisotropy(sampler, anisotropy) }
		return sampler
	}

	// `value` is clamped to [1, gl_gpu_max_anisotropy()]; a no-op without support.
	gl_gpu_sampler_set_anisotropy :: proc(sampler: Gpu_Sampler, value: f32) {
		limit := gl_gpu_max_anisotropy()
		if sampler == 0 || limit < 2 { return }
		gl.SamplerParameterf(u32(sampler), 0x84FE, clamp(value, 1, limit)) // TEXTURE_MAX_ANISOTROPY_EXT
	}

	// 0 unbinds: the texture's own sampling applies again.
	gl_gpu_sampler_bind :: proc(unit: u32, sampler: Gpu_Sampler) {
		gl.BindSampler(unit, u32(sampler))
	}

	gl_gpu_sampler_destroy :: proc(sampler: ^Gpu_Sampler) {
		if sampler^ == 0 { return }
		name := u32(sampler^)
		gl.DeleteSamplers(1, &name)
		sampler^ = 0
	}

	// 1 when anisotropic filtering is unsupported. Queried per call: callers
	// cache it (client.max_anisotropy), and it must follow the current context.
	gl_gpu_max_anisotropy :: proc() -> f32 {
		value: f32 = 1
		if bool(glfw.ExtensionSupported("GL_EXT_texture_filter_anisotropic")) || bool(glfw.ExtensionSupported("GL_ARB_texture_filter_anisotropic")) {
			gl.GetFloatv(0x84FF, &value) // MAX_TEXTURE_MAX_ANISOTROPY_EXT
		}
		return max(value, 1)
	}

	gl_gpu_max_texture_size :: proc() -> i32 {
		value: i32
		gl.GetIntegerv(gl.MAX_TEXTURE_SIZE, &value)
		return value
	}

	// A depth-only target rendering into `depth`: layer `layer` of an array
	// texture, or the whole 2D texture when layer < 0.
	gl_gpu_render_target_create_depth :: proc(depth: Gpu_Texture, layer: i32 = -1) -> Gpu_Render_Target {
		if depth == 0 { return 0 }
		fbo: u32
		gl.CreateFramebuffers(1, &fbo)
		if layer >= 0 {
			gl.NamedFramebufferTextureLayer(fbo, gl.DEPTH_ATTACHMENT, u32(depth), 0, layer)
		} else {
			gl.NamedFramebufferTexture(fbo, gl.DEPTH_ATTACHMENT, u32(depth), 0)
		}
		gl.NamedFramebufferDrawBuffer(fbo, gl.NONE)
		gl.NamedFramebufferReadBuffer(fbo, gl.NONE)
		return Gpu_Render_Target(fbo)
	}

	// Destroys a depth-only or colour target. Safe on 0.
	gl_gpu_render_target_destroy :: proc(target: ^Gpu_Render_Target) {
		if target^ == 0 { return }
		fbo := u32(target^)
		if t, ok := g_gl_color_targets[fbo]; ok {
			color, depth := t.color, t.depth
			gl.DeleteRenderbuffers(1, &color)
			gl.DeleteRenderbuffers(1, &depth)
			delete_key(&g_gl_color_targets, fbo)
		}
		gl.DeleteFramebuffers(1, &fbo)
		target^ = 0
	}

	// Starts a depth-only pass over a size x size target: depth test and writes
	// on, blending off, depth cleared to 1. cull_front culls front faces (shadow
	// acne); otherwise nothing is culled.
	gl_gpu_depth_pass_begin :: proc(target: Gpu_Render_Target, size: i32, cull_front: bool) {
		gpu_flush_deferred()
		gl.BindFramebuffer(gl.FRAMEBUFFER, u32(target))
		gl.Viewport(0, 0, size, size)
		gl_gpu_draw_state_reset()
		gl.Clear(gl.DEPTH_BUFFER_BIT)
		if cull_front {
			gl.Enable(gl.CULL_FACE)
			gl.CullFace(gl.FRONT)
		} else {
			gl.Disable(gl.CULL_FACE)
		}
	}

	// Ends a run of depth passes and rebinds the frame's target. The caller names
	// the target and viewport to go back to (reading them back with glGet would
	// stall threaded drivers).
	gl_gpu_depth_pass_end :: proc(restore: Gpu_Render_Target, viewport: [4]i32) {
		gl.Disable(gl.CULL_FACE)
		gl.CullFace(gl.BACK)
		gl.BindFramebuffer(gl.FRAMEBUFFER, u32(restore))
		gl.Viewport(viewport[0], viewport[1], viewport[2], viewport[3])
	}

	// Immutable: `data` (len(data) bytes) is the whole contents for the buffer's
	// lifetime. `kind` matters to Vulkan's usage flags, not to GL.
	gl_gpu_buffer_create :: proc(kind: Gpu_Buffer_Kind, data: []u8) -> Gpu_Buffer {
		if len(data) == 0 { return 0 }
		name: u32
		gl.CreateBuffers(1, &name)
		gl.NamedBufferStorage(name, len(data), raw_data(data), 0)
		return Gpu_Buffer(name)
	}

	gl_gpu_buffer_destroy :: proc(buffer: ^Gpu_Buffer) {
		if buffer^ == 0 { return }
		name := u32(buffer^)
		gl.DeleteBuffers(1, &name)
		buffer^ = 0
	}

	// Makes a storage buffer readable as `layout(std430, binding = binding)`.
	gl_gpu_buffer_bind_storage :: proc(binding: u32, buffer: Gpu_Buffer) {
		gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, binding, u32(buffer))
	}

	gl_gpu_max_storage_buffer_size :: proc() -> i64 {
		value: i64
		gl.GetInteger64v(gl.MAX_SHADER_STORAGE_BLOCK_SIZE, &value)
		return value
	}

	gl_gpu_vertex_input_create :: proc(layout: Gpu_Vertex_Layout, vertices, indices: Gpu_Buffer) -> Gpu_Vertex_Input {
		// .UI data is per frame: gpu_transient_bind.
		if vertices == 0 || indices == 0 || layout == .UI || layout == .Debug_Line { return 0 }
		vao: u32
		gl.CreateVertexArrays(1, &vao)
		gl.VertexArrayElementBuffer(vao, u32(indices))
		attribs: u32
		switch layout {
		case .Basic:
			gl.VertexArrayVertexBuffer(vao, 0, u32(vertices), 0, size_of(Vertex))
			gl.VertexArrayAttribFormat(vao, 0, 3, gl.FLOAT, false, u32(offset_of(Vertex, position)))
			gl.VertexArrayAttribFormat(vao, 1, 2, gl.FLOAT, false, u32(offset_of(Vertex, tex_coord)))
			attribs = 2
		case .Batched:
			gl.VertexArrayVertexBuffer(vao, 0, u32(vertices), 0, size_of(Batched_Vertex))
			gl.VertexArrayAttribFormat(vao, 0, 3, gl.FLOAT, false, u32(offset_of(Batched_Vertex, position)))
			gl.VertexArrayAttribFormat(vao, 1, 2, gl.FLOAT, false, u32(offset_of(Batched_Vertex, tex_coord)))
			gl.VertexArrayAttribFormat(vao, 2, 1, gl.FLOAT, false, u32(offset_of(Batched_Vertex, face_idx)))
			gl.VertexArrayAttribFormat(vao, 3, 1, gl.FLOAT, false, u32(offset_of(Batched_Vertex, object_index)))
			attribs = 4
		case .UI, .Debug_Line:
		}
		for attrib in 0 ..< attribs {
			gl.EnableVertexArrayAttrib(vao, attrib)
			gl.VertexArrayAttribBinding(vao, attrib, 0)
		}
		return Gpu_Vertex_Input(vao)
	}

	gl_gpu_vertex_input_bind :: proc(input: Gpu_Vertex_Input) {
		gl.BindVertexArray(u32(input))
		g_gl_index_base = 0
		g_gl_topology = gl.TRIANGLES
	}

	// Lines for the .Debug_Line layout, triangles otherwise.
	@(private = "file")
	g_gl_topology: u32 = gl.TRIANGLES

	// Byte offset of index 0 in the bound element buffer: 0 for vertex inputs,
	// the ring position after gpu_transient_bind.
	@(private = "file")
	g_gl_index_base: uintptr

	// Destroys only the input; its buffers are destroyed separately.
	gl_gpu_vertex_input_destroy :: proc(input: ^Gpu_Vertex_Input) {
		if input^ == 0 { return }
		vao := u32(input^)
		gl.DeleteVertexArrays(1, &vao)
		input^ = 0
	}

	// Uniform data for the next draws lives in one persistently mapped ring
	// buffer: a push is a memcpy plus a range bind, with no buffer update for the
	// driver to serialize against draws in flight. The ring is split into
	// segments; entering a segment waits for the fence placed when that segment
	// was last left, so memory is never rewritten while the GPU may still read
	// it. (Vulkan: per-frame dynamic uniform buffer offsets.) The ring belongs to
	// the context that created it; tests destroy and recreate contexts.
	GPU_UNIFORM_RING_SIZE :: 8 << 20
	GPU_UNIFORM_RING_SEGMENTS :: 4
	GPU_UNIFORM_SEGMENT_SIZE :: GPU_UNIFORM_RING_SIZE / GPU_UNIFORM_RING_SEGMENTS
	// Per-frame vertices and indices (gpu_transient_bind), same scheme.
	GPU_TRANSIENT_RING_SIZE :: 32 << 20

	@(private = "file")
	Gl_Uniform_Ring :: struct {
		buffer:   u32,
		mapped:   [^]u8,
		offset:   int,
		align:    int,
		segment:  int,
		segment_size: int,
		fences:   [GPU_UNIFORM_RING_SEGMENTS]gl.sync_t,
		context_: glfw.WindowHandle,
		vaos:     [Gpu_Vertex_Layout]u32, // transient ring: the vertex inputs reading it
	}

	@(private = "file")
	g_uniform_ring: Gl_Uniform_Ring

	@(private = "file")
	g_transient_ring: Gl_Uniform_Ring

	@(private = "file")
	gl_uniform_ring_init :: proc(ring: ^Gl_Uniform_Ring, size: int = GPU_UNIFORM_RING_SIZE, align: int = 0) {
		flags := u32(gl.MAP_WRITE_BIT | gl.MAP_PERSISTENT_BIT | gl.MAP_COHERENT_BIT)
		gl.CreateBuffers(1, &ring.buffer)
		gl.NamedBufferStorage(ring.buffer, size, nil, flags)
		ring.mapped = cast([^]u8)gl.MapNamedBufferRange(ring.buffer, 0, size, flags)
		ring.segment_size = size / GPU_UNIFORM_RING_SEGMENTS
		if align > 0 {
			ring.align = align
		} else {
			uniform_align: i32
			gl.GetIntegerv(gl.UNIFORM_BUFFER_OFFSET_ALIGNMENT, &uniform_align)
			ring.align = max(int(uniform_align), 16)
		}
	}

	// Leaves the current segment (fencing it) and waits until the next one is
	// no longer read by the GPU.
	@(private = "file")
	gl_uniform_ring_advance :: proc(ring: ^Gl_Uniform_Ring) {
		ring.fences[ring.segment] = gl.FenceSync(gl.SYNC_GPU_COMMANDS_COMPLETE, 0)
		ring.segment = (ring.segment + 1) % GPU_UNIFORM_RING_SEGMENTS
		ring.offset = ring.segment * ring.segment_size
		if fence := ring.fences[ring.segment]; fence != nil {
			for {
				result := gl.ClientWaitSync(fence, gl.SYNC_FLUSH_COMMANDS_BIT, 1_000_000_000)
				if result != gl.TIMEOUT_EXPIRED { break }
			}
			gl.DeleteSync(fence)
			ring.fences[ring.segment] = nil
		}
	}

	// Uploads `data` and binds it as uniform block `binding` for the following
	// draws. `data` must be laid out std140.
	gl_gpu_uniform_push :: proc(binding: u32, data: []u8) {
		ring := &g_uniform_ring
		current := glfw.GetCurrentContext()
		if ring.context_ != current {
			// The old context (and its buffer) is gone or not current: forget it.
			ring^ = {context_ = current}
		}
		if ring.buffer == 0 { gl_uniform_ring_init(ring) }
		size := len(data)
		if size == 0 || size > GPU_UNIFORM_SEGMENT_SIZE || ring.mapped == nil { return }
		if ring.offset + size > (ring.segment + 1) * ring.segment_size { gl_uniform_ring_advance(ring) }
		copy(ring.mapped[ring.offset:][:size], data)
		gl.BindBufferRange(gl.UNIFORM_BUFFER, binding, ring.buffer, ring.offset, size)
		ring.offset = (ring.offset + size + ring.align - 1) / ring.align * ring.align
	}

	// Frees the current context's uniform and transient rings
	// (resource_cache_fini).
	gl_gpu_uniforms_fini :: proc() {
		for ring in ([2]^Gl_Uniform_Ring{&g_uniform_ring, &g_transient_ring}) {
			if ring.buffer != 0 && ring.context_ == glfw.GetCurrentContext() {
				for fence in ring.fences { if fence != nil { gl.DeleteSync(fence) } }
				for &vao in ring.vaos { if vao != 0 { gl.DeleteVertexArrays(1, &vao) } }
				gl.UnmapNamedBuffer(ring.buffer)
				gl.DeleteBuffers(1, &ring.buffer)
			}
			ring^ = {}
		}
	}

	// Copies this frame's vertices (laid out as `layout`) and indices into the
	// transient ring and binds them for the following gpu_draw_indexed calls,
	// whose first_index counts from the start of `indices`. .UI and
	// .Debug_Line. False when the data does not fit (a quarter of the ring).
	gl_gpu_transient_bind :: proc(layout: Gpu_Vertex_Layout, vertices: []u8, indices: []u32) -> bool {
		assert(layout == .UI || layout == .Debug_Line)
		ring := &g_transient_ring
		current := glfw.GetCurrentContext()
		if ring.context_ != current { ring^ = {context_ = current} }
		if ring.buffer == 0 { gl_uniform_ring_init(ring, GPU_TRANSIENT_RING_SIZE, 16) }
		vertex_bytes := (len(vertices) + 15) &~ 15
		index_bytes := len(indices) * size_of(u32)
		size := vertex_bytes + index_bytes
		if size == 0 || size > ring.segment_size || ring.mapped == nil { return false }
		if ring.offset + size > (ring.segment + 1) * ring.segment_size { gl_uniform_ring_advance(ring) }
		vertex_offset := ring.offset
		index_offset := vertex_offset + vertex_bytes
		copy(ring.mapped[vertex_offset:][:len(vertices)], vertices)
		copy(ring.mapped[index_offset:][:index_bytes], ([^]u8)(raw_data(indices))[:index_bytes])
		ring.offset = (index_offset + index_bytes + 15) &~ 15
		Format :: struct{size: i32, offset: uintptr}
		formats: []Format
		stride: i32
		if layout == .UI {
			@(static) ui := [6]Format{
				{2, offset_of(UI_Vertex, position)}, {2, offset_of(UI_Vertex, local)}, {2, offset_of(UI_Vertex, uv)},
				{4, offset_of(UI_Vertex, color)}, {4, offset_of(UI_Vertex, radii)}, {4, offset_of(UI_Vertex, params)},
			}
			formats, stride = ui[:], size_of(UI_Vertex)
		} else {
			@(static) lines := [2]Format{{3, offset_of(Debug_Line_Vertex, position)}, {4, offset_of(Debug_Line_Vertex, color)}}
			formats, stride = lines[:], size_of(Debug_Line_Vertex)
		}
		vao := &ring.vaos[layout]
		if vao^ == 0 {
			gl.CreateVertexArrays(1, vao)
			for f, attrib in formats {
				gl.VertexArrayAttribFormat(vao^, u32(attrib), f.size, gl.FLOAT, false, u32(f.offset))
				gl.EnableVertexArrayAttrib(vao^, u32(attrib))
				gl.VertexArrayAttribBinding(vao^, u32(attrib), 0)
			}
			gl.VertexArrayElementBuffer(vao^, ring.buffer)
		}
		gl.VertexArrayVertexBuffer(vao^, 0, ring.buffer, vertex_offset, stride)
		gl.BindVertexArray(vao^)
		g_gl_index_base = uintptr(index_offset)
		g_gl_topology = layout == .Debug_Line ? gl.LINES : gl.TRIANGLES
		return true
	}

	// ---------------------------------------------------------------------------
	// Programs and draws.

	gl_gpu_program_create_basic :: proc(batched, shadow_depth: bool) -> Gpu_Program {
		return Gpu_Program(basic_program_compile(batched, shadow_depth))
	}

	gl_gpu_program_destroy :: proc(program: ^Gpu_Program) {
		if program^ == 0 { return }
		if g_active_shader == u32(program^) { g_active_shader = 0 }
		gl.DeleteProgram(u32(program^))
		program^ = 0
	}

	gl_gpu_program_bind :: proc(program: Gpu_Program) {
		if g_active_shader == u32(program) { return }
		gl.UseProgram(u32(program))
		g_active_shader = u32(program)
	}

	// What the GL state machine holds for the draw state; `known` is false after
	// code outside this interface may have changed it.
	@(private = "file")
	g_gl_draw: struct {
		state: Gpu_Draw_State,
		known: bool,
	}

	@(private = "file")
	gl_apply_draw_state :: proc(state: Gpu_Draw_State, force: bool) {
		current := g_gl_draw.state
		if force || current.blend != state.blend {
			if state.blend { gl.Enable(gl.BLEND) } else { gl.Disable(gl.BLEND) }
		}
		if force || current.depth_write != state.depth_write {
			gl.DepthMask(state.depth_write ? gl.TRUE : gl.FALSE)
		}
		if force || current.wireframe != state.wireframe {
			gl.PolygonMode(gl.FRONT_AND_BACK, state.wireframe ? gl.LINE : gl.FILL)
		}
		if force || current.depth_test != state.depth_test {
			switch state.depth_test {
			case .Off:        gl.Disable(gl.DEPTH_TEST)
			case .Less:       gl.Enable(gl.DEPTH_TEST); gl.DepthFunc(gl.LESS)
			case .Less_Equal: gl.Enable(gl.DEPTH_TEST); gl.DepthFunc(gl.LEQUAL)
			}
		}
		g_gl_draw = {state = state, known = true}
	}

	gl_gpu_draw_state_set :: proc(state: Gpu_Draw_State) {
		gl_apply_draw_state(state, !g_gl_draw.known)
	}

	// Starts a run of world draws: depth test on and the default draw state,
	// whatever other code (HUD, tests) left behind. Also called after one, so
	// world state never leaks into the HUD.
	gl_gpu_draw_state_reset :: proc() {
		gpu_flush_deferred()
		gl.Enable(gl.DEPTH_TEST)
		gl.ActiveTexture(gl.TEXTURE0)
		gl_apply_draw_state(GPU_DRAW_STATE_DEFAULT, true)
	}

	gl_gpu_draw_indexed :: proc(index_count: i32, first_index: u32) {
		gl.DrawElements(g_gl_topology, index_count, gl.UNSIGNED_INT, rawptr(g_gl_index_base + uintptr(first_index) * size_of(u32)))
	}

	// Clips draws to `rect` (x, y, width, height in target pixels, y up from
	// the bottom row: glScissor's convention) until disabled.
	gl_gpu_scissor :: proc(enabled: bool, rect: [4]i32 = {}) {
		if !enabled { gl.Disable(gl.SCISSOR_TEST); return }
		gl.Enable(gl.SCISSOR_TEST)
		gl.Scissor(rect[0], rect[1], max(rect[2], 0), max(rect[3], 0))
	}

	gl_gpu_program_create_debug_lines :: proc() -> Gpu_Program {
		dir := shared.concat(shared.assets_path(), "shaders/")
		defer delete(dir)
		vert := shared.concat(dir, "debug_line.vert")
		defer delete(vert)
		frag := shared.concat(dir, "debug_line.frag")
		defer delete(frag)
		return Gpu_Program(shader_compile(vert, frag))
	}

	gl_gpu_program_create_ui :: proc() -> Gpu_Program {
		dir := shared.concat(shared.assets_path(), "shaders/")
		defer delete(dir)
		return Gpu_Program(shader_compile_ui(dir, "ui.vert", "ui.frag"))
	}

	// ---------------------------------------------------------------------------
	// Colour targets, clears and readback.

	@(private = "file")
	Gl_Color_Target :: struct {
		color, depth: u32,
	}

	@(private = "file")
	g_gl_color_targets: map[u32]Gl_Color_Target

	// An RGBA8 colour + depth target (offscreen frames, tests, the benchmark).
	gl_gpu_render_target_create :: proc(width, height: i32) -> Gpu_Render_Target {
		fbo: u32
		target: Gl_Color_Target
		gl.CreateFramebuffers(1, &fbo)
		gl.CreateRenderbuffers(1, &target.color)
		gl.CreateRenderbuffers(1, &target.depth)
		gl.NamedRenderbufferStorage(target.color, gl.RGBA8, width, height)
		gl.NamedRenderbufferStorage(target.depth, gl.DEPTH24_STENCIL8, width, height)
		gl.NamedFramebufferRenderbuffer(fbo, gl.COLOR_ATTACHMENT0, gl.RENDERBUFFER, target.color)
		gl.NamedFramebufferRenderbuffer(fbo, gl.DEPTH_STENCIL_ATTACHMENT, gl.RENDERBUFFER, target.depth)
		g_gl_color_targets[fbo] = target
		return Gpu_Render_Target(fbo)
	}

	// Draws go to `target` (0: the window) over a width x height viewport.
	gl_gpu_set_target :: proc(target: Gpu_Render_Target, width, height: i32) {
		gpu_flush_deferred()
		gl.BindFramebuffer(gl.FRAMEBUFFER, u32(target))
		gl.Viewport(0, 0, width, height)
	}

	gl_gpu_set_clear_color :: proc(color: [3]f32) {
		gl.ClearColor(color.r, color.g, color.b, 1)
	}

	// Clears the current target's colour (to gpu_set_clear_color's) and/or depth.
	gl_gpu_clear :: proc(color, depth: bool) {
		gpu_flush_deferred()
		mask: u32
		if color { mask |= gl.COLOR_BUFFER_BIT }
		if depth {
			mask |= gl.DEPTH_BUFFER_BIT
			// glClear honours the depth mask.
			gl.DepthMask(gl.TRUE)
			g_gl_draw.state.depth_write = true
		}
		if mask != 0 { gl.Clear(mask) }
	}

	// RGB8 pixels of `target`, rows bottom-up (GL's order; the Vulkan backend
	// renders in the same orientation).
	gl_gpu_read_color_rgb :: proc(target: Gpu_Render_Target, width, height: i32, pixels: []u8) {
		if len(pixels) < int(width) * int(height) * 3 { return }
		gpu_flush_deferred()
		gl.BindFramebuffer(gl.READ_FRAMEBUFFER, u32(target))
		gl.PixelStorei(gl.PACK_ALIGNMENT, 1)
		gl.ReadPixels(0, 0, width, height, gl.RGB, gl.UNSIGNED_BYTE, raw_data(pixels))
		gl.PixelStorei(gl.PACK_ALIGNMENT, 4)
		gl.BindFramebuffer(gl.READ_FRAMEBUFFER, 0)
	}

	// Depth values of `target`, bottom-up. Only equality between two reads on the
	// same backend is meaningful (GL: normalized u32; Vulkan: f32 bits).
	gl_gpu_read_depth :: proc(target: Gpu_Render_Target, width, height: i32, depth: []u32) {
		if len(depth) < int(width) * int(height) { return }
		gpu_flush_deferred()
		gl.BindFramebuffer(gl.READ_FRAMEBUFFER, u32(target))
		gl.PixelStorei(gl.PACK_ALIGNMENT, 4)
		gl.ReadPixels(0, 0, width, height, gl.DEPTH_COMPONENT, gl.UNSIGNED_INT, raw_data(depth))
		gl.BindFramebuffer(gl.READ_FRAMEBUFFER, 0)
	}

	// ---------------------------------------------------------------------------
	// Frames: GPU timing and frames in flight (benchmark).

	@(private = "file")
	g_gl_frames: struct {
		queries:   [GPU_FRAMES_IN_FLIGHT]u32,
		fences:    [GPU_FRAMES_IN_FLIGHT]gl.sync_t,
		pending:   [GPU_FRAMES_IN_FLIGHT]bool,
		slot:      int,
		ready:     bool,
		completed: [dynamic]f64, // GPU ms of finished frames not yet taken
	}

	@(private = "file")
	gl_frame_collect :: proc(slot: int) {
		frames := &g_gl_frames
		if frames.fences[slot] != nil {
			gl.ClientWaitSync(frames.fences[slot], gl.SYNC_FLUSH_COMMANDS_BIT, 5_000_000_000)
			gl.DeleteSync(frames.fences[slot])
			frames.fences[slot] = nil
		}
		if !frames.pending[slot] { return }
		ns: u64
		gl.GetQueryObjectui64v(frames.queries[slot], gl.QUERY_RESULT, &ns)
		frames.pending[slot] = false
		append(&frames.completed, f64(ns) / 1e6)
	}

	// Waits until the frame that last used the next slot is done: at most
	// GPU_FRAMES_IN_FLIGHT frames are ever queued. gpu_frame_begin does this too;
	// calling it first lets a caller time the frame without the wait.
	gl_gpu_frame_wait :: proc() {
		gl_frame_collect(g_gl_frames.slot)
	}

	gl_gpu_frame_begin :: proc() {
		frames := &g_gl_frames
		if !frames.ready {
			gl.GenQueries(GPU_FRAMES_IN_FLIGHT, &frames.queries[0])
			frames.ready = true
		}
		gl_frame_collect(frames.slot)
		gl.BeginQuery(gl.TIME_ELAPSED, frames.queries[frames.slot])
	}

	gl_gpu_frame_end :: proc() {
		gpu_flush_deferred()
		frames := &g_gl_frames
		gl.EndQuery(gl.TIME_ELAPSED)
		frames.pending[frames.slot] = true
		frames.fences[frames.slot] = gl.FenceSync(gl.SYNC_GPU_COMMANDS_COMPLETE, 0)
		gl.Flush()
		frames.slot = (frames.slot + 1) % GPU_FRAMES_IN_FLIGHT
	}

	// Waits for every frame in flight.
	gl_gpu_frames_finish :: proc() {
		for i in 0 ..< GPU_FRAMES_IN_FLIGHT { gl_frame_collect((g_gl_frames.slot + i) % GPU_FRAMES_IN_FLIGHT) }
	}

	// Appends the GPU times (ms, in frame order) of finished frames not taken
	// yet; nil discards them.
	gl_gpu_frames_take :: proc(gpu_ms: ^[dynamic]f64) {
		if gpu_ms != nil { append(gpu_ms, ..g_gl_frames.completed[:]) }
		clear(&g_gl_frames.completed)
	}

	gl_gpu_frames_fini :: proc() {
		gl_gpu_frames_finish()
		if g_gl_frames.ready { gl.DeleteQueries(GPU_FRAMES_IN_FLIGHT, &g_gl_frames.queries[0]) }
		delete(g_gl_frames.completed)
		g_gl_frames = {}
	}

	gl_gpu_wait_idle :: proc() {
		gl.Finish()
	}

	// ---------------------------------------------------------------------------
	// Window.

	// GL draws window frames straight into the default framebuffer.
	gl_gpu_window_target :: proc() -> Gpu_Render_Target { return 0 }

	gl_gpu_set_vsync :: proc(on: bool) {
		glfw.SwapInterval(on ? 1 : 0)
	}

	gl_gpu_present :: proc(window: glfw.WindowHandle) {
		gpu_flush_deferred()
		glfw.SwapBuffers(window)
	}

	gl_gpu_backend_name :: proc() -> string { return "OpenGL" }

	gl_gpu_device_info :: proc() -> Gpu_Device_Info {
		gl_string :: proc(name: u32) -> string {
			value := cstring(gl.GetString(name))
			return value == nil ? "" : string(value)
		}
		return {api = "OpenGL", vendor = gl_string(gl.VENDOR), renderer = gl_string(gl.RENDERER), version = gl_string(gl.VERSION)}
	}

	// GL reports resets through glGetGraphicsResetStatus (gpu_reset.odin).
	gl_gpu_device_lost :: proc() -> bool { return false }

	gl_gpu_device_name :: proc() -> string {
		renderer := cstring(gl.GetString(gl.RENDERER))
		return renderer == nil ? "unknown GL renderer" : string(renderer)
	}

// What placeholder objects and per-context caches belong to.
gl_gpu_context_token :: proc() -> rawptr {
	return rawptr(glfw.GetCurrentContext())
}

