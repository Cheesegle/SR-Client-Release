package main

import glfw "vendor:glfw"

// Backend-neutral GPU interface (Vulkan port, Phase 1).
//
// Renderer code creates, updates, binds and destroys GPU resources only
// through the gpu_* procedures; each backend (gpu_gl.odin today, Vulkan next)
// implements them. Handles are opaque: 0 always means "none", and nothing
// outside the backend may assume what the value is. On the GL backend a
// handle's value happens to be the GL object name, so code that has not been
// moved behind this interface yet can still cast it (u32(handle)) to call GL
// directly. Every such cast marks a site the port still has to convert.

// Both backends are in every build (the SPIR-V the Vulkan one embeds comes
// from tools/build-spirv.ps1, run by build.bat). The player picks one in
// Settings (Graphics API) or with --vulkan / --opengl; Vulkan falls back to
// OpenGL when the GPU cannot run it.
Gpu_Backend :: enum u8 {
	OpenGL,
	Vulkan,
}

// Which backend gpu_* calls go to (see the dispatchers at the end).
g_gpu_backend: Gpu_Backend

// Tests (and only tests) run on Vulkan when built with
// -define:SR_VULKAN=true (build.bat tests-vk); GL-only tests are left
// out of that build with `when !SR_VULKAN`.
SR_VULKAN :: #config(SR_VULKAN, false)

Gpu_Texture :: distinct u32
// A separate sampler object; bound over a texture's own sampling.
Gpu_Sampler :: distinct u32
// Something a pass renders into: a colour+depth target (offscreen frames,
// tests, the benchmark) or a depth-only one (shadow maps). 0 is the window.
Gpu_Render_Target :: distinct u32
// A compiled shader program: a world shader variant or the interface shader.
Gpu_Program :: distinct u32
// GPU memory holding vertices, indices or shader-readable storage.
Gpu_Buffer :: distinct u32
// A vertex buffer and an index buffer read with one Gpu_Vertex_Layout: what a
// draw binds. A VAO on GL; on Vulkan the layout belongs to the pipeline and
// this only names the two buffers.
Gpu_Vertex_Input :: distinct u32

Gpu_Buffer_Kind :: enum u8 {
	Vertex,
	Index,   // u32 indices
	Storage, // std430 shader storage
}

// Shader resource bindings shared by every backend. Uniform blocks: the
// per-pass block and the per-draw block. Storage buffers: the map batches'
// objects. Texture units: the colour texture, the sun shadow map array and
// the player shadow map.
GPU_BINDING_PASS    :: 0
GPU_BINDING_DRAW    :: 1
GPU_BINDING_OBJECTS :: 0
GPU_UNIT_COLOR         :: 0
GPU_UNIT_SHADOW        :: 1
GPU_UNIT_PLAYER_SHADOW :: 2

Gpu_Depth_Test :: enum u8 {
	Less,       // the world's test (the zero value)
	Off,        // flat overlays: the interface, nameplates
	Less_Equal, // lines over the surfaces they outline (debug overlay)
}

// Fixed-function state of a draw. Culling is a property of the pass (shadow
// passes cull front faces).
Gpu_Draw_State :: struct {
	blend:       bool, // src alpha, one minus src alpha
	depth_write: bool,
	wireframe:   bool,
	depth_test:  Gpu_Depth_Test,
}
GPU_DRAW_STATE_DEFAULT :: Gpu_Draw_State{depth_write = true}

// Frames in flight: gpu_frame_begin waits for the frame that last used its slot.
GPU_FRAMES_IN_FLIGHT :: 2

// Sections of a frame timed on the GPU (gpu_pass_mark), in frame order. A
// section lasts from its mark to the next mark the frame wrote, or the
// frame's end; sections a frame skips (Resolve without MSAA) are not counted.
Gpu_Pass :: enum u8 {
	Shadows,   // shadow maps
	World,     // the map, players and effects
	Viewmodel, // your weapon and arms
	Resolve,   // MSAA resolve
	Interface, // healthbars, HUD, menus, cursor
	Present,   // copy to the window (Vulkan) and present
}

// Per-pass GPU time of finished frames, summed until gpu_pass_times_take.
g_gpu_pass_times: struct {
	sum:    [Gpu_Pass]f64,
	frames: [Gpu_Pass]int,
}

// Splits one finished frame's timestamps (ns, ordered as Gpu_Pass) into
// section durations.
gpu_pass_times_add :: proc(stamps: [Gpu_Pass]u64, marked: bit_set[Gpu_Pass], end_ns: u64) {
	for pass in Gpu_Pass {
		if pass not_in marked { continue }
		next := end_ns
		for later := int(pass) + 1; later < len(Gpu_Pass); later += 1 {
			if Gpu_Pass(later) in marked { next = stamps[Gpu_Pass(later)]; break }
		}
		if next < stamps[pass] { continue }
		g_gpu_pass_times.sum[pass] += f64(next - stamps[pass]) / 1e6
		g_gpu_pass_times.frames[pass] += 1
	}
}

// Average ms per section since the last call (0 for sections not run).
gpu_pass_times_take :: proc() -> (average: [Gpu_Pass]f64) {
	for pass in Gpu_Pass {
		if n := g_gpu_pass_times.frames[pass]; n > 0 { average[pass] = g_gpu_pass_times.sum[pass] / f64(n) }
	}
	g_gpu_pass_times = {}
	return
}

// Marks the start of a timed section in the frame being recorded.
gpu_pass_mark :: proc(pass: Gpu_Pass) {
	if g_gpu_backend == .Vulkan { vk_gpu_pass_mark(pass); return }
	gl_gpu_pass_mark(pass)
}

// Every vertex format the renderer draws from buffers. Attribute locations
// are fixed per layout and match the shaders' `layout(location = n)`.
Gpu_Vertex_Layout :: enum u8 {
	Basic,   // Vertex: position (0), tex_coord (1)
	Batched, // Batched_Vertex: position (0), tex_coord (1), face_idx (2), object_index (3)
	UI,      // UI_Vertex: position (0), local (1), uv (2), color (3), radii (4), params (5)
	// Debug_Line_Vertex: position (0), color (1). Drawn as a line list (pairs
	// of indices) rather than triangles.
	Debug_Line,
}

// Batched work a caller keeps on the CPU (the interface's draw list) is drawn
// before anything else touches the GPU: each backend calls
// gpu_flush_deferred first thing in its clears, target and pass changes,
// readbacks, presents and other programs' draws. Code that draws or reads
// behind this interface (raw GL in tests) calls ui_flush itself.
g_gpu_deferred: struct {
	flush: proc(),
	busy:  bool, // inside flush: its own draws must not recurse
}

gpu_flush_deferred :: proc() {
	if g_gpu_deferred.flush == nil || g_gpu_deferred.busy { return }
	g_gpu_deferred.busy = true
	g_gpu_deferred.flush()
	g_gpu_deferred.busy = false
}

Gpu_Format :: enum u8 {
	RGBA8, // 4 bytes per pixel, rows tightly packed
	R8,    // 1 byte per pixel (glyph coverage), rows tightly packed
	// Depth only, sampled through a comparison sampler (shadow maps). 24-bit
	// on GL; D32_SFLOAT on Vulkan, where D24 is optional. Uploads are f32.
	Depth,
}

Gpu_Filter :: enum u8 {
	Nearest,
	Linear,
}

Gpu_Wrap :: enum u8 {
	Repeat,
	Clamp,
}

// How a texture is sampled when no separate sampler overrides it (the world
// pass binds client.graphics_sampler over these). Vulkan bakes this into the
// texture's descriptor, so changing it later goes through
// gpu_texture_set_filter rather than a raw parameter write.
Gpu_Sampler_Desc :: struct {
	filter:     Gpu_Filter, // minification and magnification
	mip_filter: bool,       // pick the nearest mip level when minifying
	mip_linear: bool,       // with mip_filter: blend the two nearest levels instead
	wrap:       Gpu_Wrap,
	// Depth comparison (reference <= stored), for shadow samplers.
	compare:    bool,
}

Gpu_Texture_Desc :: struct {
	width, height: i32,
	format:        Gpu_Format,
	// > 0 makes a 2D array texture with this many layers; 0 a plain 2D one.
	layers:        i32,
	// Allocate a full mip chain and build it from level 0 after upload.
	mipmaps:       bool,
	sampler:       Gpu_Sampler_Desc,
}

// Upload-time filtering of the map's prefab textures: sharp pixels, mip
// selection on minify, tiled.
GPU_SAMPLER_WORLD :: Gpu_Sampler_Desc{filter = .Nearest, mip_filter = true, wrap = .Repeat}
GPU_SAMPLER_UI_LINEAR :: Gpu_Sampler_Desc{filter = .Linear, wrap = .Clamp}
GPU_SAMPLER_UI_NEAREST :: Gpu_Sampler_Desc{filter = .Nearest, wrap = .Clamp}

// What reports name the GPU by (gpu_device_info). The strings stay valid
// until the backend shuts down.
Gpu_Device_Info :: struct {
	api:      string, // "OpenGL", "Vulkan"
	vendor:   string,
	renderer: string,
	version:  string, // API and driver version
}

// A GPU reset status (gpu_reset_poll) that is not glGetGraphicsResetStatus's:
// the Vulkan device was lost (VK_ERROR_DEVICE_LOST).
GPU_RESET_DEVICE_LOST :: 0x1_0000

gpu_format_bytes_per_pixel :: proc(format: Gpu_Format) -> int {
	switch format {
	case .RGBA8: return 4
	case .R8:    return 1
	case .Depth: return 4
	}
	return 0
}

// The texture sampled by untextured materials: one opaque white texel,
// created on first use and kept until resource_cache_fini.
gpu_blank_texture :: proc() -> Gpu_Texture {
	if g_blank_texture == 0 {
		white := [4]u8{255, 255, 255, 255}
		g_blank_texture = gpu_texture_create({width = 1, height = 1, format = .RGBA8, sampler = GPU_SAMPLER_UI_NEAREST}, white[:])
	}
	return g_blank_texture
}

// Binds `texture` (0 = the blank texture) for the colour sampler on unit 0.
// Consecutive binds of the same texture are skipped; g_active_texture is the
// cache, and anything that binds a texture behind this interface's back must
// reset it to 0.
gpu_bind_color_texture :: proc(texture: Gpu_Texture) {
	target := texture != 0 ? texture : gpu_blank_texture()
	if g_active_texture == target { return }
	gpu_texture_bind(0, target)
	g_active_texture = target
}

// ---------------------------------------------------------------------------
// Backend dispatch: one exe carries both backends (gpu_gl.odin, gpu_vk.odin);
// g_gpu_backend picks which one every gpu_* call goes to. It is set once,
// before the device or context exists, and never changes while it does.

gpu_backend_name :: proc() -> string {
	if g_gpu_backend == .Vulkan { return vk_gpu_backend_name() }
	return gl_gpu_backend_name()
}

gpu_buffer_bind_storage :: proc(binding: u32, buffer: Gpu_Buffer) {
	if g_gpu_backend == .Vulkan { vk_gpu_buffer_bind_storage(binding, buffer); return }
	gl_gpu_buffer_bind_storage(binding, buffer)
}

gpu_buffer_create :: proc(kind: Gpu_Buffer_Kind, data: []u8) -> Gpu_Buffer {
	if g_gpu_backend == .Vulkan { return vk_gpu_buffer_create(kind, data) }
	return gl_gpu_buffer_create(kind, data)
}

gpu_buffer_destroy :: proc(buffer: ^Gpu_Buffer) {
	if g_gpu_backend == .Vulkan { vk_gpu_buffer_destroy(buffer); return }
	gl_gpu_buffer_destroy(buffer)
}

gpu_clear :: proc(color, depth: bool) {
	if g_gpu_backend == .Vulkan { vk_gpu_clear(color, depth); return }
	gl_gpu_clear(color, depth)
}

gpu_context_token :: proc() -> rawptr {
	if g_gpu_backend == .Vulkan { return vk_gpu_context_token() }
	return gl_gpu_context_token()
}

gpu_depth_pass_begin :: proc(target: Gpu_Render_Target, size: i32, cull_front: bool) {
	if g_gpu_backend == .Vulkan { vk_gpu_depth_pass_begin(target, size, cull_front); return }
	gl_gpu_depth_pass_begin(target, size, cull_front)
}

gpu_depth_pass_end :: proc(restore: Gpu_Render_Target, viewport: [4]i32) {
	if g_gpu_backend == .Vulkan { vk_gpu_depth_pass_end(restore, viewport); return }
	gl_gpu_depth_pass_end(restore, viewport)
}

gpu_device_info :: proc() -> Gpu_Device_Info {
	if g_gpu_backend == .Vulkan { return vk_gpu_device_info() }
	return gl_gpu_device_info()
}

gpu_device_lost :: proc() -> bool {
	if g_gpu_backend == .Vulkan { return vk_gpu_device_lost() }
	return gl_gpu_device_lost()
}

gpu_device_name :: proc() -> string {
	if g_gpu_backend == .Vulkan { return vk_gpu_device_name() }
	return gl_gpu_device_name()
}

gpu_draw_indexed :: proc(index_count: i32, first_index: u32) {
	if g_gpu_backend == .Vulkan { vk_gpu_draw_indexed(index_count, first_index); return }
	gl_gpu_draw_indexed(index_count, first_index)
}

gpu_draw_state_reset :: proc() {
	if g_gpu_backend == .Vulkan { vk_gpu_draw_state_reset(); return }
	gl_gpu_draw_state_reset()
}

gpu_draw_state_set :: proc(state: Gpu_Draw_State) {
	if g_gpu_backend == .Vulkan { vk_gpu_draw_state_set(state); return }
	gl_gpu_draw_state_set(state)
}

gpu_frame_begin :: proc() {
	if g_gpu_backend == .Vulkan { vk_gpu_frame_begin(); return }
	gl_gpu_frame_begin()
}

gpu_frame_end :: proc() {
	if g_gpu_backend == .Vulkan { vk_gpu_frame_end(); return }
	gl_gpu_frame_end()
}

gpu_frame_wait :: proc() {
	if g_gpu_backend == .Vulkan { vk_gpu_frame_wait(); return }
	gl_gpu_frame_wait()
}

gpu_frames_fini :: proc() {
	if g_gpu_backend == .Vulkan { vk_gpu_frames_fini(); return }
	gl_gpu_frames_fini()
}

gpu_frames_finish :: proc() {
	if g_gpu_backend == .Vulkan { vk_gpu_frames_finish(); return }
	gl_gpu_frames_finish()
}

gpu_frames_take :: proc(gpu_ms: ^[dynamic]f64) {
	if g_gpu_backend == .Vulkan { vk_gpu_frames_take(gpu_ms); return }
	gl_gpu_frames_take(gpu_ms)
}

gpu_max_anisotropy :: proc() -> f32 {
	if g_gpu_backend == .Vulkan { return vk_gpu_max_anisotropy() }
	return gl_gpu_max_anisotropy()
}

gpu_max_storage_buffer_size :: proc() -> i64 {
	if g_gpu_backend == .Vulkan { return vk_gpu_max_storage_buffer_size() }
	return gl_gpu_max_storage_buffer_size()
}

gpu_max_texture_size :: proc() -> i32 {
	if g_gpu_backend == .Vulkan { return vk_gpu_max_texture_size() }
	return gl_gpu_max_texture_size()
}

gpu_present :: proc(window: glfw.WindowHandle = nil) {
	if g_gpu_backend == .Vulkan { vk_gpu_present(window); return }
	gl_gpu_present(window)
}

gpu_program_bind :: proc(program: Gpu_Program) {
	if g_gpu_backend == .Vulkan { vk_gpu_program_bind(program); return }
	gl_gpu_program_bind(program)
}

gpu_program_create_basic :: proc(batched, shadow_depth: bool) -> Gpu_Program {
	if g_gpu_backend == .Vulkan { return vk_gpu_program_create_basic(batched, shadow_depth) }
	return gl_gpu_program_create_basic(batched, shadow_depth)
}

gpu_program_create_debug_lines :: proc() -> Gpu_Program {
	if g_gpu_backend == .Vulkan { return vk_gpu_program_create_debug_lines() }
	return gl_gpu_program_create_debug_lines()
}

gpu_program_create_ui :: proc() -> Gpu_Program {
	if g_gpu_backend == .Vulkan { return vk_gpu_program_create_ui() }
	return gl_gpu_program_create_ui()
}

gpu_program_destroy :: proc(program: ^Gpu_Program) {
	if g_gpu_backend == .Vulkan { vk_gpu_program_destroy(program); return }
	gl_gpu_program_destroy(program)
}

gpu_read_color_rgb :: proc(target: Gpu_Render_Target, width, height: i32, pixels: []u8) {
	if g_gpu_backend == .Vulkan { vk_gpu_read_color_rgb(target, width, height, pixels); return }
	gl_gpu_read_color_rgb(target, width, height, pixels)
}

gpu_read_depth :: proc(target: Gpu_Render_Target, width, height: i32, depth: []u32) {
	if g_gpu_backend == .Vulkan { vk_gpu_read_depth(target, width, height, depth); return }
	gl_gpu_read_depth(target, width, height, depth)
}

gpu_render_target_create :: proc(width, height: i32) -> Gpu_Render_Target {
	if g_gpu_backend == .Vulkan { return vk_gpu_render_target_create(width, height) }
	return gl_gpu_render_target_create(width, height)
}

// A multisampled colour + depth target (MSAA: the world and viewmodel pass).
// It cannot be read back or sampled; gpu_resolve averages its colour into a
// single-sample target, which the interface is then drawn into.
gpu_render_target_create_msaa :: proc(width, height, samples: i32) -> Gpu_Render_Target {
	if g_gpu_backend == .Vulkan { return vk_gpu_render_target_create_msaa(width, height, samples) }
	return gl_gpu_render_target_create_msaa(width, height, samples)
}

// Resolves `source`'s (multisampled) colour into `destination` (0: the
// window), both width x height. Depth is not resolved: what is drawn after
// (the interface) does not test depth.
gpu_resolve :: proc(source, destination: Gpu_Render_Target, width, height: i32) {
	if g_gpu_backend == .Vulkan { vk_gpu_resolve(source, destination, width, height); return }
	gl_gpu_resolve(source, destination, width, height)
}

// The highest MSAA sample count (1, 2, 4 or 8) both colour and depth targets
// support.
gpu_max_msaa_samples :: proc() -> i32 {
	if g_gpu_backend == .Vulkan { return vk_gpu_max_msaa_samples() }
	return gl_gpu_max_msaa_samples()
}

gpu_render_target_create_depth :: proc(depth: Gpu_Texture, layer: i32 = -1) -> Gpu_Render_Target {
	if g_gpu_backend == .Vulkan { return vk_gpu_render_target_create_depth(depth, layer) }
	return gl_gpu_render_target_create_depth(depth, layer)
}

gpu_render_target_destroy :: proc(target: ^Gpu_Render_Target) {
	if g_gpu_backend == .Vulkan { vk_gpu_render_target_destroy(target); return }
	gl_gpu_render_target_destroy(target)
}

gpu_sampler_bind :: proc(unit: u32, sampler: Gpu_Sampler) {
	if g_gpu_backend == .Vulkan { vk_gpu_sampler_bind(unit, sampler); return }
	gl_gpu_sampler_bind(unit, sampler)
}

gpu_sampler_create :: proc(desc: Gpu_Sampler_Desc, anisotropy: f32 = 1) -> Gpu_Sampler {
	if g_gpu_backend == .Vulkan { return vk_gpu_sampler_create(desc, anisotropy) }
	return gl_gpu_sampler_create(desc, anisotropy)
}

gpu_sampler_destroy :: proc(sampler: ^Gpu_Sampler) {
	if g_gpu_backend == .Vulkan { vk_gpu_sampler_destroy(sampler); return }
	gl_gpu_sampler_destroy(sampler)
}

gpu_sampler_set_anisotropy :: proc(sampler: Gpu_Sampler, value: f32) {
	if g_gpu_backend == .Vulkan { vk_gpu_sampler_set_anisotropy(sampler, value); return }
	gl_gpu_sampler_set_anisotropy(sampler, value)
}

gpu_scissor :: proc(enabled: bool, rect: [4]i32 = {}) {
	if g_gpu_backend == .Vulkan { vk_gpu_scissor(enabled, rect); return }
	gl_gpu_scissor(enabled, rect)
}

gpu_set_clear_color :: proc(color: [3]f32) {
	if g_gpu_backend == .Vulkan { vk_gpu_set_clear_color(color); return }
	gl_gpu_set_clear_color(color)
}

gpu_set_target :: proc(target: Gpu_Render_Target, width, height: i32) {
	if g_gpu_backend == .Vulkan { vk_gpu_set_target(target, width, height); return }
	gl_gpu_set_target(target, width, height)
}

// How long the last presented frame waited for the display (V-Sync): the
// present-wait pacing on Vulkan, SwapBuffers on OpenGL. VRR capping uses it
// to tell whether frames still reach the refresh rate.
gpu_last_vsync_wait_ms :: proc() -> f64 {
	if g_gpu_backend == .Vulkan { return vk_gpu_last_vsync_wait_ms() }
	return gl_gpu_last_vsync_wait_ms()
}

gpu_set_vsync :: proc(on: bool) {
	if g_gpu_backend == .Vulkan { vk_gpu_set_vsync(on); return }
	gl_gpu_set_vsync(on)
}

gpu_texture_bind :: proc(unit: u32, texture: Gpu_Texture) {
	if g_gpu_backend == .Vulkan { vk_gpu_texture_bind(unit, texture); return }
	gl_gpu_texture_bind(unit, texture)
}

gpu_texture_create :: proc(desc: Gpu_Texture_Desc, pixels: []u8 = nil) -> Gpu_Texture {
	if g_gpu_backend == .Vulkan { return vk_gpu_texture_create(desc, pixels) }
	return gl_gpu_texture_create(desc, pixels)
}

gpu_texture_destroy :: proc(texture: ^Gpu_Texture) {
	if g_gpu_backend == .Vulkan { vk_gpu_texture_destroy(texture); return }
	gl_gpu_texture_destroy(texture)
}

gpu_texture_set_filter :: proc(texture: Gpu_Texture, filter: Gpu_Filter) {
	if g_gpu_backend == .Vulkan { vk_gpu_texture_set_filter(texture, filter); return }
	gl_gpu_texture_set_filter(texture, filter)
}

// Gives an existing 2D texture new contents, size and sampling while keeping
// its handle (live mod reload).
gpu_texture_replace :: proc(texture: Gpu_Texture, desc: Gpu_Texture_Desc, pixels: []u8) -> bool {
	if g_gpu_backend == .Vulkan { return vk_gpu_texture_replace(texture, desc, pixels) }
	return gl_gpu_texture_replace(texture, desc, pixels)
}

// World texture filtering (Settings > Smooth textures).
gpu_sampler_set_filter :: proc(sampler: Gpu_Sampler, filter: Gpu_Filter) {
	if g_gpu_backend == .Vulkan { vk_gpu_sampler_set_filter(sampler, filter); return }
	gl_gpu_sampler_set_filter(sampler, filter)
}

gpu_texture_update :: proc(texture: Gpu_Texture, format: Gpu_Format, x, y, width, height: i32, pixels: []u8) {
	if g_gpu_backend == .Vulkan { vk_gpu_texture_update(texture, format, x, y, width, height, pixels); return }
	gl_gpu_texture_update(texture, format, x, y, width, height, pixels)
}

gpu_transient_bind :: proc(layout: Gpu_Vertex_Layout, vertices: []u8, indices: []u32) -> bool {
	if g_gpu_backend == .Vulkan { return vk_gpu_transient_bind(layout, vertices, indices) }
	return gl_gpu_transient_bind(layout, vertices, indices)
}

gpu_uniform_push :: proc(binding: u32, data: []u8) {
	if g_gpu_backend == .Vulkan { vk_gpu_uniform_push(binding, data); return }
	gl_gpu_uniform_push(binding, data)
}

gpu_uniforms_fini :: proc() {
	if g_gpu_backend == .Vulkan { vk_gpu_uniforms_fini(); return }
	gl_gpu_uniforms_fini()
}

gpu_vertex_input_bind :: proc(input: Gpu_Vertex_Input) {
	if g_gpu_backend == .Vulkan { vk_gpu_vertex_input_bind(input); return }
	gl_gpu_vertex_input_bind(input)
}

gpu_vertex_input_create :: proc(layout: Gpu_Vertex_Layout, vertices, indices: Gpu_Buffer) -> Gpu_Vertex_Input {
	if g_gpu_backend == .Vulkan { return vk_gpu_vertex_input_create(layout, vertices, indices) }
	return gl_gpu_vertex_input_create(layout, vertices, indices)
}

gpu_vertex_input_destroy :: proc(input: ^Gpu_Vertex_Input) {
	if g_gpu_backend == .Vulkan { vk_gpu_vertex_input_destroy(input); return }
	gl_gpu_vertex_input_destroy(input)
}

gpu_wait_idle :: proc() {
	if g_gpu_backend == .Vulkan { vk_gpu_wait_idle(); return }
	gl_gpu_wait_idle()
}

gpu_window_target :: proc() -> Gpu_Render_Target {
	if g_gpu_backend == .Vulkan { return vk_gpu_window_target() }
	return gl_gpu_window_target()
}
