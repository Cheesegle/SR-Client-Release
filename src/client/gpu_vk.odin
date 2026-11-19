package main

// Vulkan 1.3 backend for the gpu_* interface (see gpu.odin: g_gpu_backend
// picks it at startup). The SPIR-V it embeds comes from tools/build-spirv.ps1.
//
// Conventions that keep every caller identical to the GL backend:
// - Images are rendered and stored in GL's orientation: no viewport flip, so
//   framebuffer row 0 is GL's bottom row. Texture uploads, shadow-map UVs,
//   gl_FragCoord, derivatives and readbacks all match GL, and frontFace is
//   CLOCKWISE (Vulkan measures winding with y down). Presenting to a window
//   will need one vertical flip at the end.
// - basic.vert maps GL clip z to Vulkan's 0..w, so stored depths equal GL's.
// - Binding state (program, textures, buffers, uniform blocks) behaves like GL
//   state: calls record what the next draw needs, and gpu_draw_indexed applies
//   whatever changed. Render passes start lazily at the first draw and clears
//   become load ops (or vkCmdClearAttachments inside a pass).
// - Outside gpu_frame_begin/end (map loads, readbacks) commands still work:
//   recording starts implicitly and is submitted when needed.
// - Nothing waits for the GPU on the frame path: uploads are recorded into
//   the frame's command buffer from a staging ring (vk_upload_begin), and
//   destroyed objects are freed once the last frame that may use them has
//   finished (vk_retire). Only resizes, readbacks and shutdown wait;
//   g_vk_stats counts every wait.

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import glfw "vendor:glfw"
import vk "vendor:vulkan"


@(private = "file") SPIRV_BASIC_VERT :: #load("spirv/basic.vert.spv")
@(private = "file") SPIRV_BASIC_FRAG :: #load("spirv/basic.frag.spv")
@(private = "file") SPIRV_BATCHED_VERT :: #load("spirv/basic_batched.vert.spv")
@(private = "file") SPIRV_BATCHED_FRAG :: #load("spirv/basic_batched.frag.spv")
@(private = "file") SPIRV_SHADOW_VERT :: #load("spirv/basic_shadow.vert.spv")
@(private = "file") SPIRV_SHADOW_FRAG :: #load("spirv/basic_shadow.frag.spv")
@(private = "file") SPIRV_SHADOW_BATCHED_VERT :: #load("spirv/basic_shadow_batched.vert.spv")
@(private = "file") SPIRV_SHADOW_BATCHED_FRAG :: #load("spirv/basic_shadow_batched.frag.spv")
@(private = "file") SPIRV_UI_VERT :: #load("spirv/ui.vert.spv")
@(private = "file") SPIRV_UI_FRAG :: #load("spirv/ui.frag.spv")
@(private = "file") SPIRV_DEBUG_LINE_VERT :: #load("spirv/debug_line.vert.spv")
@(private = "file") SPIRV_DEBUG_LINE_FRAG :: #load("spirv/debug_line.frag.spv")

VK_COLOR_FORMAT :: vk.Format.R8G8B8A8_UNORM
VK_DEPTH_FORMAT :: vk.Format.D32_SFLOAT
VK_UNIFORM_RING_PER_FRAME :: 16 << 20
VK_TRANSIENT_RING_PER_FRAME :: 16 << 20 // gpu_transient_bind vertices and indices
VK_STAGING_RING_PER_FRAME :: 8 << 20 // upload sources; bigger uploads get their own buffer
VK_FRAME_SETS :: 4096
VK_TEXTURE_SETS :: 8192
VK_MAX_LAYERS :: 4

// ---------------------------------------------------------------------------
// Handle tables: handle = index + 1, so 0 stays "none".

@(private = "file")
Vk_Table :: struct($T: typeid) {
	items: [dynamic]T,
	live:  [dynamic]bool,
	free:  [dynamic]u32,
}

@(private = "file")
vk_table_add :: proc(table: ^Vk_Table($T), item: T) -> u32 {
	if len(table.free) > 0 {
		index := pop(&table.free)
		table.items[index] = item
		table.live[index] = true
		return index + 1
	}
	append(&table.items, item)
	append(&table.live, true)
	return u32(len(table.items))
}

@(private = "file")
vk_table_get :: proc(table: ^Vk_Table($T), handle: u32) -> ^T {
	if handle == 0 || int(handle) > len(table.items) || !table.live[handle - 1] { return nil }
	return &table.items[handle - 1]
}

@(private = "file")
vk_table_remove :: proc(table: ^Vk_Table($T), handle: u32) {
	if handle == 0 || int(handle) > len(table.items) || !table.live[handle - 1] { return }
	table.live[handle - 1] = false
	table.items[handle - 1] = {}
	append(&table.free, handle - 1)
}

@(private = "file")
vk_table_destroy :: proc(table: ^Vk_Table($T)) {
	delete(table.items)
	delete(table.live)
	delete(table.free)
}

// ---------------------------------------------------------------------------
// Resources.

// Device memory comes from 64 MB blocks per memory type (vk_alloc), so
// creating a resource is not a driver allocation; big resources get their own.
VK_BLOCK_SIZE :: 64 << 20

@(private = "file")
Vk_Block :: struct {
	memory: vk.DeviceMemory,
	type:   u32,
	images: bool, // images and buffers never share a block (bufferImageGranularity)
	mapped: [^]u8,
	free:   [dynamic][2]int, // offset, size; sorted, coalesced
	used:   int,
}

@(private = "file")
Vk_Allocation :: struct {
	memory: vk.DeviceMemory,
	offset: int,
	size:   int,
	block:  ^Vk_Block, // nil: a dedicated allocation
	mapped: [^]u8,
}

@(private = "file")
Vk_Buffer :: struct {
	buffer: vk.Buffer,
	memory: Vk_Allocation,
	size:   int,
	mapped: [^]u8,
}

@(private = "file")
Vk_Image :: struct {
	image:   vk.Image,
	memory:  Vk_Allocation,
	view:    vk.ImageView, // every layer and mip
	format:  vk.Format,
	aspect:  vk.ImageAspectFlags,
	width:   u32,
	height:  u32,
	layers:  u32,
	mips:    u32,
	array:   bool,
	layouts: [VK_MAX_LAYERS]vk.ImageLayout,
}

@(private = "file")
Vk_Texture :: struct {
	image:            Vk_Image,
	format:           Gpu_Format,
	desc:             Gpu_Sampler_Desc,
	sampler:          vk.Sampler, // shared, from the sampler cache
	set:              vk.DescriptorSet, // set 1 with its own sampler (colour textures)
	override:         Gpu_Sampler,
	override_version: u32,
	override_set:     vk.DescriptorSet,
}

@(private = "file")
Vk_Sampler_Object :: struct {
	desc:       Gpu_Sampler_Desc,
	anisotropy: f32,
	sampler:    vk.Sampler,
	version:    u32,
}

@(private = "file")
Vk_Target :: struct {
	depth_only: bool,
	// Colour targets own their images.
	color:      Vk_Image,
	depth:      Vk_Image,
	// Depth-only targets render into one layer of a texture.
	texture:    Gpu_Texture,
	layer:      u32,
	layer_view: vk.ImageView,
	width:      u32,
	height:     u32,
	samples:    u32, // colour targets: 1, or 2/4/8 for MSAA (never read back or sampled)
}

@(private = "file")
Vk_Program :: struct {
	vert, frag: vk.ShaderModule,
	layout:     Gpu_Vertex_Layout,
	shadow:     bool, // a shadow-map depth variant (drawn in depth passes)
}

// Compiled pipelines survive restarts here (relative to the working folder,
// like client-settings.json); the driver ignores data from another GPU or
// driver version.
VK_PIPELINE_CACHE_PATH :: "vk-pipeline-cache.bin"

@(private = "file")
Vk_Input :: struct {
	layout:   Gpu_Vertex_Layout,
	vertices: Gpu_Buffer,
	indices:  Gpu_Buffer,
}

@(private = "file")
// Cull mode and the depth test, write and compare op are dynamic state
// (core in Vulkan 1.3), so a program needs one pipeline per blend /
// wireframe / pass kind instead of one per draw-state combination.
Vk_Pipeline_Key :: struct {
	program:    Gpu_Program,
	blend:      bool,
	wireframe:  bool,
	depth_only: bool,
	samples:    u8, // the pass's sample count (MSAA); 1 for depth passes
}

// The dynamic state last set in the frame's command buffer.
@(private = "file")
Vk_Dynamic_State :: struct {
	valid:       bool,
	cull_front:  bool,
	depth_test:  Gpu_Depth_Test,
	depth_write: bool,
}

@(private = "file")
Vk_Sampler_Key :: struct {
	desc:       Gpu_Sampler_Desc,
	anisotropy: f32,
}

// An object destroyed while frames that may use it are in flight; freed once
// the frame with `serial` has finished (only the set fields are freed).
@(private = "file")
Vk_Retired :: struct {
	serial:   u64,
	buffer:   Vk_Buffer,
	image:    Vk_Image,
	view:     vk.ImageView,
	set:      vk.DescriptorSet, // from texture_pool
	pipeline: vk.Pipeline,
	module:   vk.ShaderModule,
}

// GPU waits, for checking that gameplay never stalls (printed at shutdown).
g_vk_stats: struct {
	idle_waits:   int, // vkDeviceWaitIdle: resizes, shutdown
	sync_uploads: int, // uploads that could not join a frame (inside a shadow pass)
	readbacks:    int, // gpu_read_* (tests, benchmark, startup self-test)
	draw_time_pipelines: int, // pipelines compiled at a draw (not precreated)
	present_waits:    int, // frames that waited for an earlier present (vsync on)
	present_wait_ms:  f64, // total time spent in those waits
	set0_binds:       int, // descriptor set 0 binds (per pass, not per draw)
	barriers:         int, // image layout barriers recorded (vk_transition)
	barriers_skipped: int, // transitions that needed none (already in a read-only layout)
	resolves:         int, // MSAA resolves (gpu_resolve)
}

@(private = "file")
Vk_Frame :: struct {
	cmd:       vk.CommandBuffer,
	fence:     vk.Fence,
	pool:      vk.DescriptorPool,
	queries:   vk.QueryPool,
	acquired:  vk.Semaphore, // signalled by vkAcquireNextImageKHR for this frame
	serial:    u64,          // which recording this slot holds
	submitted: bool,
	presenting: bool,        // handed to the present thread, which submits it
	// Low-latency pacing (vk_gpu_frame_ready_delay): when the frame's recording
	// was meant to start and when it reached the queue, time.Tick nanoseconds.
	ll_start_ns: f64,
	submit_ns:   f64,
	timed:     bool,
	marked:    bit_set[Gpu_Pass], // gpu_pass_mark timestamps written (queries 2 + pass)
}

// Timestamp queries per frame: begin, end, then one per Gpu_Pass.
VK_FRAME_QUERIES :: 2 + len(Gpu_Pass)

// The window: a surface, its swapchain, and the offscreen target the frame is
// drawn into (gpu_window_target). gpu_present blits that target, flipped
// vertically (it is stored in GL's bottom-up orientation), to the image.
@(private = "file")
Vk_Swapchain :: struct {
	window:      glfw.WindowHandle,
	surface:     vk.SurfaceKHR,
	swapchain:   vk.SwapchainKHR,
	format:      vk.Format,
	extent:      vk.Extent2D,
	images:      [dynamic]vk.Image,
	// Per image: presentation waits on it, so it is reused only once the
	// image comes back from vkAcquireNextImageKHR.
	rendered:    [dynamic]vk.Semaphore,
	vsync:       bool,
	dirty:       bool, // recreate before the next frame
	target:      Gpu_Render_Target,
	// VK_KHR_present_id + VK_KHR_present_wait: every present carries an
	// increasing id; with vsync on, a frame starts only once the frame before
	// the last one is on screen, so at most one frame waits for the display
	// (FIFO would otherwise queue several, each a refresh of input latency).
	present_wait: bool,
	present_id:   u64, // id of the last present
	first_id:     u64, // first id presented on the current swapchain
	last_wait_ms: f64, // vk_present_wait_pace's wait before the current frame
}

@(private = "file")
Vk_State :: struct {
	ready:            bool,
	instance:         vk.Instance,
	messenger:        vk.DebugUtilsMessengerEXT,
	physical:         vk.PhysicalDevice,
	device:           vk.Device,
	queue:            vk.Queue,
	queue_family:     u32,
	props:            vk.PhysicalDeviceProperties,
	memory:           vk.PhysicalDeviceMemoryProperties,
	anisotropy:       bool,
	wireframe:        bool,
	device_name:      string,
	vendor_name:      string,
	version_text:     string, // "Vulkan 1.4.357, NVIDIA 581.57"

	command_pool:     vk.CommandPool,
	upload_cmd:       vk.CommandBuffer,
	upload_fence:     vk.Fence,
	frames:           [GPU_FRAMES_IN_FLIGHT]Vk_Frame,
	slot:             int,
	recording:        bool,
	completed:        [dynamic]f64,

	set0_layout:      vk.DescriptorSetLayout,
	set1_layout:      vk.DescriptorSetLayout,
	pipeline_layout:  vk.PipelineLayout,
	texture_pool:     vk.DescriptorPool,
	pipeline_cache:   vk.PipelineCache,
	pipelines:        map[Vk_Pipeline_Key]vk.Pipeline,
	samplers:         map[Vk_Sampler_Key]vk.Sampler,
	retired:          [dynamic]Vk_Retired,
	blocks:           [dynamic]^Vk_Block,
	serial:           u64, // of the recording in progress, or the last one
	completed_serial: u64, // every recording up to this one has finished
	staging:          Vk_Buffer, // per-frame upload source regions
	staging_cursor:   int,

	ring:             Vk_Buffer, // per-frame uniform regions
	ring_cursor:      int,
	transient:        Vk_Buffer, // per-frame vertex and index regions
	transient_cursor: int,
	ring_align:       int,
	dummy_storage:    Vk_Buffer,
	readback:         Vk_Buffer,
	placeholder_array: Gpu_Texture,
	placeholder_2d:   Gpu_Texture,

	buffers:          Vk_Table(Vk_Buffer),
	textures:         Vk_Table(Vk_Texture),
	sampler_objects:  Vk_Table(Vk_Sampler_Object),
	targets:          Vk_Table(Vk_Target),
	programs:         Vk_Table(Vk_Program),
	inputs:           Vk_Table(Vk_Input),

	// What the next draw needs (GL-like binding state).
	target:           Gpu_Render_Target,
	viewport:         [2]i32,
	clear_color:      [4]f32,
	pending_color:    bool,
	pending_depth:    bool,
	program:          Gpu_Program,
	draw_state:       Gpu_Draw_State,
	input:            Gpu_Vertex_Input,
	color_texture:    Gpu_Texture,
	color_override:   Gpu_Sampler,
	shadow_texture:   Gpu_Texture,
	player_texture:   Gpu_Texture,
	objects:          Gpu_Buffer,
	pass_offset:      u32,
	draw_vec4:        u32, // the draw block's index in the frame's ring, in vec4s
	pushed_draw_vec4: u32, // the value the command buffer has (max(u32): none yet)
	// gpu_transient_bind's data, in place of `input` while active.
	transient_active: bool,
	transient_offsets: [2]vk.DeviceSize, // vertices, indices
	scissor_on:       bool,
	scissor_rect:     [4]i32, // GL convention: x, y from the bottom row, width, height

	// What the current command buffer has bound.
	in_pass:          bool,
	pass_depth_only:  bool,
	pass_samples:     u32, // the colour pass's sample count
	msaa_samples:     i32, // sample count of the last MSAA target (its pipelines are precompiled)
	pass_cull_front:  bool,
	depth_pass_target: Gpu_Render_Target,
	bound_pipeline:   vk.Pipeline,
	dyn_state:        Vk_Dynamic_State,
	set0:             vk.DescriptorSet,
	set0_dirty:       bool,
	bound_set0:       vk.DescriptorSet,
	bound_offsets:    [2]u32,
	bound_set1:       vk.DescriptorSet,
	bound_input:      Gpu_Vertex_Input,
	bound_transient:  [2]vk.DeviceSize,
	bound_scissor:    vk.Rect2D,
	warned_no_target: bool,

	present:          Vk_Swapchain,
	// What target 0 means (GL's "the window"): the window target, or a test's.
	default_target:   Gpu_Render_Target,
}

@(private = "file")
g_vk: Vk_State

g_vk_validation_errors: int

// Set before gpu_vk_init: --gpu-debug turns validation on (as does
// SR_VK_VALIDATION=1) and logs its messages to GPU_DEBUG_LOG_PATH.
g_vk_debug: struct {
	wanted:     bool,
	validation: bool, // validation layers are loaded
	log:        ^os.File,
	lock:       sync.Mutex,
}
GPU_DEBUG_LOG_PATH :: "logs/gpu-debug.log"

// VK_ERROR_DEVICE_LOST was returned; the main loop reports it as a GPU reset
// (gpu_reset.odin) and closes.
@(private = "file")
g_vk_device_lost: bool

vk_gpu_device_lost :: proc() -> bool { return sync.atomic_load(&g_vk_device_lost) }

// ---------------------------------------------------------------------------
// Latency probe: SR_LATENCY_PROBE=<seconds> (off otherwise). For every window
// frame it measures the time from the start of its recording (right before the
// game reads input) to the GPU finishing it (the end timestamp written after
// the present blit, moved to the CPU clock with VK_EXT_calibrated_timestamps),
// and the time between frame starts. It waits SR_LATENCY_PROBE_WARMUP seconds
// (default 10) after the first frame, records, prints a summary and closes the
// window.
@(private = "file")
Vk_Latency_Probe :: struct {
	seconds, warmup: f64,
	enabled:         bool, // asked for, and calibrated timestamps are available
	first:           time.Tick,
	recording:       bool,
	finished:        bool,
	start:           [GPU_FRAMES_IN_FLIGHT]time.Tick,
	counted:         [GPU_FRAMES_IN_FLIGHT]bool,
	prev_start:      time.Tick,
	latency_ms:      [dynamic]f64,
	interval_ms:     [dynamic]f64,
	gpu_ms:          [dynamic]f64,
	input_ns:        [GPU_FRAMES_IN_FLIGHT]i64, // arrival of the oldest mouse report the frame read (0: none)
	mouse_ms:        [dynamic]f64,              // mouse report arrival -> GPU done, frames that read mouse input
	collect_ms:      f64, // game thread: waiting for the slot's frame (fence, present thread)
	present_ms:      f64, // game thread: in gpu_present
	delay_ms, cpu_est_ms, gpu_est_ms: f64, // low-latency pacing, summed per frame
}

@(private = "file")
g_vk_probe: Vk_Latency_Probe

// GPU timestamps on the CPU clock (VK_KHR/EXT_calibrated_timestamps): the
// latency probe and low-latency pacing (vk_gpu_frame_ready_delay) use them.
@(private = "file")
Vk_Clock :: struct {
	available:  bool,
	khr:        bool, // VK_KHR_calibrated_timestamps rather than EXT
	cal_gpu:    u64,  // device ticks at cal_cpu_ns
	cal_cpu_ns: f64,  // time.Tick nanoseconds
	cal_tick:   time.Tick,
}

@(private = "file")
g_vk_clock: Vk_Clock

// Before device creation: adds the calibrated timestamps extension when the
// device has it.
@(private = "file")
vk_clock_setup :: proc(physical: vk.PhysicalDevice, extensions: ^[dynamic]cstring) {
	count: u32
	vk.EnumerateDeviceExtensionProperties(physical, nil, &count, nil)
	props := make([]vk.ExtensionProperties, count, context.temp_allocator)
	vk.EnumerateDeviceExtensionProperties(physical, nil, &count, raw_data(props))
	has_ext, has_khr := false, false
	for &e in props {
		name := string(cstring(&e.extensionName[0]))
		if name == vk.EXT_CALIBRATED_TIMESTAMPS_EXTENSION_NAME { has_ext = true }
		if name == vk.KHR_CALIBRATED_TIMESTAMPS_EXTENSION_NAME { has_khr = true }
	}
	switch {
	case has_khr: append(extensions, vk.KHR_CALIBRATED_TIMESTAMPS_EXTENSION_NAME); g_vk_clock.khr = true
	case has_ext: append(extensions, vk.EXT_CALIBRATED_TIMESTAMPS_EXTENSION_NAME)
	case: return
	}
	g_vk_clock.available = true
}

@(private = "file")
vk_clock_calibrate :: proc() -> bool {
	c := &g_vk_clock
	domain: vk.TimeDomainKHR = ODIN_OS == .Windows ? .QUERY_PERFORMANCE_COUNTER : .CLOCK_MONOTONIC
	infos := [2]vk.CalibratedTimestampInfoKHR{
		{sType = .CALIBRATED_TIMESTAMP_INFO_KHR, timeDomain = .DEVICE},
		{sType = .CALIBRATED_TIMESTAMP_INFO_KHR, timeDomain = domain},
	}
	stamps: [2]u64
	deviation: u64
	result := c.khr ? vk.GetCalibratedTimestampsKHR(g_vk.device, 2, &infos[0], &stamps[0], &deviation) : vk.GetCalibratedTimestampsEXT(g_vk.device, 2, &infos[0], &stamps[0], &deviation)
	if result != .SUCCESS { c.available = false; return false }
	c.cal_gpu = stamps[0]
	c.cal_cpu_ns = f64(stamps[1]) * 1e9 / f64(cpu_clock_frequency())
	c.cal_tick = time.tick_now()
	return true
}

// A GPU timestamp as time.Tick nanoseconds; ok false without calibration.
@(private = "file")
vk_clock_gpu_to_cpu_ns :: proc(stamp: u64) -> (ns: f64, ok: bool) {
	c := &g_vk_clock
	if !c.available { return }
	if c.cal_tick == {} || time.duration_seconds(time.tick_since(c.cal_tick)) > 0.5 { // follow clock drift
		if !vk_clock_calibrate() { return }
	}
	return c.cal_cpu_ns + f64(i64(stamp - c.cal_gpu)) * f64(g_vk.props.limits.timestampPeriod), true
}

@(private = "file")
vk_tick_ns :: proc(t: time.Tick) -> f64 { return f64(time.tick_diff(time.Tick{}, t)) }

@(private = "file")
vk_probe_setup :: proc() {
	p := &g_vk_probe
	seconds, _ := strconv.parse_f64(os.get_env("SR_LATENCY_PROBE", context.temp_allocator))
	if seconds <= 0 { return }
	warmup, warmup_ok := strconv.parse_f64(os.get_env("SR_LATENCY_PROBE_WARMUP", context.temp_allocator))
	p.seconds, p.warmup = seconds, warmup_ok ? warmup : 10
	if !g_vk_clock.available { fmt.eprintln("[Probe] calibrated timestamps unavailable; latency probe off"); return }
	p.enabled = true
	fmt.printfln("[Probe] latency probe: %.0f s after %.0f s warm-up, present thread %s, low latency %s", p.seconds, p.warmup,
		os.get_env("SR_VK_PRESENT_THREAD", context.temp_allocator) == "0" ? "off" : os.get_env("SR_VK_PRESENT_THREAD", context.temp_allocator) == "1" ? "always" : os.get_env("SR_VK_PRESENT_SPIN", context.temp_allocator) == "1" ? "always, spinning" : "adaptive",
		os.get_env("SR_LOW_LATENCY", context.temp_allocator) == "0" ? "off" : fmt.tprintf("on, margin %.0f us", g_vk_ll_margin_ns / 1000))
}

// A window frame starts recording (its slot has been collected).
@(private = "file")
vk_probe_frame_start :: proc(slot: int, collect_ms: f64) {
	p := &g_vk_probe
	if !p.enabled || p.finished { return }
	now := time.tick_now()
	if p.first == {} { p.first = now }
	elapsed := time.duration_seconds(time.tick_diff(p.first, now))
	if !p.recording && elapsed >= p.warmup { p.recording = true; p.prev_start = now; p.counted = {}; phase_timing_start(); input_probe_set(true) }
	p.start[slot] = now
	p.counted[slot] = false
	p.input_ns[slot] = 0
	if !p.recording { return }
	if elapsed >= p.warmup + p.seconds { vk_probe_finish(); return }
	p.counted[slot] = true
	p.collect_ms += collect_ms
	if p.prev_start != now { append(&p.interval_ms, time.duration_milliseconds(time.tick_diff(p.prev_start, now))) }
	p.prev_start = now
}

// The frame in this slot finished; `end` is its last GPU timestamp.
@(private = "file")
vk_probe_frame_done :: proc(slot: int, begin, end: u64) {
	p := &g_vk_probe
	if !p.enabled || !p.counted[slot] { return }
	p.counted[slot] = false
	append(&p.gpu_ms, f64(end - begin) * f64(g_vk.props.limits.timestampPeriod) / 1e6)
	end_ns, ok := vk_clock_gpu_to_cpu_ns(end)
	if !ok { return }
	append(&p.latency_ms, (end_ns - vk_tick_ns(p.start[slot])) / 1e6)
	if p.input_ns[slot] > 0 { append(&p.mouse_ms, (end_ns - f64(p.input_ns[slot])) / 1e6) }
}

// The frame being recorded read mouse input that first arrived at `arrival_ns`
// (input_probe_take); 0 does nothing.
gpu_probe_note_input :: proc(arrival_ns: i64) {
	if arrival_ns == 0 || g_gpu_backend != .Vulkan { return }
	p := &g_vk_probe
	if !p.recording || !g_vk.recording { return }
	if p.input_ns[g_vk.slot] == 0 { p.input_ns[g_vk.slot] = arrival_ns }
}

@(private = "file")
vk_probe_finish :: proc() {
	p := &g_vk_probe
	p.finished = true
	input_probe_set(false)
	stats :: proc(values: []f64) -> (avg, p50, p95, p99, worst: f64) {
		if len(values) == 0 { return }
		sorted := make([]f64, len(values), context.temp_allocator)
		copy(sorted, values)
		slice.sort(sorted) // a 30 s run at thousands of FPS is ~200k values
		for v in sorted { avg += v }
		avg /= f64(len(sorted))
		at :: proc(s: []f64, q: f64) -> f64 { return s[min(len(s) - 1, int(q * f64(len(s))))] }
		return avg, at(sorted, 0.5), at(sorted, 0.95), at(sorted, 0.99), sorted[len(sorted) - 1]
	}
	i_avg, i_p50, i_p95, i_p99, i_max := stats(p.interval_ms[:])
	l_avg, l_p50, l_p95, l_p99, l_max := stats(p.latency_ms[:])
	fmt.printfln("[Probe] present thread %s: %d frames, %.1f FPS", g_vk_present_thread.running ? "on" : "off", len(p.interval_ms), i_avg > 0 ? 1000 / i_avg : 0)
	fmt.printfln("[Probe] frame time ms   avg %.3f  p50 %.3f  p95 %.3f  p99 %.3f  max %.3f", i_avg, i_p50, i_p95, i_p99, i_max)
	fmt.printfln("[Probe] start->GPU done avg %.3f  p50 %.3f  p95 %.3f  p99 %.3f  max %.3f", l_avg, l_p50, l_p95, l_p99, l_max)
	if len(p.mouse_ms) > 0 {
		m_avg, m_p50, m_p95, m_p99, m_max := stats(p.mouse_ms[:])
		fmt.printfln("[Probe] mouse->GPU done avg %.3f  p50 %.3f  p95 %.3f  p99 %.3f  max %.3f (%d frames with mouse input)", m_avg, m_p50, m_p95, m_p99, m_max, len(p.mouse_ms))
	} else {
		fmt.println("[Probe] mouse->GPU done: no mouse input while recording")
	}
	g_avg, g_p50, _, g_p99, _ := stats(p.gpu_ms[:])
	frames := f64(max(1, len(p.interval_ms)))
	fmt.printfln("[Probe] GPU per frame   avg %.3f  p50 %.3f  p99 %.3f; game thread per frame: slot wait %.3f, gpu_present %.3f", g_avg, g_p50, g_p99, p.collect_ms / frames, p.present_ms / frames)
	fmt.printfln("[Probe] presented on the game thread %d, on the present thread %d (whole run)", g_vk_present_mode.inline_frames, g_vk_present_mode.thread_frames)
	fmt.printfln("[Probe] low latency per frame: delay %.3f, CPU estimate %.3f, GPU estimate %.3f", p.delay_ms / frames, p.cpu_est_ms / frames, p.gpu_est_ms / frames)
	fmt.printfln("[Probe] CPU per frame by phase (ms): %s", phase_timing_report(len(p.interval_ms)))
	if g_vk.present.window != nil { glfw.SetWindowShouldClose(g_vk.present.window, true) }
}

// ---------------------------------------------------------------------------
// Low-latency frame start (SR_LOW_LATENCY=0 turns it off).
//
// With two frames in flight a GPU-bound game reads input for a frame while the
// GPU still has the whole previous frame to draw: input waits about two GPU
// frames to be drawn. Instead, the next frame starts (and reads input) as late
// as it can while still reaching the queue just before the GPU finishes the
// frame in flight, so the GPU never idles and the frame rate holds. The finish
// is predicted from the previous frame's GPU end timestamp (on the CPU clock,
// Vk_Clock) and recent GPU and CPU frame times; the estimates lean early (the
// fastest recent GPU frame, the slowest recent CPU frame, plus a margin), so a
// misprediction costs a little latency rather than frame rate. CPU-bound
// frames, frame caps and V-Sync (present-wait pacing) see no delay.
@(private = "file")
VK_LL_GPU_SAMPLES :: 8
@(private = "file")
VK_LL_CPU_SAMPLES :: 16

@(private = "file")
Vk_Low_Latency :: struct {
	enabled:         bool,
	gpu_ns:          [VK_LL_GPU_SAMPLES]f64, // GPU time of recent frames
	cpu_ns:          [VK_LL_CPU_SAMPLES]f64, // recent frames' start to submit
	gpu_n, cpu_n:    int,
	last_end_ns:     f64, // GPU end of the newest finished frame
	last_end_serial: u64,
}

@(private = "file")
g_vk_ll: Vk_Low_Latency

// How early (besides 5% of a GPU frame) the next frame aims to reach the GPU
// before the one in flight finishes. 0.1 ms is more than a whole frame's GPU
// time at thousands of FPS, so the delay rarely applies there; SR_LL_MARGIN_US
// overrides it to test smaller margins.
VK_LL_MARGIN_NS :: 100_000.0
@(private = "file")
g_vk_ll_margin_ns: f64 = VK_LL_MARGIN_NS

// A window frame finished on the GPU (`begin`, `end`: its timestamps).
@(private = "file")
vk_ll_frame_done :: proc(frame: ^Vk_Frame, begin, end: u64) {
	ll := &g_vk_ll
	defer frame.ll_start_ns, frame.submit_ns = 0, 0
	if !ll.enabled { return }
	end_ns, ok := vk_clock_gpu_to_cpu_ns(end)
	if !ok { return }
	if frame.serial > ll.last_end_serial { ll.last_end_ns, ll.last_end_serial = end_ns, frame.serial }
	ll.gpu_ns[ll.gpu_n % VK_LL_GPU_SAMPLES] = f64(end - begin) * f64(g_vk.props.limits.timestampPeriod)
	ll.gpu_n += 1
	if frame.ll_start_ns > 0 && frame.submit_ns > frame.ll_start_ns {
		ll.cpu_ns[ll.cpu_n % VK_LL_CPU_SAMPLES] = frame.submit_ns - frame.ll_start_ns
		ll.cpu_n += 1
	}
}

// Game thread, between frames, before input is read: waits until the next
// frame's slot is free and returns how much longer (seconds) the next frame
// should wait before it starts (0: start now).
vk_gpu_frame_ready_delay :: proc() -> f64 {
	sc := &g_vk.present
	if sc.window == nil || g_vk.recording { return 0 }
	vk_collect(g_vk.slot) // the frame before last; the next frame records into its slot
	delay := vk_ll_delay()
	// The game thread's slack this frame: everything since the frame ended
	// (frame cap, waiting for the GPU) plus the delay. vk_present_use_thread
	// decides from it where to present.
	pm := &g_vk_present_mode
	if pm.frame_end != {} { pm.slack_ns = f64(time.tick_diff(pm.frame_end, time.tick_now())) + delay * 1e9 }
	return delay
}

@(private = "file")
vk_ll_delay :: proc() -> f64 {
	sc := &g_vk.present
	now := vk_tick_ns(time.tick_now())
	next := &g_vk.frames[g_vk.slot]
	next.ll_start_ns = now
	ll := &g_vk_ll
	if !ll.enabled || sc.vsync || ll.gpu_n < VK_LL_GPU_SAMPLES || ll.cpu_n < VK_LL_CPU_SAMPLES { return 0 }
	// The newest frame: in flight, its predecessor (last_end_serial) finished.
	newest := &g_vk.frames[(g_vk.slot + GPU_FRAMES_IN_FLIGHT - 1) % GPU_FRAMES_IN_FLIGHT]
	if !newest.submitted || ll.last_end_serial + 1 != newest.serial { return 0 }
	submit_ns := now // not on the queue yet: it will be within microseconds
	if newest.presenting {
		pt := &g_vk_present_thread
		sync.mutex_lock(&pt.lock)
		if pt.submitted >= newest.serial { submit_ns = newest.submit_ns }
		sync.mutex_unlock(&pt.lock)
	} else if newest.submit_ns > 0 {
		submit_ns = newest.submit_ns
	}
	gpu := max(f64)
	for v in ll.gpu_ns { gpu = min(gpu, v) }
	cpu, slowest: f64 // the second slowest: one hitch does not hold latency up for 16 frames
	for v in ll.cpu_ns {
		if v > slowest { cpu, slowest = slowest, v } else if v > cpu { cpu = v }
	}
	margin := g_vk_ll_margin_ns + 0.05 * gpu // see VK_LL_MARGIN_NS, + 5% of a GPU frame
	finish := max(ll.last_end_ns, submit_ns) + gpu
	start := finish - margin - cpu
	if start <= now { return 0 }
	start = min(start, now + gpu) // never more than a frame
	next.ll_start_ns = start
	if g_vk_probe.recording {
		g_vk_probe.delay_ms += (start - now) / 1e6
		g_vk_probe.cpu_est_ms += cpu / 1e6
		g_vk_probe.gpu_est_ms += gpu / 1e6
	}
	return (start - now) / 1e9
}

// Where a window frame is presented. The present thread takes acquire, blit,
// submit and present (0.1-0.2 ms on the drivers measured) off the game thread,
// which raises the frame rate only while the game thread is the bottleneck;
// the hand-over itself adds a thread wake-up before the frame reaches the
// queue (it never shortens input-to-GPU latency). So frames are presented on
// the game thread while it has slack (it waits for the GPU, the low-latency
// delay or V-Sync anyway) and handed to the present thread only while it has
// none. The decision follows the average slack; after a switch it holds for
// 64 frames while the average settles in the new mode.
@(private = "file")
Vk_Present_Mode :: struct {
	inline:         bool,
	forced:         bool, // SR_VK_PRESENT_THREAD=1: every frame on the present thread
	spin:           bool, // SR_VK_PRESENT_SPIN=1: the present thread spins for the next frame and takes every frame (tested: more FPS, more delay)
	hold:           int, // frames before the next switch may happen
	slack_ns:       f64, // set by vk_gpu_frame_ready_delay
	slack_avg_ns:   f64,
	frame_end:      time.Tick, // the game thread finished the newest frame
	inline_cost_ns: f64, // the game thread's time presenting inline (average)
	last_inline:    bool, // the newest frame was presented on the game thread
	inline_frames:  int,
	thread_frames:  int,
}

VK_PRESENT_SPIN_NS :: 1_000_000

@(private = "file")
g_vk_present_mode := Vk_Present_Mode{inline = true, hold = 64, inline_cost_ns = 150_000}

@(private = "file")
vk_present_use_thread :: proc() -> bool {
	pt := &g_vk_present_thread
	if !pt.running { return false }
	pm := &g_vk_present_mode
	// A spinning present thread takes a frame within a microsecond, so handing
	// it over costs no latency and the game thread is free sooner.
	if pm.forced || pm.spin { return true }
	slack := pm.slack_ns + g_vk.present.last_wait_ms * 1e6
	pm.slack_avg_ns += (slack - pm.slack_avg_ns) / 16
	// Inline wins whenever the game thread has room for most of the present:
	// the frame then reaches the queue without a thread wake-up.
	if pm.hold > 0 {
		pm.hold -= 1
	} else if pm.inline ? pm.slack_avg_ns < 10_000 : pm.slack_avg_ns > 0.75 * pm.inline_cost_ns + 10_000 {
		pm.inline, pm.hold = !pm.inline, 64
	}
	if !pm.inline { return true }
	// Presenting here needs the thread idle: frames reach the swapchain in order.
	sync.mutex_lock(&pt.lock)
	idle := !pt.has_job && !pt.busy
	sync.mutex_unlock(&pt.lock)
	return !idle
}

// Every vkQueueSubmit, vkQueuePresentKHR and vkDeviceWaitIdle holds this: the
// queue is used by the game thread and the present thread.
@(private = "file")
g_vk_queue_lock: sync.Mutex

// ---------------------------------------------------------------------------
// Present thread.
//
// A window frame ends on the game thread with its command buffer closed; the
// rest of the frame's Vulkan work runs here: vkAcquireNextImageKHR (which
// blocks when every swapchain image is still queued), recording the blit to
// the acquired image, vkQueueSubmit, vkQueuePresentKHR and, with vsync, the
// vkWaitForPresentKHR pacing wait. The game thread meanwhile samples input and
// simulates the next frame. At most one frame waits for the thread while it
// works on another, so the game thread never runs further ahead than before
// (the frame fences still bound it at GPU_FRAMES_IN_FLIGHT).
//
// Ownership: while the thread runs, only it touches the swapchain. The game
// thread drains it (vk_present_thread_drain) before rebuilding the swapchain,
// waiting for the device, or reusing a frame slot it handed over.
// SR_VK_PRESENT_THREAD=0 presents every frame on the game thread, =1 every
// frame on the present thread; unset, vk_present_use_thread picks per frame.
@(private = "file")
Vk_Present_Job :: struct {
	slot:          int,
	serial:        u64,              // the frame's recording serial
	cmd:           vk.CommandBuffer, // the frame, ended; window target already in TRANSFER_SRC
	fence:         vk.Fence,
	acquired:      vk.Semaphore,
	queries:       vk.QueryPool,
	timed:         bool,             // write the frame's end timestamp after the blit
	source:        vk.Image,
	width, height: i32,
	present_id:    u64,              // VK_KHR_present_id value; 0 without present wait
	first_id:      u64,              // first id on the current swapchain
	pace:          bool,             // vsync with present wait
}

@(private = "file")
Vk_Present_Thread :: struct {
	thread:  ^thread.Thread,
	running: bool, // owner: game thread
	lock:    sync.Mutex,
	cond:    sync.Cond, // every change below is broadcast
	job:     Vk_Present_Job,
	has_job: bool,
	busy:    bool,
	stop:    bool,
	paced:   u64, // the newest present_id handled, pacing wait included
	submitted: u64, // the newest frame serial submitted to the queue
	// Present thread only.
	pool:           vk.CommandPool,
	blit:           [GPU_FRAMES_IN_FLIGHT]vk.CommandBuffer,
}

@(private = "file")
g_vk_present_thread: Vk_Present_Thread

@(private = "file")
vk_present_thread_start :: proc() {
	pt := &g_vk_present_thread
	if pt.running || os.get_env("SR_VK_PRESENT_THREAD", context.temp_allocator) == "0" { return }
	pool_info := vk.CommandPoolCreateInfo{sType = .COMMAND_POOL_CREATE_INFO, flags = {.RESET_COMMAND_BUFFER}, queueFamilyIndex = g_vk.queue_family}
	if !vk_ok(vk.CreateCommandPool(g_vk.device, &pool_info, nil, &pt.pool), "vkCreateCommandPool (present thread)") { return }
	alloc := vk.CommandBufferAllocateInfo{sType = .COMMAND_BUFFER_ALLOCATE_INFO, commandPool = pt.pool, level = .PRIMARY, commandBufferCount = GPU_FRAMES_IN_FLIGHT}
	if !vk_ok(vk.AllocateCommandBuffers(g_vk.device, &alloc, &pt.blit[0]), "vkAllocateCommandBuffers (present thread)") {
		vk.DestroyCommandPool(g_vk.device, pt.pool, nil)
		pt.pool = 0
		return
	}
	g_vk_present_mode.spin = os.get_env("SR_VK_PRESENT_SPIN", context.temp_allocator) == "1"
	pt.thread = thread.create_and_start(vk_present_thread_main, priority = .High)
	if pt.thread == nil {
		vk.DestroyCommandPool(g_vk.device, pt.pool, nil)
		pt.pool = 0
		fmt.eprintln("[Vulkan] Present thread unavailable; presenting on the game thread")
		return
	}
	pt.running = true
	g_vk_present_mode.forced = os.get_env("SR_VK_PRESENT_THREAD", context.temp_allocator) == "1"
}

@(private = "file")
vk_present_thread_stop :: proc() {
	pt := &g_vk_present_thread
	if !pt.running { return }
	sync.mutex_lock(&pt.lock)
	pt.stop = true
	sync.cond_broadcast(&pt.cond)
	sync.mutex_unlock(&pt.lock)
	thread.join(pt.thread)
	thread.destroy(pt.thread)
	vk.DestroyCommandPool(g_vk.device, pt.pool, nil)
	pt^ = {}
}

// Game thread: waits until the thread has nothing queued and is idle.
@(private = "file")
vk_present_thread_drain :: proc() {
	pt := &g_vk_present_thread
	if !pt.running { return }
	sync.mutex_lock(&pt.lock)
	for pt.has_job || pt.busy { sync.cond_wait(&pt.cond, &pt.lock) }
	sync.mutex_unlock(&pt.lock)
}

// Game thread: waits until the frame with this serial is on the queue (its
// fence will signal), not for later frames or the presents.
@(private = "file")
vk_present_thread_wait_submitted :: proc(serial: u64) {
	pt := &g_vk_present_thread
	if !pt.running { return }
	sync.mutex_lock(&pt.lock)
	for pt.submitted < serial && (pt.has_job || pt.busy) { sync.cond_wait(&pt.cond, &pt.lock) }
	sync.mutex_unlock(&pt.lock)
}

// Game thread: queues a frame. Waits only while the previous one has not
// been picked up yet.
@(private = "file")
vk_present_thread_hand_off :: proc(job: Vk_Present_Job) {
	pt := &g_vk_present_thread
	sync.mutex_lock(&pt.lock)
	for pt.has_job { sync.cond_wait(&pt.cond, &pt.lock) }
	pt.job, pt.has_job = job, true
	sync.cond_broadcast(&pt.cond)
	sync.mutex_unlock(&pt.lock)
}

@(private = "file")
vk_present_thread_main :: proc() {
	cpu_pin_current_thread_off_game_core() // this branch has no per-role pinning
	pt := &g_vk_present_thread
	sync.mutex_lock(&pt.lock)
	for {
		if !pt.has_job && !pt.stop && g_vk_present_mode.spin {
			// Spin for the next frame before sleeping: in game it comes within a
			// fraction of a millisecond, and waking a sleeping thread costs tens
			// of microseconds before the frame reaches the queue. After 1 ms
			// without one (menus, a frame cap) it sleeps as before.
			sync.mutex_unlock(&pt.lock)
			until := time.tick_now()._nsec + VK_PRESENT_SPIN_NS
			for i := 0; !sync.atomic_load(&pt.has_job) && !sync.atomic_load(&pt.stop); i += 1 {
				intrinsics.cpu_relax()
				if i & 255 == 255 && time.tick_now()._nsec > until { break }
			}
			sync.mutex_lock(&pt.lock)
		}
		for !pt.has_job && !pt.stop { sync.cond_wait(&pt.cond, &pt.lock) }
		if !pt.has_job { break } // stopping, nothing left
		job := pt.job
		pt.has_job, pt.busy = false, true
		sync.cond_broadcast(&pt.cond)
		sync.mutex_unlock(&pt.lock)
		vk_present_thread_run(pt, &job)
		sync.mutex_lock(&pt.lock)
		pt.busy = false
		pt.paced = max(pt.paced, job.present_id)
		sync.cond_broadcast(&pt.cond)
	}
	sync.mutex_unlock(&pt.lock)
}

// Acquires, blits, submits (always: the frame's fence must signal even when
// nothing can be shown), presents, then paces.
@(private = "file")
vk_present_thread_run :: proc(pt: ^Vk_Present_Thread, job: ^Vk_Present_Job) {
	sc := &g_vk.present
	index: u32
	acquired := vk.AcquireNextImageKHR(g_vk.device, sc.swapchain, max(u64), job.acquired, 0, &index)
	presentable := false
	#partial switch acquired {
	case .SUCCESS: presentable = true
	case .SUBOPTIMAL_KHR: presentable = true; sync.atomic_store(&sc.dirty, true) // still usable for this frame
	case .ERROR_OUT_OF_DATE_KHR: sync.atomic_store(&sc.dirty, true)
	case: vk_ok(acquired, "vkAcquireNextImageKHR")
	}
	cmd := pt.blit[job.slot] // its last use finished: the game thread waited for this slot's fence
	vk.ResetCommandBuffer(cmd, {})
	begin := vk.CommandBufferBeginInfo{sType = .COMMAND_BUFFER_BEGIN_INFO, flags = {.ONE_TIME_SUBMIT}}
	vk.BeginCommandBuffer(cmd, &begin)
	if presentable { vk_record_present_blit(cmd, job.source, job.width, job.height, sc.images[index], sc.extent) }
	if job.timed { vk.CmdWriteTimestamp2(cmd, {.BOTTOM_OF_PIPE}, job.queries, 1) }
	vk.EndCommandBuffer(cmd)

	cmds := [2]vk.CommandBuffer{job.cmd, cmd}
	wait := job.acquired
	rendered: vk.Semaphore
	if presentable { rendered = sc.rendered[index] }
	wait_stage := vk.PipelineStageFlags{.TRANSFER}
	submit := vk.SubmitInfo{
		sType = .SUBMIT_INFO, commandBufferCount = 2, pCommandBuffers = &cmds[0],
		waitSemaphoreCount = presentable ? 1 : 0, pWaitSemaphores = &wait, pWaitDstStageMask = &wait_stage,
		signalSemaphoreCount = presentable ? 1 : 0, pSignalSemaphores = &rendered,
	}
	presented := false
	sync.mutex_lock(&g_vk_queue_lock)
	vk_ok(vk.QueueSubmit(g_vk.queue, 1, &submit, job.fence), "vkQueueSubmit (present)")
	g_vk.frames[job.slot].submit_ns = vk_tick_ns(time.tick_now()) // read by the game thread after pt.submitted says so
	if presentable {
		present := vk.PresentInfoKHR{
			sType = .PRESENT_INFO_KHR, waitSemaphoreCount = 1, pWaitSemaphores = &rendered,
			swapchainCount = 1, pSwapchains = &sc.swapchain, pImageIndices = &index,
		}
		present_id: vk.PresentIdKHR
		id := job.present_id
		if id != 0 {
			present_id = {sType = .PRESENT_ID_KHR, swapchainCount = 1, pPresentIds = &id}
			present.pNext = &present_id
		}
		result := vk.QueuePresentKHR(g_vk.queue, &present)
		#partial switch result {
		case .SUCCESS: presented = true
		case .SUBOPTIMAL_KHR: presented = true; sync.atomic_store(&sc.dirty, true)
		case .ERROR_OUT_OF_DATE_KHR: sync.atomic_store(&sc.dirty, true)
		case: vk_ok(result, "vkQueuePresentKHR")
		}
	}
	sync.mutex_unlock(&g_vk_queue_lock)
	sync.mutex_lock(&pt.lock)
	pt.submitted = max(pt.submitted, job.serial)
	sync.cond_broadcast(&pt.cond)
	sync.mutex_unlock(&pt.lock)
	if !presented || job.present_id == 0 { return }
	// vsync: wait until the frame before this one is on screen, so the game
	// starts its next frame (and reads input) as late as the display allows
	// while one frame stays queued. A timeout (minimised, occluded) lets it go.
	if job.pace && job.present_id > job.first_id {
		result := vk.WaitForPresentKHR(g_vk.device, sc.swapchain, job.present_id - 1, 100 * 1_000_000)
		#partial switch result {
		case .SUCCESS, .TIMEOUT, .SUBOPTIMAL_KHR:
		case .ERROR_OUT_OF_DATE_KHR: sync.atomic_store(&sc.dirty, true)
		case: vk_ok(result, "vkWaitForPresentKHR")
		}
	}
}

@(private = "file")
vk_ok :: proc(result: vk.Result, what: string, loc := #caller_location) -> bool {
	if result == .SUCCESS { return true }
	if result == .ERROR_DEVICE_LOST {
		if !sync.atomic_exchange(&g_vk_device_lost, true) { fmt.eprintfln("[Vulkan] Device lost (%s)", what) }
		return false
	}
	fmt.eprintfln("[Vulkan] %s failed: %v (%v)", what, result, loc)
	return false
}

@(private = "file")
vk_debug_callback :: proc "system" (severity: vk.DebugUtilsMessageSeverityFlagsEXT, types: vk.DebugUtilsMessageTypeFlagsEXT, data: ^vk.DebugUtilsMessengerCallbackDataEXT, user: rawptr) -> b32 {
	context = runtime.default_context()
	kind := "info"
	if .ERROR in severity {
		sync.atomic_add(&g_vk_validation_errors, 1)
		kind = "validation"
	} else if .WARNING in severity {
		kind = "warning"
	}
	fmt.eprintfln("[Vulkan %s] %s", kind, data.pMessage)
	if g_vk_debug.log != nil {
		sync.mutex_lock(&g_vk_debug.lock)
		fmt.fprintfln(g_vk_debug.log, "[%s] %s", kind, data.pMessage)
		sync.mutex_unlock(&g_vk_debug.lock)
	}
	return false
}

// ---------------------------------------------------------------------------
// Device setup.

// Creates the instance and device. With a window (GLFW_NO_API), also its
// surface, a swapchain and the window target frames are drawn into; without
// one (benchmark, tests) rendering is offscreen only.
// Validation layers load with SR_VK_VALIDATION=1.
gpu_vk_init :: proc(window: glfw.WindowHandle = nil) -> bool {
	if g_vk.ready { return true }
	if !bool(glfw.VulkanSupported()) {
		fmt.eprintln("[Vulkan] No Vulkan loader or driver found")
		return false
	}
	vk.load_proc_addresses_global(rawptr(glfw.GetInstanceProcAddress))

	validation := g_vk_debug.wanted || os.get_env("SR_VK_VALIDATION", context.temp_allocator) == "1"
	layers := make([dynamic]cstring, context.temp_allocator)
	if validation {
		count: u32
		vk.EnumerateInstanceLayerProperties(&count, nil)
		available := make([]vk.LayerProperties, count, context.temp_allocator)
		vk.EnumerateInstanceLayerProperties(&count, raw_data(available))
		found := false
		for &layer in available {
			if string(cstring(&layer.layerName[0])) == "VK_LAYER_KHRONOS_validation" { found = true }
		}
		if found { append(&layers, "VK_LAYER_KHRONOS_validation") } else { fmt.eprintln("[Vulkan] Validation requested but VK_LAYER_KHRONOS_validation is not installed"); validation = false }
	}
	extensions := make([dynamic]cstring, context.temp_allocator)
	for ext in glfw.GetRequiredInstanceExtensions() { append(&extensions, ext) }
	if validation { append(&extensions, vk.EXT_DEBUG_UTILS_EXTENSION_NAME) }

	app := vk.ApplicationInfo{sType = .APPLICATION_INFO, pApplicationName = "SR Client", applicationVersion = 1, pEngineName = "SR Client", engineVersion = 1, apiVersion = vk.API_VERSION_1_3}
	instance_info := vk.InstanceCreateInfo{
		sType = .INSTANCE_CREATE_INFO, pApplicationInfo = &app,
		enabledLayerCount = u32(len(layers)), ppEnabledLayerNames = raw_data(layers),
		enabledExtensionCount = u32(len(extensions)), ppEnabledExtensionNames = raw_data(extensions),
	}
	if !vk_ok(vk.CreateInstance(&instance_info, nil, &g_vk.instance), "vkCreateInstance") { return false }
	vk.load_proc_addresses_instance(g_vk.instance)
	if validation {
		messenger_info := vk.DebugUtilsMessengerCreateInfoEXT{
			sType = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
			messageSeverity = {.WARNING, .ERROR},
			messageType = {.GENERAL, .VALIDATION, .PERFORMANCE},
			pfnUserCallback = vk_debug_callback,
		}
		vk.CreateDebugUtilsMessengerEXT(g_vk.instance, &messenger_info, nil, &g_vk.messenger)
	}
	g_vk_debug.validation = validation
	if validation && g_vk_debug.wanted {
		diagnostics_make_log_dir()
		if file, err := os.open(GPU_DEBUG_LOG_PATH, {.Write, .Create, .Trunc}); err == nil {
			g_vk_debug.log = file
			fmt.fprintln(file, "SR Client GPU debug log (Vulkan validation)")
		}
	}
	if window != nil {
		if !vk_ok(glfw.CreateWindowSurface(g_vk.instance, window, nil, &g_vk.present.surface), "glfwCreateWindowSurface") { return false }
		g_vk.present.window = window
	}

	// Prefer a discrete GPU with Vulkan 1.3 and a graphics queue (the
	// NvOptimus/AmdPowerXpress exports steer only OpenGL). SR_GPU picks one
	// by index or by part of its name instead.
	count: u32
	vk.EnumeratePhysicalDevices(g_vk.instance, &count, nil)
	devices := make([]vk.PhysicalDevice, count, context.temp_allocator)
	vk.EnumeratePhysicalDevices(g_vk.instance, &count, raw_data(devices))
	choice := os.get_env("SR_GPU", context.temp_allocator)
	choice_index, choice_is_index := strconv.parse_int(choice)
	best_score := -1
	for device, index in devices {
		props: vk.PhysicalDeviceProperties
		vk.GetPhysicalDeviceProperties(device, &props)
		name := string(cstring(&props.deviceName[0]))
		fmt.printfln("[Vulkan] GPU %d: %s (%v, API %d.%d)", index, name, props.deviceType, props.apiVersion >> 22, (props.apiVersion >> 12) & 0x3ff)
		if props.apiVersion < vk.API_VERSION_1_3 { continue }
		family_count: u32
		vk.GetPhysicalDeviceQueueFamilyProperties(device, &family_count, nil)
		families := make([]vk.QueueFamilyProperties, family_count, context.temp_allocator)
		vk.GetPhysicalDeviceQueueFamilyProperties(device, &family_count, raw_data(families))
		family := -1
		for f, i in families {
			if .GRAPHICS not_in f.queueFlags || f.timestampValidBits == 0 { continue }
			if window != nil {
				present: b32
				vk.GetPhysicalDeviceSurfaceSupportKHR(device, u32(i), g_vk.present.surface, &present)
				if !present { continue }
			}
			family = i
			break
		}
		if family < 0 { continue }
		score := 0
		#partial switch props.deviceType {
		case .DISCRETE_GPU:   score = 3
		case .INTEGRATED_GPU: score = 2
		case .VIRTUAL_GPU:    score = 1
		}
		if len(choice) > 0 && (choice_is_index ? choice_index == index : strings.contains(strings.to_lower(name, context.temp_allocator), strings.to_lower(choice, context.temp_allocator))) {
			score = 100
		}
		if score > best_score {
			best_score = score
			g_vk.physical, g_vk.queue_family, g_vk.props = device, u32(family), props
		}
	}
	if best_score < 0 {
		fmt.eprintln("[Vulkan] No GPU with Vulkan 1.3 and a graphics queue (that can present to the window)")
		return false
	}
	vk.GetPhysicalDeviceMemoryProperties(g_vk.physical, &g_vk.memory)
	g_vk.device_name = fmt.aprintf("%s", cstring(&g_vk.props.deviceName[0]))
	if len(choice) > 0 && best_score < 100 { fmt.eprintfln("[Vulkan] SR_GPU=%s matches no usable GPU; using %s", choice, g_vk.device_name) }
	switch g_vk.props.vendorID {
	case 0x10DE: g_vk.vendor_name = fmt.aprintf("NVIDIA")
	case 0x1002: g_vk.vendor_name = fmt.aprintf("AMD")
	case 0x8086: g_vk.vendor_name = fmt.aprintf("Intel")
	case:        g_vk.vendor_name = fmt.aprintf("vendor 0x%04X", g_vk.props.vendorID)
	}
	driver := vk.PhysicalDeviceDriverProperties{sType = .PHYSICAL_DEVICE_DRIVER_PROPERTIES}
	props2 := vk.PhysicalDeviceProperties2{sType = .PHYSICAL_DEVICE_PROPERTIES_2, pNext = &driver}
	vk.GetPhysicalDeviceProperties2(g_vk.physical, &props2)
	api := g_vk.props.apiVersion
	g_vk.version_text = fmt.aprintf("%d.%d.%d, %s %s", api >> 22, (api >> 12) & 0x3ff, api & 0xfff,
		cstring(&driver.driverName[0]), cstring(&driver.driverInfo[0]))

	features13 := vk.PhysicalDeviceVulkan13Features{sType = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES}
	features := vk.PhysicalDeviceFeatures2{sType = .PHYSICAL_DEVICE_FEATURES_2, pNext = &features13}
	vk.GetPhysicalDeviceFeatures2(g_vk.physical, &features)
	// glslc turns `discard` into demote-to-helper-invocation for Vulkan 1.3.
	if !features13.dynamicRendering || !features13.synchronization2 || !features13.shaderDemoteToHelperInvocation {
		fmt.eprintln("[Vulkan] The GPU lacks dynamic rendering, synchronization2 or shaderDemoteToHelperInvocation")
		return false
	}
	g_vk.anisotropy = bool(features.features.samplerAnisotropy)
	g_vk.wireframe = bool(features.features.fillModeNonSolid)
	enable13 := vk.PhysicalDeviceVulkan13Features{sType = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES, dynamicRendering = true, synchronization2 = true, shaderDemoteToHelperInvocation = true}
	enable := vk.PhysicalDeviceFeatures2{sType = .PHYSICAL_DEVICE_FEATURES_2, pNext = &enable13}
	enable.features.samplerAnisotropy = b32(g_vk.anisotropy)
	enable.features.fillModeNonSolid = b32(g_vk.wireframe)
	priority: f32 = 1
	queue_info := vk.DeviceQueueCreateInfo{sType = .DEVICE_QUEUE_CREATE_INFO, queueFamilyIndex = g_vk.queue_family, queueCount = 1, pQueuePriorities = &priority}
	device_extensions := make([dynamic]cstring, context.temp_allocator)
	enable_present_id := vk.PhysicalDevicePresentIdFeaturesKHR{sType = .PHYSICAL_DEVICE_PRESENT_ID_FEATURES_KHR, presentId = true}
	enable_present_wait := vk.PhysicalDevicePresentWaitFeaturesKHR{sType = .PHYSICAL_DEVICE_PRESENT_WAIT_FEATURES_KHR, pNext = &enable_present_id, presentWait = true}
	if window != nil {
		append(&device_extensions, vk.KHR_SWAPCHAIN_EXTENSION_NAME)
		if vk_present_wait_supported(g_vk.physical) {
			append(&device_extensions, vk.KHR_PRESENT_ID_EXTENSION_NAME, vk.KHR_PRESENT_WAIT_EXTENSION_NAME)
			enable_present_id.pNext = enable.pNext
			enable.pNext = &enable_present_wait
			g_vk.present.present_wait = true
		}
		vk_clock_setup(g_vk.physical, &device_extensions)
	}
	device_info := vk.DeviceCreateInfo{
		sType = .DEVICE_CREATE_INFO, pNext = &enable, queueCreateInfoCount = 1, pQueueCreateInfos = &queue_info,
		enabledExtensionCount = u32(len(device_extensions)), ppEnabledExtensionNames = raw_data(device_extensions),
	}
	if !vk_ok(vk.CreateDevice(g_vk.physical, &device_info, nil, &g_vk.device), "vkCreateDevice") { return false }
	vk.load_proc_addresses_device(g_vk.device)
	vk.GetDeviceQueue(g_vk.device, g_vk.queue_family, 0, &g_vk.queue)

	pool_info := vk.CommandPoolCreateInfo{sType = .COMMAND_POOL_CREATE_INFO, flags = {.RESET_COMMAND_BUFFER}, queueFamilyIndex = g_vk.queue_family}
	vk.CreateCommandPool(g_vk.device, &pool_info, nil, &g_vk.command_pool)
	cmds: [GPU_FRAMES_IN_FLIGHT + 1]vk.CommandBuffer
	alloc := vk.CommandBufferAllocateInfo{sType = .COMMAND_BUFFER_ALLOCATE_INFO, commandPool = g_vk.command_pool, level = .PRIMARY, commandBufferCount = len(cmds)}
	vk.AllocateCommandBuffers(g_vk.device, &alloc, &cmds[0])
	g_vk.upload_cmd = cmds[GPU_FRAMES_IN_FLIGHT]
	fence_info := vk.FenceCreateInfo{sType = .FENCE_CREATE_INFO}
	vk.CreateFence(g_vk.device, &fence_info, nil, &g_vk.upload_fence)
	frame_pool_sizes := [?]vk.DescriptorPoolSize{
		{type = .UNIFORM_BUFFER_DYNAMIC, descriptorCount = VK_FRAME_SETS},
		{type = .STORAGE_BUFFER_DYNAMIC, descriptorCount = VK_FRAME_SETS},
		{type = .STORAGE_BUFFER, descriptorCount = VK_FRAME_SETS},
		{type = .COMBINED_IMAGE_SAMPLER, descriptorCount = 2 * VK_FRAME_SETS},
	}
	for &frame, i in g_vk.frames {
		frame.cmd = cmds[i]
		vk.CreateFence(g_vk.device, &fence_info, nil, &frame.fence)
		semaphore_info := vk.SemaphoreCreateInfo{sType = .SEMAPHORE_CREATE_INFO}
		vk.CreateSemaphore(g_vk.device, &semaphore_info, nil, &frame.acquired)
		dp := vk.DescriptorPoolCreateInfo{sType = .DESCRIPTOR_POOL_CREATE_INFO, maxSets = VK_FRAME_SETS, poolSizeCount = len(frame_pool_sizes), pPoolSizes = &frame_pool_sizes[0]}
		vk.CreateDescriptorPool(g_vk.device, &dp, nil, &frame.pool)
		qp := vk.QueryPoolCreateInfo{sType = .QUERY_POOL_CREATE_INFO, queryType = .TIMESTAMP, queryCount = VK_FRAME_QUERIES}
		vk.CreateQueryPool(g_vk.device, &qp, nil, &frame.queries)
	}

	set0_bindings := [?]vk.DescriptorSetLayoutBinding{
		{binding = 0, descriptorType = .UNIFORM_BUFFER_DYNAMIC, descriptorCount = 1, stageFlags = {.VERTEX, .FRAGMENT}},
		// Per-draw data: the frame's whole uniform ring, read at the vec4
		// index the draw passes as a push constant (vk_gpu_draw_indexed).
		{binding = 1, descriptorType = .STORAGE_BUFFER_DYNAMIC, descriptorCount = 1, stageFlags = {.VERTEX}},
		{binding = 2, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, stageFlags = {.VERTEX}},
		{binding = 4, descriptorType = .COMBINED_IMAGE_SAMPLER, descriptorCount = 1, stageFlags = {.FRAGMENT}},
		{binding = 5, descriptorType = .COMBINED_IMAGE_SAMPLER, descriptorCount = 1, stageFlags = {.FRAGMENT}},
	}
	layout_info := vk.DescriptorSetLayoutCreateInfo{sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO, bindingCount = len(set0_bindings), pBindings = &set0_bindings[0]}
	vk.CreateDescriptorSetLayout(g_vk.device, &layout_info, nil, &g_vk.set0_layout)
	set1_binding := vk.DescriptorSetLayoutBinding{binding = 0, descriptorType = .COMBINED_IMAGE_SAMPLER, descriptorCount = 1, stageFlags = {.FRAGMENT}}
	layout_info = {sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO, bindingCount = 1, pBindings = &set1_binding}
	vk.CreateDescriptorSetLayout(g_vk.device, &layout_info, nil, &g_vk.set1_layout)
	set_layouts := [2]vk.DescriptorSetLayout{g_vk.set0_layout, g_vk.set1_layout}
	draw_index := vk.PushConstantRange{stageFlags = {.VERTEX}, offset = 0, size = size_of(u32)}
	pl := vk.PipelineLayoutCreateInfo{sType = .PIPELINE_LAYOUT_CREATE_INFO, setLayoutCount = 2, pSetLayouts = &set_layouts[0], pushConstantRangeCount = 1, pPushConstantRanges = &draw_index}
	vk.CreatePipelineLayout(g_vk.device, &pl, nil, &g_vk.pipeline_layout)
	texture_pool_size := vk.DescriptorPoolSize{type = .COMBINED_IMAGE_SAMPLER, descriptorCount = VK_TEXTURE_SETS}
	tp := vk.DescriptorPoolCreateInfo{sType = .DESCRIPTOR_POOL_CREATE_INFO, flags = {.FREE_DESCRIPTOR_SET}, maxSets = VK_TEXTURE_SETS, poolSizeCount = 1, pPoolSizes = &texture_pool_size}
	vk.CreateDescriptorPool(g_vk.device, &tp, nil, &g_vk.texture_pool)
	cache_data, cache_err := os.read_entire_file_from_path(VK_PIPELINE_CACHE_PATH, context.temp_allocator)
	cache_info := vk.PipelineCacheCreateInfo{sType = .PIPELINE_CACHE_CREATE_INFO}
	if cache_err == nil && len(cache_data) > 0 { cache_info.initialDataSize, cache_info.pInitialData = len(cache_data), raw_data(cache_data) }
	if vk.CreatePipelineCache(g_vk.device, &cache_info, nil, &g_vk.pipeline_cache) != .SUCCESS {
		cache_info.initialDataSize, cache_info.pInitialData = 0, nil
		vk.CreatePipelineCache(g_vk.device, &cache_info, nil, &g_vk.pipeline_cache)
	}

	g_vk.ring_align = max(int(g_vk.props.limits.minUniformBufferOffsetAlignment), 16)
	g_vk.ring = vk_buffer_make(VK_UNIFORM_RING_PER_FRAME * GPU_FRAMES_IN_FLIGHT, {.UNIFORM_BUFFER, .STORAGE_BUFFER}, {.HOST_VISIBLE, .HOST_COHERENT})
	g_vk.dummy_storage = vk_buffer_make(256, {.STORAGE_BUFFER}, {.HOST_VISIBLE, .HOST_COHERENT})
	g_vk.transient = vk_buffer_make(VK_TRANSIENT_RING_PER_FRAME * GPU_FRAMES_IN_FLIGHT, {.VERTEX_BUFFER, .INDEX_BUFFER}, {.HOST_VISIBLE, .HOST_COHERENT})
	g_vk.staging = vk_buffer_make(VK_STAGING_RING_PER_FRAME * GPU_FRAMES_IN_FLIGHT, {.TRANSFER_SRC}, {.HOST_VISIBLE, .HOST_COHERENT})
	g_vk.ready = true

	far := transmute([4]u8)f32(1)
	placeholder := Gpu_Sampler_Desc{filter = .Nearest, wrap = .Clamp, compare = true}
	g_vk.placeholder_array = vk_gpu_texture_create({width = 1, height = 1, format = .Depth, layers = 1, sampler = placeholder}, far[:])
	g_vk.placeholder_2d = vk_gpu_texture_create({width = 1, height = 1, format = .Depth, sampler = placeholder}, far[:])
	if window != nil {
		g_vk.present.vsync = true
		width, height := glfw.GetFramebufferSize(window)
		g_vk.present.target = vk_gpu_render_target_create(max(width, 1), max(height, 1))
		g_vk.default_target = g_vk.present.target
		// Built by the first frame, after the caller's gpu_set_vsync.
		g_vk.present.dirty = true
		vk_present_thread_start()
		g_vk_ll.enabled = g_vk_clock.available && os.get_env("SR_LOW_LATENCY", context.temp_allocator) != "0"
		if v, ok := strconv.parse_f64(os.get_env("SR_LL_MARGIN_US", context.temp_allocator)); ok && v >= 0 { g_vk_ll_margin_ns = v * 1000 }
		vk_probe_setup()
	}
	fmt.printfln("[Vulkan] Using %s (%s), Vulkan %s%s", g_vk.device_name, g_vk.vendor_name, g_vk.version_text,
		validation ? ", validation on" : "")
	return true
}

gpu_vk_fini :: proc() {
	if !g_vk.ready { return }
	if g_vk.recording { vk_submit() }
	vk_present_thread_stop() // finishes its frame first
	for &frame in g_vk.frames { frame.presenting = false }
	vk.DeviceWaitIdle(g_vk.device)
	device := g_vk.device
	vk_gpu_texture_destroy(&g_vk.placeholder_array)
	vk_gpu_texture_destroy(&g_vk.placeholder_2d)
	vk_gpu_render_target_destroy(&g_vk.present.target)
	vk_swapchain_release()
	leaked: [6]int // textures, targets, inputs, buffers, programs, samplers
	for live, i in g_vk.textures.live { if live { leaked[0] += 1; h := Gpu_Texture(i + 1); vk_gpu_texture_destroy(&h) } }
	for live, i in g_vk.targets.live { if live { leaked[1] += 1; h := Gpu_Render_Target(i + 1); vk_gpu_render_target_destroy(&h) } }
	for live, i in g_vk.inputs.live { if live { leaked[2] += 1; h := Gpu_Vertex_Input(i + 1); vk_gpu_vertex_input_destroy(&h) } }
	for live, i in g_vk.buffers.live { if live { leaked[3] += 1; h := Gpu_Buffer(i + 1); vk_gpu_buffer_destroy(&h) } }
	for live, i in g_vk.programs.live { if live { leaked[4] += 1; h := Gpu_Program(i + 1); vk_gpu_program_destroy(&h) } }
	for live, i in g_vk.sampler_objects.live { if live { leaked[5] += 1; h := Gpu_Sampler(i + 1); vk_gpu_sampler_destroy(&h) } }
	if total := leaked[0] + leaked[1] + leaked[2] + leaked[3] + leaked[4] + leaked[5]; total > 0 {
		fmt.eprintfln("[Vulkan] %d GPU objects were still alive at shutdown: %d textures, %d targets, %d vertex inputs, %d buffers, %d programs, %d samplers",
			total, leaked[0], leaked[1], leaked[2], leaked[3], leaked[4], leaked[5])
	}
	vk_release_retired(all = true)
	fmt.printfln("[Vulkan] GPU waits this run: %d device idle (resizes, shutdown), %d synchronous uploads, %d readbacks; %d pipelines compiled at a draw",
		g_vk_stats.idle_waits, g_vk_stats.sync_uploads, g_vk_stats.readbacks, g_vk_stats.draw_time_pipelines)
	fmt.printfln("[Vulkan] Image barriers: %d recorded, %d transitions needed none; %d set 0 binds", g_vk_stats.barriers, g_vk_stats.barriers_skipped, g_vk_stats.set0_binds)
	if g_vk_stats.present_waits > 0 {
		fmt.printfln("[Vulkan] Present waits (vsync): %d frames, %.1f ms on average", g_vk_stats.present_waits, g_vk_stats.present_wait_ms / f64(g_vk_stats.present_waits))
	}
	for _, pipeline in g_vk.pipelines { vk.DestroyPipeline(device, pipeline, nil) }
	for _, sampler in g_vk.samplers { vk.DestroySampler(device, sampler, nil) }
	vk_buffer_free(&g_vk.ring)
	vk_buffer_free(&g_vk.dummy_storage)
	vk_buffer_free(&g_vk.transient)
	vk_buffer_free(&g_vk.staging)
	vk_buffer_free(&g_vk.readback)
	for &frame in g_vk.frames {
		vk.DestroyFence(device, frame.fence, nil)
		vk.DestroySemaphore(device, frame.acquired, nil)
		vk.DestroyDescriptorPool(device, frame.pool, nil)
		vk.DestroyQueryPool(device, frame.queries, nil)
	}
	vk.DestroyFence(device, g_vk.upload_fence, nil)
	vk.DestroyCommandPool(device, g_vk.command_pool, nil)
	vk.DestroyDescriptorPool(device, g_vk.texture_pool, nil)
	cache_size: int
	if vk.GetPipelineCacheData(device, g_vk.pipeline_cache, &cache_size, nil) == .SUCCESS && cache_size > 0 {
		data := make([]u8, cache_size, context.temp_allocator)
		if vk.GetPipelineCacheData(device, g_vk.pipeline_cache, &cache_size, raw_data(data)) == .SUCCESS {
			_ = os.write_entire_file(VK_PIPELINE_CACHE_PATH, data[:cache_size])
		}
	}
	vk.DestroyPipelineCache(device, g_vk.pipeline_cache, nil)
	vk.DestroyPipelineLayout(device, g_vk.pipeline_layout, nil)
	vk.DestroyDescriptorSetLayout(device, g_vk.set0_layout, nil)
	vk.DestroyDescriptorSetLayout(device, g_vk.set1_layout, nil)
	vk_blocks_fini()
	vk.DestroyDevice(device, nil)
	if g_vk.present.surface != 0 { vk.DestroySurfaceKHR(g_vk.instance, g_vk.present.surface, nil) }
	delete(g_vk.present.images)
	delete(g_vk.present.rendered)
	if g_vk.messenger != 0 { vk.DestroyDebugUtilsMessengerEXT(g_vk.instance, g_vk.messenger, nil) }
	vk.DestroyInstance(g_vk.instance, nil)
	delete(g_vk.pipelines)
	delete(g_vk.samplers)
	delete(g_vk.retired)
	delete(g_vk.completed)
	delete(g_vk.device_name)
	delete(g_vk.vendor_name)
	delete(g_vk.version_text)
	if g_vk_debug.log != nil {
		fmt.fprintfln(g_vk_debug.log, "\nSummary: %d validation errors.", g_vk_validation_errors)
		os.close(g_vk_debug.log)
		g_vk_debug.log = nil
	}
	vk_table_destroy(&g_vk.buffers)
	vk_table_destroy(&g_vk.textures)
	vk_table_destroy(&g_vk.sampler_objects)
	vk_table_destroy(&g_vk.targets)
	vk_table_destroy(&g_vk.programs)
	vk_table_destroy(&g_vk.inputs)
	g_vk = {}
}

vk_gpu_backend_name :: proc() -> string { return "Vulkan" }

// Device-local memory (VRAM) in MB, for the tester export; 0 when unknown.
vk_gpu_vram_mb :: proc() -> u64 {
	if g_vk.physical == nil { return 0 }
	total: u64
	for i in 0 ..< g_vk.memory.memoryHeapCount {
		heap := g_vk.memory.memoryHeaps[i]
		if .DEVICE_LOCAL in heap.flags { total = max(total, u64(heap.size)) }
	}
	return total / (1024 * 1024)
}

vk_gpu_device_info :: proc() -> Gpu_Device_Info {
	return {api = "Vulkan", vendor = g_vk.vendor_name, renderer = g_vk.device_name, version = g_vk.version_text}
}
vk_gpu_device_name :: proc() -> string { return g_vk.device_name }
vk_gpu_context_token :: proc() -> rawptr { return rawptr(g_vk.device) }

vk_gpu_max_anisotropy :: proc() -> f32 {
	return g_vk.anisotropy ? max(g_vk.props.limits.maxSamplerAnisotropy, 1) : 1
}

vk_gpu_max_texture_size :: proc() -> i32 {
	return i32(g_vk.props.limits.maxImageDimension2D)
}

vk_gpu_max_storage_buffer_size :: proc() -> i64 {
	return i64(g_vk.props.limits.maxStorageBufferRange)
}

// ---------------------------------------------------------------------------
// Memory, buffers and one-shot commands.

@(private = "file")
vk_memory_type :: proc(bits: u32, flags: vk.MemoryPropertyFlags) -> u32 {
	for i in 0 ..< g_vk.memory.memoryTypeCount {
		if bits & (1 << i) != 0 && g_vk.memory.memoryTypes[i].propertyFlags & flags == flags { return i }
	}
	return 0
}

// Memory for one resource: a range of a shared block, or (a quarter block
// and up) an allocation of its own. Host-visible memory comes mapped.
@(private = "file")
vk_alloc :: proc(req: vk.MemoryRequirements, flags: vk.MemoryPropertyFlags, images: bool) -> (a: Vk_Allocation, ok: bool) {
	type := vk_memory_type(req.memoryTypeBits, flags)
	host := .HOST_VISIBLE in flags
	map_memory :: proc(memory: vk.DeviceMemory) -> [^]u8 {
		ptr: rawptr
		vk.MapMemory(g_vk.device, memory, 0, vk.DeviceSize(VK_WHOLE_SIZE), {}, &ptr)
		return cast([^]u8)ptr
	}
	size, align := int(req.size), max(int(req.alignment), 1)
	if size > VK_BLOCK_SIZE / 4 {
		info := vk.MemoryAllocateInfo{sType = .MEMORY_ALLOCATE_INFO, allocationSize = req.size, memoryTypeIndex = type}
		if !vk_ok(vk.AllocateMemory(g_vk.device, &info, nil, &a.memory), "vkAllocateMemory") { return }
		a.size = size
		if host { a.mapped = map_memory(a.memory) }
		return a, true
	}
	for block in g_vk.blocks {
		if block.type != type || block.images != images { continue }
		for &range, i in block.free {
			start := (range[0] + align - 1) / align * align
			end := range[0] + range[1]
			if start + size > end { continue }
			// Keep the parts before and after the allocation free.
			before := [2]int{range[0], start - range[0]}
			after := [2]int{start + size, end - start - size}
			ordered_remove(&block.free, i)
			if after[1] > 0 { inject_at(&block.free, i, after) }
			if before[1] > 0 { inject_at(&block.free, i, before) }
			block.used += size
			a = {memory = block.memory, offset = start, size = size, block = block}
			if block.mapped != nil { a.mapped = block.mapped[start:] }
			return a, true
		}
	}
	block := new(Vk_Block)
	info := vk.MemoryAllocateInfo{sType = .MEMORY_ALLOCATE_INFO, allocationSize = VK_BLOCK_SIZE, memoryTypeIndex = type}
	if !vk_ok(vk.AllocateMemory(g_vk.device, &info, nil, &block.memory), "vkAllocateMemory (block)") { free(block); return }
	block.type, block.images = type, images
	if host { block.mapped = map_memory(block.memory) }
	append(&block.free, [2]int{0, VK_BLOCK_SIZE})
	append(&g_vk.blocks, block)
	return vk_alloc(req, flags, images)
}

@(private = "file")
vk_free :: proc(a: ^Vk_Allocation) {
	if a.memory == 0 { return }
	block := a.block
	if block == nil {
		vk.FreeMemory(g_vk.device, a.memory, nil)
		a^ = {}
		return
	}
	// Insert in order, then merge with the neighbours.
	i := 0
	for i < len(block.free) && block.free[i][0] < a.offset { i += 1 }
	inject_at(&block.free, i, [2]int{a.offset, a.size})
	if i + 1 < len(block.free) && block.free[i][0] + block.free[i][1] == block.free[i + 1][0] {
		block.free[i][1] += block.free[i + 1][1]
		ordered_remove(&block.free, i + 1)
	}
	if i > 0 && block.free[i - 1][0] + block.free[i - 1][1] == block.free[i][0] {
		block.free[i - 1][1] += block.free[i][1]
		ordered_remove(&block.free, i)
	}
	block.used -= a.size
	a^ = {}
}

@(private = "file")
vk_blocks_fini :: proc() {
	for block in g_vk.blocks {
		if block.used != 0 { fmt.eprintfln("[Vulkan] a memory block still has %d bytes in use at shutdown", block.used) }
		vk.FreeMemory(g_vk.device, block.memory, nil)
		delete(block.free)
		free(block)
	}
	delete(g_vk.blocks)
}

@(private = "file")
vk_buffer_make :: proc(size: int, usage: vk.BufferUsageFlags, flags: vk.MemoryPropertyFlags) -> (b: Vk_Buffer) {
	info := vk.BufferCreateInfo{sType = .BUFFER_CREATE_INFO, size = vk.DeviceSize(max(size, 4)), usage = usage, sharingMode = .EXCLUSIVE}
	vk.CreateBuffer(g_vk.device, &info, nil, &b.buffer)
	req: vk.MemoryRequirements
	vk.GetBufferMemoryRequirements(g_vk.device, b.buffer, &req)
	if memory, ok := vk_alloc(req, flags, false); ok {
		b.memory = memory
		vk.BindBufferMemory(g_vk.device, b.buffer, memory.memory, vk.DeviceSize(memory.offset))
		b.mapped = memory.mapped
	}
	b.size = size
	return
}

VK_WHOLE_SIZE :: ~u64(0)

@(private = "file")
vk_buffer_free :: proc(b: ^Vk_Buffer) {
	if b.buffer == 0 { return }
	vk.DestroyBuffer(g_vk.device, b.buffer, nil)
	vk_free(&b.memory)
	b^ = {}
}

// Frees `item` once every recording up to the current one has finished.
@(private = "file")
vk_retire :: proc(item: Vk_Retired) {
	item := item
	item.serial = g_vk.serial
	append(&g_vk.retired, item)
}

@(private = "file")
vk_release_retired :: proc(all := false) {
	kept := 0
	for item in g_vk.retired {
		if !all && item.serial > g_vk.completed_serial {
			g_vk.retired[kept] = item
			kept += 1
			continue
		}
		item := item
		vk_buffer_free(&item.buffer)
		vk_image_free(&item.image)
		if item.view != 0 { vk.DestroyImageView(g_vk.device, item.view, nil) }
		if item.set != 0 { vk.FreeDescriptorSets(g_vk.device, g_vk.texture_pool, 1, &item.set) }
		if item.pipeline != 0 { vk.DestroyPipeline(g_vk.device, item.pipeline, nil) }
		if item.module != 0 { vk.DestroyShaderModule(g_vk.device, item.module, nil) }
	}
	resize(&g_vk.retired, kept)
}

// Waits until the GPU has finished everything (resizes, shutdown).
@(private = "file")
vk_idle :: proc() {
	if g_vk.recording { vk_submit() }
	vk_present_thread_drain()
	sync.mutex_lock(&g_vk_queue_lock)
	vk.DeviceWaitIdle(g_vk.device)
	sync.mutex_unlock(&g_vk_queue_lock)
	g_vk_stats.idle_waits += 1
	g_vk.completed_serial = g_vk.serial
	vk_release_retired()
}

// Where upload commands go: the frame's command buffer, between passes, so
// they run in order with the draws around them and nothing waits. Inside a
// shadow depth pass (which cannot be split) a one-shot submit is waited for.
@(private = "file")
Vk_Upload :: struct {
	cmd:     vk.CommandBuffer,
	sync:    bool,
	staging: Vk_Buffer, // the one-shot path's own source buffer
}

// Starts an upload; `source` is `size` bytes of host memory to copy from at
// `source_buffer`/`source_offset` (size 0: no source).
@(private = "file")
vk_upload_begin :: proc(size: int) -> (up: Vk_Upload, source_buffer: vk.Buffer, source_offset: vk.DeviceSize, source: [^]u8) {
	if g_vk.in_pass && g_vk.pass_depth_only {
		up.sync = true
		up.cmd = g_vk.upload_cmd
		vk.ResetCommandBuffer(up.cmd, {})
		begin := vk.CommandBufferBeginInfo{sType = .COMMAND_BUFFER_BEGIN_INFO, flags = {.ONE_TIME_SUBMIT}}
		vk.BeginCommandBuffer(up.cmd, &begin)
		if size > 0 {
			up.staging = vk_buffer_make(size, {.TRANSFER_SRC}, {.HOST_VISIBLE, .HOST_COHERENT})
			source_buffer, source = up.staging.buffer, up.staging.mapped
		}
		return
	}
	up.cmd = vk_cmd()
	vk_pass_end() // transfers cannot run inside a render pass; the next draw resumes it
	if size <= 0 { return }
	cursor := (g_vk.staging_cursor + 15) &~ 15
	if size <= VK_STAGING_RING_PER_FRAME - cursor {
		base := g_vk.slot * VK_STAGING_RING_PER_FRAME + cursor
		g_vk.staging_cursor = cursor + size
		return up, g_vk.staging.buffer, vk.DeviceSize(base), g_vk.staging.mapped[base:]
	}
	dedicated := vk_buffer_make(size, {.TRANSFER_SRC}, {.HOST_VISIBLE, .HOST_COHERENT})
	vk_retire({buffer = dedicated})
	return up, dedicated.buffer, 0, dedicated.mapped
}

@(private = "file")
vk_upload_end :: proc(up: ^Vk_Upload) {
	if up.sync {
		vk.EndCommandBuffer(up.cmd)
		submit := vk.SubmitInfo{sType = .SUBMIT_INFO, commandBufferCount = 1, pCommandBuffers = &up.cmd}
		vk.ResetFences(g_vk.device, 1, &g_vk.upload_fence)
		sync.mutex_lock(&g_vk_queue_lock)
		vk_ok(vk.QueueSubmit(g_vk.queue, 1, &submit, g_vk.upload_fence), "vkQueueSubmit (upload)")
		sync.mutex_unlock(&g_vk_queue_lock)
		vk_ok(vk.WaitForFences(g_vk.device, 1, &g_vk.upload_fence, true, max(u64)), "vkWaitForFences (upload)")
		vk_buffer_free(&up.staging)
		g_vk_stats.sync_uploads += 1
		return
	}
	// Transfer writes before every later use of a buffer: vertex and index
	// fetch, the batched objects' storage buffer (vertex shader), uniforms and
	// later copies. Images uploaded here also get their own layout barrier.
	barrier := vk.MemoryBarrier2{
		sType = .MEMORY_BARRIER_2,
		srcStageMask = {.ALL_TRANSFER}, srcAccessMask = {.TRANSFER_WRITE},
		dstStageMask = {.VERTEX_ATTRIBUTE_INPUT, .INDEX_INPUT, .VERTEX_SHADER, .FRAGMENT_SHADER, .ALL_TRANSFER},
		dstAccessMask = {.VERTEX_ATTRIBUTE_READ, .INDEX_READ, .SHADER_STORAGE_READ, .UNIFORM_READ, .TRANSFER_READ, .TRANSFER_WRITE},
	}
	dep := vk.DependencyInfo{sType = .DEPENDENCY_INFO, memoryBarrierCount = 1, pMemoryBarriers = &barrier}
	vk.CmdPipelineBarrier2(up.cmd, &dep)
}

// Immutable: `data` is the whole contents for the buffer's lifetime.
vk_gpu_buffer_create :: proc(kind: Gpu_Buffer_Kind, data: []u8) -> Gpu_Buffer {
	if len(data) == 0 || !g_vk.ready { return 0 }
	usage: vk.BufferUsageFlags = {.TRANSFER_DST}
	switch kind {
	case .Vertex:  usage += {.VERTEX_BUFFER}
	case .Index:   usage += {.INDEX_BUFFER}
	case .Storage: usage += {.STORAGE_BUFFER}
	}
	buffer := vk_buffer_make(len(data), usage, {.DEVICE_LOCAL})
	up, source_buffer, source_offset, source := vk_upload_begin(len(data))
	mem.copy(source, raw_data(data), len(data))
	region := vk.BufferCopy{srcOffset = source_offset, size = vk.DeviceSize(len(data))}
	vk.CmdCopyBuffer(up.cmd, source_buffer, buffer.buffer, 1, &region)
	vk_upload_end(&up)
	return Gpu_Buffer(vk_table_add(&g_vk.buffers, buffer))
}

vk_gpu_buffer_destroy :: proc(buffer: ^Gpu_Buffer) {
	b := vk_table_get(&g_vk.buffers, u32(buffer^))
	if b == nil { buffer^ = 0; return }
	vk_retire({buffer = b^})
	if g_vk.objects == buffer^ { g_vk.objects = 0; g_vk.set0_dirty = true }
	vk_table_remove(&g_vk.buffers, u32(buffer^))
	buffer^ = 0
}

vk_gpu_buffer_bind_storage :: proc(binding: u32, buffer: Gpu_Buffer) {
	if g_vk.objects == buffer { return }
	g_vk.objects = buffer
	g_vk.set0_dirty = true
}

vk_gpu_vertex_input_create :: proc(layout: Gpu_Vertex_Layout, vertices, indices: Gpu_Buffer) -> Gpu_Vertex_Input {
	if vertices == 0 || indices == 0 { return 0 }
	return Gpu_Vertex_Input(vk_table_add(&g_vk.inputs, Vk_Input{layout = layout, vertices = vertices, indices = indices}))
}

vk_gpu_vertex_input_bind :: proc(input: Gpu_Vertex_Input) {
	g_vk.input = input
	g_vk.transient_active = false
}

// Copies this frame's vertices and indices into the frame's region of the
// transient ring and makes them the next draws' input (see gpu_gl.odin).
vk_gpu_transient_bind :: proc(layout: Gpu_Vertex_Layout, vertices: []u8, indices: []u32) -> bool {
	assert(layout == .UI || layout == .Debug_Line)
	if !g_vk.ready { return false }
	vk_cmd() // the region belongs to the frame being recorded
	vertex_bytes := (len(vertices) + 15) &~ 15
	index_bytes := len(indices) * size_of(u32)
	if g_vk.transient_cursor + vertex_bytes + index_bytes > VK_TRANSIENT_RING_PER_FRAME {
		@(static) warned: bool
		if !warned { fmt.eprintln("[Vulkan] transient ring full for this frame; draw skipped"); warned = true }
		return false
	}
	base := g_vk.slot * VK_TRANSIENT_RING_PER_FRAME + g_vk.transient_cursor
	mem.copy(g_vk.transient.mapped[base:], raw_data(vertices), len(vertices))
	mem.copy(g_vk.transient.mapped[base + vertex_bytes:], raw_data(indices), index_bytes)
	g_vk.transient_cursor += vertex_bytes + ((index_bytes + 15) &~ 15)
	g_vk.transient_offsets = {vk.DeviceSize(base), vk.DeviceSize(base + vertex_bytes)}
	g_vk.transient_active = true
	return true
}

// Clips draws to `rect` (GL convention: x, y from the bottom row, which is
// row 0 of a target here; see the orientation note at the top).
vk_gpu_scissor :: proc(enabled: bool, rect: [4]i32 = {}) {
	g_vk.scissor_on, g_vk.scissor_rect = enabled, rect
}

vk_gpu_vertex_input_destroy :: proc(input: ^Gpu_Vertex_Input) {
	if vk_table_get(&g_vk.inputs, u32(input^)) == nil { input^ = 0; return }
	if g_vk.input == input^ { g_vk.input = 0 }
	if g_vk.bound_input == input^ { g_vk.bound_input = 0 }
	vk_table_remove(&g_vk.inputs, u32(input^))
	input^ = 0
}

// ---------------------------------------------------------------------------
// Images and textures.

@(private = "file")
vk_format :: proc(format: Gpu_Format) -> vk.Format {
	switch format {
	case .RGBA8: return VK_COLOR_FORMAT
	case .R8:    return .R8_UNORM
	case .Depth: return VK_DEPTH_FORMAT
	}
	return VK_COLOR_FORMAT
}

@(private = "file")
vk_image_make :: proc(width, height, layers, mips: u32, array: bool, format: vk.Format, usage: vk.ImageUsageFlags, samples: u32 = 1) -> (img: Vk_Image) {
	img.format, img.width, img.height, img.layers, img.mips, img.array = format, width, height, max(layers, 1), max(mips, 1), array
	img.aspect = format == VK_DEPTH_FORMAT ? {.DEPTH} : {.COLOR}
	info := vk.ImageCreateInfo{
		sType = .IMAGE_CREATE_INFO, imageType = .D2, format = format,
		extent = {width, height, 1}, mipLevels = img.mips, arrayLayers = img.layers,
		samples = vk_sample_count(samples), tiling = .OPTIMAL, usage = usage, sharingMode = .EXCLUSIVE, initialLayout = .UNDEFINED,
	}
	vk_ok(vk.CreateImage(g_vk.device, &info, nil, &img.image), "vkCreateImage")
	req: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(g_vk.device, img.image, &req)
	if memory, ok := vk_alloc(req, {.DEVICE_LOCAL}, true); ok {
		img.memory = memory
		vk.BindImageMemory(g_vk.device, img.image, memory.memory, vk.DeviceSize(memory.offset))
	}
	img.view = vk_image_view(&img, 0, img.layers, array)
	return
}

@(private = "file")
vk_sample_count :: proc(samples: u32) -> vk.SampleCountFlags {
	switch samples {
	case 2: return {._2}
	case 4: return {._4}
	case 8: return {._8}
	}
	return {._1}
}

@(private = "file")
vk_image_view :: proc(img: ^Vk_Image, base_layer, layer_count: u32, array: bool) -> (view: vk.ImageView) {
	info := vk.ImageViewCreateInfo{
		sType = .IMAGE_VIEW_CREATE_INFO, image = img.image,
		viewType = array ? .D2_ARRAY : .D2, format = img.format,
		subresourceRange = {aspectMask = img.aspect, baseMipLevel = 0, levelCount = img.mips, baseArrayLayer = base_layer, layerCount = layer_count},
	}
	vk.CreateImageView(g_vk.device, &info, nil, &view)
	return
}

@(private = "file")
vk_image_free :: proc(img: ^Vk_Image) {
	if img.image == 0 { return }
	vk.DestroyImageView(g_vk.device, img.view, nil)
	vk.DestroyImage(g_vk.device, img.image, nil)
	vk_free(&img.memory)
	img^ = {}
}

// Where and how the renderer uses an image in each layout it puts images in:
// the stages and accesses a barrier has to wait for (leaving the layout) or
// make the image ready for (entering it). `writes` is the write part of
// `access`; a layout used read-only needs only an execution dependency.
@(private = "file")
Vk_Layout_Use :: struct {
	stages: vk.PipelineStageFlags2,
	access: vk.AccessFlags2,
	writes: vk.AccessFlags2,
}

@(private = "file")
vk_layout_use :: proc(layout: vk.ImageLayout) -> Vk_Layout_Use {
	#partial switch layout {
	case .UNDEFINED:
		return {}
	case .TRANSFER_DST_OPTIMAL:
		return {stages = {.ALL_TRANSFER}, access = {.TRANSFER_WRITE}, writes = {.TRANSFER_WRITE}}
	case .TRANSFER_SRC_OPTIMAL:
		return {stages = {.ALL_TRANSFER}, access = {.TRANSFER_READ}}
	case .SHADER_READ_ONLY_OPTIMAL:
		// Every sampled image (textures, glyphs, shadow maps) is read by
		// fragment shaders only.
		return {stages = {.FRAGMENT_SHADER}, access = {.SHADER_SAMPLED_READ}}
	case .COLOR_ATTACHMENT_OPTIMAL:
		// Load ops and blending read the attachment, stores write it.
		return {stages = {.COLOR_ATTACHMENT_OUTPUT}, access = {.COLOR_ATTACHMENT_READ, .COLOR_ATTACHMENT_WRITE}, writes = {.COLOR_ATTACHMENT_WRITE}}
	case .DEPTH_ATTACHMENT_OPTIMAL:
		return {
			stages = {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
			access = {.DEPTH_STENCIL_ATTACHMENT_READ, .DEPTH_STENCIL_ATTACHMENT_WRITE},
			writes = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
		}
	}
	return {stages = {.ALL_COMMANDS}, access = {.MEMORY_READ, .MEMORY_WRITE}, writes = {.MEMORY_WRITE}}
}

// Moves layers [first, first+count) (all mips) to `layout`, waiting only for
// the stages that used the old layout and blocking only the ones that use the
// new one. A layer already in `layout` gets no barrier when that layout is
// read-only (sampling after sampling); attachments and transfer destinations
// keep one, since the next pass or copy must see the previous one's writes.
@(private = "file")
vk_transition :: proc(cmd: vk.CommandBuffer, img: ^Vk_Image, first, count: u32, layout: vk.ImageLayout) {
	barriers: [VK_MAX_LAYERS]vk.ImageMemoryBarrier2
	n: u32
	to := vk_layout_use(layout)
	for layer in first ..< first + count {
		old := img.layouts[layer]
		from := vk_layout_use(old)
		if old == layout && from.writes == {} { continue }
		barriers[n] = vk.ImageMemoryBarrier2{
			sType = .IMAGE_MEMORY_BARRIER_2,
			srcStageMask = from.stages, srcAccessMask = from.writes,
			dstStageMask = to.stages, dstAccessMask = to.access,
			oldLayout = old, newLayout = layout,
			srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED, dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
			image = img.image,
			subresourceRange = {aspectMask = img.aspect, baseMipLevel = 0, levelCount = img.mips, baseArrayLayer = layer, layerCount = 1},
		}
		img.layouts[layer] = layout
		n += 1
	}
	if n == 0 {
		g_vk_stats.barriers_skipped += 1
		return
	}
	g_vk_stats.barriers += 1
	dep := vk.DependencyInfo{sType = .DEPENDENCY_INFO, imageMemoryBarrierCount = n, pImageMemoryBarriers = &barriers[0]}
	vk.CmdPipelineBarrier2(cmd, &dep)
}

@(private = "file")
vk_sampler_get :: proc(desc: Gpu_Sampler_Desc, anisotropy: f32) -> vk.Sampler {
	key := Vk_Sampler_Key{desc, anisotropy}
	if sampler, ok := g_vk.samplers[key]; ok { return sampler }
	filter: vk.Filter = desc.filter == .Linear ? .LINEAR : .NEAREST
	wrap: vk.SamplerAddressMode = desc.wrap == .Repeat ? .REPEAT : .CLAMP_TO_EDGE
	info := vk.SamplerCreateInfo{
		sType = .SAMPLER_CREATE_INFO, magFilter = filter, minFilter = filter, mipmapMode = desc.mip_linear ? .LINEAR : .NEAREST,
		addressModeU = wrap, addressModeV = wrap, addressModeW = wrap,
		// Without mip selection GL samples only the base level.
		maxLod = desc.mip_filter ? vk.LOD_CLAMP_NONE : 0,
		anisotropyEnable = b32(anisotropy > 1 && g_vk.anisotropy), maxAnisotropy = clamp(anisotropy, 1, vk_gpu_max_anisotropy()),
		compareEnable = b32(desc.compare), compareOp = .LESS_OR_EQUAL,
		borderColor = .FLOAT_OPAQUE_WHITE,
	}
	sampler: vk.Sampler
	vk.CreateSampler(g_vk.device, &info, nil, &sampler)
	g_vk.samplers[key] = sampler
	return sampler
}

@(private = "file")
vk_texture_set :: proc(view: vk.ImageView, sampler: vk.Sampler) -> (set: vk.DescriptorSet) {
	layout := g_vk.set1_layout
	alloc := vk.DescriptorSetAllocateInfo{sType = .DESCRIPTOR_SET_ALLOCATE_INFO, descriptorPool = g_vk.texture_pool, descriptorSetCount = 1, pSetLayouts = &layout}
	if !vk_ok(vk.AllocateDescriptorSets(g_vk.device, &alloc, &set), "vkAllocateDescriptorSets (texture)") { return 0 }
	image_info := vk.DescriptorImageInfo{sampler = sampler, imageView = view, imageLayout = .SHADER_READ_ONLY_OPTIMAL}
	write := vk.WriteDescriptorSet{sType = .WRITE_DESCRIPTOR_SET, dstSet = set, dstBinding = 0, descriptorCount = 1, descriptorType = .COMBINED_IMAGE_SAMPLER, pImageInfo = &image_info}
	vk.UpdateDescriptorSets(g_vk.device, 1, &write, 0, nil)
	return
}

@(private = "file")
vk_retire_set :: proc(set: vk.DescriptorSet) {
	if set != 0 { vk_retire({set = set}) }
}

vk_gpu_texture_create :: proc(desc: Gpu_Texture_Desc, pixels: []u8 = nil) -> Gpu_Texture {
	texture, ok := vk_texture_make(desc, pixels)
	if !ok { return 0 }
	return Gpu_Texture(vk_table_add(&g_vk.textures, texture))
}

// Gives an existing 2D texture new contents, size and sampling while keeping
// its handle, so everything that holds it draws the new image.
vk_gpu_texture_replace :: proc(texture: Gpu_Texture, desc: Gpu_Texture_Desc, pixels: []u8) -> bool {
	t := vk_table_get(&g_vk.textures, u32(texture))
	if t == nil || desc.layers != 0 { return false }
	fresh, ok := vk_texture_make(desc, pixels)
	if !ok { return false }
	vk_texture_release(t)
	t^ = fresh
	g_vk.bound_set1 = 0
	if g_vk.shadow_texture == texture || g_vk.player_texture == texture { g_vk.set0_dirty = true }
	return true
}

// Frees a texture's image and descriptor sets once the frames that could
// still read them have finished.
@(private = "file")
vk_texture_release :: proc(t: ^Vk_Texture) {
	vk_retire_set(t.set)
	vk_retire_set(t.override_set)
	vk_retire({image = t.image})
}

@(private = "file")
vk_texture_make :: proc(desc: Gpu_Texture_Desc, pixels: []u8) -> (texture: Vk_Texture, ok: bool) {
	if desc.width <= 0 || desc.height <= 0 || desc.layers < 0 || desc.layers > VK_MAX_LAYERS || !g_vk.ready { return }
	w, h := u32(desc.width), u32(desc.height)
	mips: u32 = 1
	if desc.mipmaps { mips = u32(math.floor(math.log2(f32(max(w, h))))) + 1 }
	usage: vk.ImageUsageFlags = {.SAMPLED, .TRANSFER_DST}
	if desc.mipmaps { usage += {.TRANSFER_SRC} }
	if desc.format == .Depth { usage += {.DEPTH_STENCIL_ATTACHMENT} }
	texture = Vk_Texture{format = desc.format, desc = desc.sampler}
	texture.image = vk_image_make(w, h, u32(max(desc.layers, 1)), mips, desc.layers > 0, vk_format(desc.format), usage)
	img := &texture.image

	size := int(w) * int(h) * gpu_format_bytes_per_pixel(desc.format)
	has_pixels := pixels != nil && len(pixels) >= size
	up, source_buffer, source_offset, source := vk_upload_begin(has_pixels ? size : 0)
	if has_pixels {
		mem.copy(source, raw_data(pixels), size)
		vk_transition(up.cmd, img, 0, img.layers, .TRANSFER_DST_OPTIMAL)
		region := vk.BufferImageCopy{bufferOffset = source_offset, imageSubresource = {aspectMask = img.aspect, mipLevel = 0, baseArrayLayer = 0, layerCount = 1}, imageExtent = {w, h, 1}}
		vk.CmdCopyBufferToImage(up.cmd, source_buffer, img.image, .TRANSFER_DST_OPTIMAL, 1, &region)
		if mips > 1 { vk_generate_mips(up.cmd, img) }
	}
	vk_transition(up.cmd, img, 0, img.layers, .SHADER_READ_ONLY_OPTIMAL)
	vk_upload_end(&up)

	texture.sampler = vk_sampler_get(desc.sampler, 1)
	if desc.format != .Depth { texture.set = vk_texture_set(img.view, texture.sampler) }
	return texture, true
}

// Level 0 is in TRANSFER_DST; builds the chain with linear blits and leaves
// every level in TRANSFER_DST (vk_transition then moves them together).
@(private = "file")
vk_generate_mips :: proc(cmd: vk.CommandBuffer, img: ^Vk_Image) {
	w, h := i32(img.width), i32(img.height)
	for level in 1 ..< img.mips {
		pre := vk.ImageMemoryBarrier2{
			sType = .IMAGE_MEMORY_BARRIER_2,
			srcStageMask = {.ALL_TRANSFER}, srcAccessMask = {.TRANSFER_WRITE},
			dstStageMask = {.ALL_TRANSFER}, dstAccessMask = {.TRANSFER_READ},
			oldLayout = .TRANSFER_DST_OPTIMAL, newLayout = .TRANSFER_SRC_OPTIMAL,
			srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED, dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
			image = img.image, subresourceRange = {aspectMask = {.COLOR}, baseMipLevel = level - 1, levelCount = 1, baseArrayLayer = 0, layerCount = img.layers},
		}
		dep := vk.DependencyInfo{sType = .DEPENDENCY_INFO, imageMemoryBarrierCount = 1, pImageMemoryBarriers = &pre}
		vk.CmdPipelineBarrier2(cmd, &dep)
		nw, nh := max(w / 2, 1), max(h / 2, 1)
		blit := vk.ImageBlit{
			srcSubresource = {aspectMask = {.COLOR}, mipLevel = level - 1, baseArrayLayer = 0, layerCount = img.layers},
			srcOffsets = {{0, 0, 0}, {w, h, 1}},
			dstSubresource = {aspectMask = {.COLOR}, mipLevel = level, baseArrayLayer = 0, layerCount = img.layers},
			dstOffsets = {{0, 0, 0}, {nw, nh, 1}},
		}
		vk.CmdBlitImage(cmd, img.image, .TRANSFER_SRC_OPTIMAL, img.image, .TRANSFER_DST_OPTIMAL, 1, &blit, .LINEAR)
		post := pre
		post.srcAccessMask, post.dstAccessMask = {.TRANSFER_READ}, {.TRANSFER_WRITE}
		post.oldLayout, post.newLayout = .TRANSFER_SRC_OPTIMAL, .TRANSFER_DST_OPTIMAL
		dep.pImageMemoryBarriers = &post
		vk.CmdPipelineBarrier2(cmd, &dep)
		w, h = nw, nh
	}
}

vk_gpu_texture_update :: proc(texture: Gpu_Texture, format: Gpu_Format, x, y, width, height: i32, pixels: []u8) {
	t := vk_table_get(&g_vk.textures, u32(texture))
	size := int(width) * int(height) * gpu_format_bytes_per_pixel(format)
	if t == nil || len(pixels) < size { return }
	// Recorded in order: draws before this see the old texels, later ones the
	// new (the transition waits for earlier reads, frames in flight included).
	up, source_buffer, source_offset, source := vk_upload_begin(size)
	mem.copy(source, raw_data(pixels), size)
	vk_transition(up.cmd, &t.image, 0, 1, .TRANSFER_DST_OPTIMAL)
	region := vk.BufferImageCopy{bufferOffset = source_offset, imageSubresource = {aspectMask = t.image.aspect, layerCount = 1}, imageOffset = {x, y, 0}, imageExtent = {u32(width), u32(height), 1}}
	vk.CmdCopyBufferToImage(up.cmd, source_buffer, t.image.image, .TRANSFER_DST_OPTIMAL, 1, &region)
	vk_transition(up.cmd, &t.image, 0, 1, .SHADER_READ_ONLY_OPTIMAL)
	vk_upload_end(&up)
}

vk_gpu_texture_rebuild_mips :: proc(texture: Gpu_Texture) {
	t := vk_table_get(&g_vk.textures, u32(texture))
	if t == nil || t.image.mips <= 1 { return }
	up, _, _, _ := vk_upload_begin(0)
	vk_transition(up.cmd, &t.image, 0, t.image.layers, .TRANSFER_DST_OPTIMAL)
	vk_generate_mips(up.cmd, &t.image)
	vk_transition(up.cmd, &t.image, 0, t.image.layers, .SHADER_READ_ONLY_OPTIMAL)
	vk_upload_end(&up)
}

vk_gpu_texture_set_filter :: proc(texture: Gpu_Texture, filter: Gpu_Filter) {
	t := vk_table_get(&g_vk.textures, u32(texture))
	if t == nil || t.desc.filter == filter { return }
	t.desc.filter = filter
	t.sampler = vk_sampler_get(t.desc, 1)
	if t.format != .Depth {
		vk_retire_set(t.set)
		t.set = vk_texture_set(t.image.view, t.sampler)
		vk_retire_set(t.override_set)
		t.override_set, t.override = 0, 0
	}
	g_vk.set0_dirty = true
}

vk_gpu_texture_bind :: proc(unit: u32, texture: Gpu_Texture) {
	switch unit {
	case GPU_UNIT_COLOR: g_vk.color_texture = texture
	case GPU_UNIT_SHADOW:
		if g_vk.shadow_texture != texture { g_vk.shadow_texture = texture; g_vk.set0_dirty = true }
	case GPU_UNIT_PLAYER_SHADOW:
		if g_vk.player_texture != texture { g_vk.player_texture = texture; g_vk.set0_dirty = true }
	}
}

vk_gpu_texture_destroy :: proc(texture: ^Gpu_Texture) {
	t := vk_table_get(&g_vk.textures, u32(texture^))
	if t == nil { texture^ = 0; return }
	if g_active_texture == texture^ { g_active_texture = 0 }
	vk_texture_release(t)
	if g_vk.color_texture == texture^ { g_vk.color_texture = 0 }
	if g_vk.shadow_texture == texture^ { g_vk.shadow_texture = 0; g_vk.set0_dirty = true }
	if g_vk.player_texture == texture^ { g_vk.player_texture = 0; g_vk.set0_dirty = true }
	g_vk.bound_set1 = 0
	vk_table_remove(&g_vk.textures, u32(texture^))
	texture^ = 0
}

vk_gpu_sampler_create :: proc(desc: Gpu_Sampler_Desc, anisotropy: f32 = 1) -> Gpu_Sampler {
	object := Vk_Sampler_Object{desc = desc, anisotropy = anisotropy, version = 1}
	object.sampler = vk_sampler_get(desc, anisotropy)
	return Gpu_Sampler(vk_table_add(&g_vk.sampler_objects, object))
}

vk_gpu_sampler_set_anisotropy :: proc(sampler: Gpu_Sampler, value: f32) {
	s := vk_table_get(&g_vk.sampler_objects, u32(sampler))
	if s == nil { return }
	value := clamp(value, 1, vk_gpu_max_anisotropy())
	if s.anisotropy == value { return }
	s.anisotropy = value
	s.sampler = vk_sampler_get(s.desc, value)
	s.version += 1
}

// World texture filtering (Settings > Smooth textures): .Linear blends texels
// and mip levels, .Nearest keeps Krunker's pixelated look.
vk_gpu_sampler_set_filter :: proc(sampler: Gpu_Sampler, filter: Gpu_Filter) {
	s := vk_table_get(&g_vk.sampler_objects, u32(sampler))
	if s == nil { return }
	linear := filter == .Linear
	if s.desc.filter == filter && s.desc.mip_linear == linear { return }
	s.desc.filter, s.desc.mip_linear = filter, linear
	s.sampler = vk_sampler_get(s.desc, s.anisotropy)
	s.version += 1
}

vk_gpu_sampler_bind :: proc(unit: u32, sampler: Gpu_Sampler) {
	if unit == GPU_UNIT_COLOR { g_vk.color_override = sampler }
}

vk_gpu_sampler_destroy :: proc(sampler: ^Gpu_Sampler) {
	if g_vk.color_override == sampler^ { g_vk.color_override = 0 }
	vk_table_remove(&g_vk.sampler_objects, u32(sampler^))
	sampler^ = 0
}

// The colour texture's set 1, with the bound sampler override if any.
@(private = "file")
vk_color_set :: proc() -> vk.DescriptorSet {
	t := vk_table_get(&g_vk.textures, u32(g_vk.color_texture))
	if t == nil { t = vk_table_get(&g_vk.textures, u32(gpu_blank_texture())) }
	if t == nil { return 0 }
	s := vk_table_get(&g_vk.sampler_objects, u32(g_vk.color_override))
	if s == nil { return t.set }
	if t.override != g_vk.color_override || t.override_version != s.version || t.override_set == 0 {
		vk_retire_set(t.override_set)
		t.override_set = vk_texture_set(t.image.view, s.sampler)
		t.override, t.override_version = g_vk.color_override, s.version
	}
	return t.override_set
}

// ---------------------------------------------------------------------------
// Render targets.

vk_gpu_render_target_create :: proc(width, height: i32) -> Gpu_Render_Target {
	if !g_vk.ready || width <= 0 || height <= 0 { return 0 }
	target := Vk_Target{samples = 1}
	vk_target_images_make(&target, u32(width), u32(height))
	return Gpu_Render_Target(vk_table_add(&g_vk.targets, target))
}

vk_gpu_render_target_create_msaa :: proc(width, height, samples: i32) -> Gpu_Render_Target {
	if !g_vk.ready || width <= 0 || height <= 0 { return 0 }
	samples := u32(clamp(samples, 1, vk_gpu_max_msaa_samples()))
	target := Vk_Target{samples = samples}
	vk_target_images_make(&target, u32(width), u32(height))
	if samples > 1 && u32(g_vk.msaa_samples) != samples {
		// Compile the world pipelines for this sample count now, not at the
		// first draw that needs each.
		g_vk.msaa_samples = i32(samples)
		keys := make([dynamic]Vk_Pipeline_Key, context.temp_allocator)
		for live, i in g_vk.programs.live {
			if !live { continue }
			p := &g_vk.programs.items[i]
			if p.shadow || p.layout == .UI { continue }
			handle := Gpu_Program(i + 1)
			append(&keys, Vk_Pipeline_Key{program = handle, samples = u8(samples)})
			if p.layout != .Debug_Line { append(&keys, Vk_Pipeline_Key{program = handle, blend = true, samples = u8(samples)}) }
		}
		vk_pipelines_precompile(keys[:])
	}
	return Gpu_Render_Target(vk_table_add(&g_vk.targets, target))
}

vk_gpu_max_msaa_samples :: proc() -> i32 {
	if !g_vk.ready { return 1 }
	counts := g_vk.props.limits.framebufferColorSampleCounts & g_vk.props.limits.framebufferDepthSampleCounts
	if ._8 in counts { return 8 }
	if ._4 in counts { return 4 }
	if ._2 in counts { return 2 }
	return 1
}

@(private = "file")
vk_target_images_make :: proc(target: ^Vk_Target, width, height: u32) {
	target.width, target.height = width, height
	if target.samples > 1 {
		// Resolved by vkCmdResolveImage (gpu_resolve); depth stays in the pass.
		target.color = vk_image_make(width, height, 1, 1, false, VK_COLOR_FORMAT, {.COLOR_ATTACHMENT, .TRANSFER_SRC}, target.samples)
		target.depth = vk_image_make(width, height, 1, 1, false, VK_DEPTH_FORMAT, {.DEPTH_STENCIL_ATTACHMENT}, target.samples)
		return
	}
	target.color = vk_image_make(width, height, 1, 1, false, VK_COLOR_FORMAT, {.COLOR_ATTACHMENT, .TRANSFER_SRC, .TRANSFER_DST})
	target.depth = vk_image_make(width, height, 1, 1, false, VK_DEPTH_FORMAT, {.DEPTH_STENCIL_ATTACHMENT, .TRANSFER_SRC})
	// Layouts start UNDEFINED: the first pass (or readback) moves them, with
	// contents undefined until drawn, as with a new GL renderbuffer.
}

vk_gpu_render_target_create_depth :: proc(depth: Gpu_Texture, layer: i32 = -1) -> Gpu_Render_Target {
	t := vk_table_get(&g_vk.textures, u32(depth))
	if t == nil { return 0 }
	target := Vk_Target{depth_only = true, texture = depth, layer = u32(max(layer, 0)), width = t.image.width, height = t.image.height, samples = 1}
	target.layer_view = vk_image_view(&t.image, target.layer, 1, false)
	return Gpu_Render_Target(vk_table_add(&g_vk.targets, target))
}

vk_gpu_render_target_destroy :: proc(target: ^Gpu_Render_Target) {
	t := vk_table_get(&g_vk.targets, u32(target^))
	if t == nil { target^ = 0; return }
	if t.depth_only {
		vk_retire({view = t.layer_view})
	} else {
		vk_retire({image = t.color})
		vk_retire({image = t.depth})
	}
	if g_vk.target == target^ { g_vk.target = 0; g_vk.pending_color, g_vk.pending_depth = false, false }
	if g_vk.default_target == target^ { g_vk.default_target = 0 }
	vk_table_remove(&g_vk.targets, u32(target^))
	target^ = 0
}

// ---------------------------------------------------------------------------
// Frames and command recording.

@(private = "file")
vk_collect :: proc(slot: int) {
	frame := &g_vk.frames[slot]
	if !frame.submitted { return }
	if frame.presenting {
		vk_present_thread_wait_submitted(frame.serial) // submitted by the present thread
		frame.presenting = false
	}
	vk_ok(vk.WaitForFences(g_vk.device, 1, &frame.fence, true, max(u64)), "vkWaitForFences")
	frame.submitted = false
	g_vk.completed_serial = max(g_vk.completed_serial, frame.serial)
	vk_release_retired()
	if frame.timed {
		stamps: [2]u64
		period := f64(g_vk.props.limits.timestampPeriod)
		if vk.GetQueryPoolResults(g_vk.device, frame.queries, 0, 2, size_of(stamps), &stamps[0], size_of(u64), {._64, .WAIT}) == .SUCCESS {
			append(&g_vk.completed, f64(stamps[1] - stamps[0]) * period / 1e6)
			vk_probe_frame_done(slot, stamps[0], stamps[1])
			vk_ll_frame_done(frame, stamps[0], stamps[1])
			if frame.marked != {} {
				passes: [Gpu_Pass]u64
				for pass in frame.marked {
					stamp: u64
					vk.GetQueryPoolResults(g_vk.device, frame.queries, 2 + u32(pass), 1, size_of(u64), &stamp, size_of(u64), {._64, .WAIT})
					passes[pass] = u64(f64(stamp) * period)
				}
				gpu_pass_times_add(passes, frame.marked, u64(f64(stamps[1]) * period))
			}
		}
		frame.timed = false
		frame.marked = {}
	}
}

@(private = "file")
vk_begin_recording :: proc(timed: bool) {
	frame := &g_vk.frames[g_vk.slot]
	collect_start := time.tick_now()
	vk_collect(g_vk.slot)
	collect_ms := time.duration_milliseconds(time.tick_since(collect_start))
	vk.ResetFences(g_vk.device, 1, &frame.fence)
	vk.ResetCommandBuffer(frame.cmd, {})
	vk.ResetDescriptorPool(g_vk.device, frame.pool, {})
	begin := vk.CommandBufferBeginInfo{sType = .COMMAND_BUFFER_BEGIN_INFO, flags = {.ONE_TIME_SUBMIT}}
	vk.BeginCommandBuffer(frame.cmd, &begin)
	if timed {
		vk.CmdResetQueryPool(frame.cmd, frame.queries, 0, VK_FRAME_QUERIES)
		vk.CmdWriteTimestamp2(frame.cmd, {.TOP_OF_PIPE}, frame.queries, 0)
	}
	frame.timed = timed
	if timed && g_vk.present.window != nil { vk_probe_frame_start(g_vk.slot, collect_ms) }
	g_vk.serial += 1
	frame.serial = g_vk.serial
	g_vk.recording = true
	g_vk.ring_cursor = 0
	g_vk.staging_cursor = 0
	g_vk.transient_cursor = 0
	g_vk.transient_active = false
	// A fresh command buffer has nothing bound.
	g_vk.bound_pipeline, g_vk.bound_set0, g_vk.bound_set1, g_vk.bound_input = 0, 0, 0, 0
	g_vk.bound_transient = {max(vk.DeviceSize), max(vk.DeviceSize)}
	g_vk.dyn_state = {}
	g_vk.pushed_draw_vec4 = max(u32)
	g_vk.set0, g_vk.set0_dirty = 0, true
	g_vk.in_pass = false
}

@(private = "file")
vk_cmd :: proc() -> vk.CommandBuffer {
	if !g_vk.recording { vk_begin_recording(false) }
	return g_vk.frames[g_vk.slot].cmd
}

// `wait` (at the transfer stage) and `signal` are the swapchain semaphores of
// a presenting frame; 0 for every other submit.
@(private = "file")
vk_submit :: proc(wait: vk.Semaphore = 0, signal: vk.Semaphore = 0) {
	if !g_vk.recording { return }
	vk_pass_end()
	vk_flush_pending_clear()
	frame := &g_vk.frames[g_vk.slot]
	if frame.timed { vk.CmdWriteTimestamp2(frame.cmd, {.BOTTOM_OF_PIPE}, frame.queries, 1) }
	vk.EndCommandBuffer(frame.cmd)
	wait, signal := wait, signal
	wait_stage := vk.PipelineStageFlags{.TRANSFER}
	submit := vk.SubmitInfo{
		sType = .SUBMIT_INFO, commandBufferCount = 1, pCommandBuffers = &frame.cmd,
		waitSemaphoreCount = wait != 0 ? 1 : 0, pWaitSemaphores = &wait, pWaitDstStageMask = &wait_stage,
		signalSemaphoreCount = signal != 0 ? 1 : 0, pSignalSemaphores = &signal,
	}
	sync.mutex_lock(&g_vk_queue_lock)
	vk_ok(vk.QueueSubmit(g_vk.queue, 1, &submit, frame.fence), "vkQueueSubmit")
	sync.mutex_unlock(&g_vk_queue_lock)
	frame.submit_ns = vk_tick_ns(time.tick_now())
	frame.submitted = true
	g_vk.recording = false
	g_vk.in_pass = false
	g_vk.slot = (g_vk.slot + 1) % GPU_FRAMES_IN_FLIGHT
}

// After everything recorded so far has finished on the GPU.
vk_gpu_pass_mark :: proc(pass: Gpu_Pass) {
	if !g_vk.recording { return }
	frame := &g_vk.frames[g_vk.slot]
	if !frame.timed || pass in frame.marked { return }
	vk.CmdWriteTimestamp2(frame.cmd, {.ALL_COMMANDS}, frame.queries, 2 + u32(pass))
	frame.marked += {pass}
}

vk_gpu_frame_wait :: proc() {
	if !g_vk.recording { vk_collect(g_vk.slot) }
}

vk_gpu_frame_begin :: proc() {
	if g_vk.recording { vk_submit() }
	if g_vk.present.window != nil { vk_window_sync(); vk_present_wait_pace() }
	vk_begin_recording(true)
}

vk_gpu_frame_end :: proc() {
	gpu_flush_deferred()
	vk_submit()
	g_vk_present_mode.frame_end = time.tick_now()
}

vk_gpu_frames_finish :: proc() {
	if g_vk.recording { vk_submit() }
	for i in 0 ..< GPU_FRAMES_IN_FLIGHT { vk_collect((g_vk.slot + i) % GPU_FRAMES_IN_FLIGHT) }
}

vk_gpu_frames_take :: proc(gpu_ms: ^[dynamic]f64) {
	if gpu_ms != nil { append(gpu_ms, ..g_vk.completed[:]) }
	clear(&g_vk.completed)
}

vk_gpu_frames_fini :: proc() {
	vk_gpu_frames_finish()
	clear(&g_vk.completed)
}

vk_gpu_wait_idle :: proc() {
	vk_gpu_frames_finish()
	vk_present_thread_drain()
	sync.mutex_lock(&g_vk_queue_lock)
	vk.DeviceWaitIdle(g_vk.device)
	sync.mutex_unlock(&g_vk_queue_lock)
}

// ---------------------------------------------------------------------------
// Uniform data.

vk_gpu_uniform_push :: proc(binding: u32, data: []u8) {
	if !g_vk.ready || len(data) == 0 { return }
	vk_cmd() // the ring region belongs to the frame being recorded
	// The pass block is bound at its offset (uniform alignment); draw blocks
	// are read from the frame's ring as a storage buffer by vec4 index.
	align := binding == GPU_BINDING_PASS ? g_vk.ring_align : 16
	offset := (g_vk.ring_cursor + align - 1) / align * align
	if offset + len(data) > VK_UNIFORM_RING_PER_FRAME {
		@(static) warned: bool
		if !warned { fmt.eprintln("[Vulkan] uniform ring full for this frame; reusing its start"); warned = true }
		offset = 0
	}
	absolute := g_vk.slot * VK_UNIFORM_RING_PER_FRAME + offset
	mem.copy(g_vk.ring.mapped[absolute:], raw_data(data), len(data))
	g_vk.ring_cursor = offset + len(data)
	if binding == GPU_BINDING_PASS { g_vk.pass_offset = u32(absolute) } else { g_vk.draw_vec4 = u32(offset / 16) }
}

vk_gpu_uniforms_fini :: proc() {}

// ---------------------------------------------------------------------------
// Programs, pipelines and draws.

@(private = "file")
vk_shader_module :: proc(code: []u8) -> (module: vk.ShaderModule) {
	words := make([]u32, (len(code) + 3) / 4, context.temp_allocator)
	mem.copy(raw_data(words), raw_data(code), len(code))
	info := vk.ShaderModuleCreateInfo{sType = .SHADER_MODULE_CREATE_INFO, codeSize = len(code), pCode = raw_data(words)}
	vk_ok(vk.CreateShaderModule(g_vk.device, &info, nil, &module), "vkCreateShaderModule")
	return
}

vk_gpu_program_create_basic :: proc(batched, shadow_depth: bool) -> Gpu_Program {
	if !g_vk.ready { return 0 }
	vert, frag: []u8
	switch {
	case batched && shadow_depth: vert, frag = SPIRV_SHADOW_BATCHED_VERT, SPIRV_SHADOW_BATCHED_FRAG
	case shadow_depth:            vert, frag = SPIRV_SHADOW_VERT, SPIRV_SHADOW_FRAG
	case batched:                 vert, frag = SPIRV_BATCHED_VERT, SPIRV_BATCHED_FRAG
	case:                         vert, frag = SPIRV_BASIC_VERT, SPIRV_BASIC_FRAG
	}
	program := Vk_Program{vert = vk_shader_module(vert), frag = vk_shader_module(frag), layout = batched ? .Batched : .Basic, shadow = shadow_depth}
	return vk_program_add(program)
}

// Registers a program and compiles the pipelines its draws will use, so the
// first draw with a new state does not stop to compile one.
@(private = "file")
vk_program_add :: proc(program: Vk_Program) -> Gpu_Program {
	handle := Gpu_Program(vk_table_add(&g_vk.programs, program))
	keys := make([dynamic]Vk_Pipeline_Key, context.temp_allocator)
	switch {
	case program.shadow:
		append(&keys, Vk_Pipeline_Key{program = handle, depth_only = true})
	case program.layout == .UI:
		append(&keys, Vk_Pipeline_Key{program = handle, blend = true})
	case program.layout == .Debug_Line:
		append(&keys, Vk_Pipeline_Key{program = handle})
	case:
		// scene.odin: blend for transparent materials (wireframe is a debug
		// view, built on use).
		append(&keys, Vk_Pipeline_Key{program = handle}, Vk_Pipeline_Key{program = handle, blend = true})
	}
	count := len(keys)
	for i in 0 ..< count {
		keys[i].samples = 1
		// World programs also draw into the MSAA target, when there is one.
		if g_vk.msaa_samples > 1 && !program.shadow && program.layout != .UI {
			msaa := keys[i]
			msaa.samples = u8(g_vk.msaa_samples)
			append(&keys, msaa)
		}
	}
	vk_pipelines_precompile(keys[:])
	return handle
}

vk_gpu_program_create_debug_lines :: proc() -> Gpu_Program {
	if !g_vk.ready { return 0 }
	program := Vk_Program{vert = vk_shader_module(SPIRV_DEBUG_LINE_VERT), frag = vk_shader_module(SPIRV_DEBUG_LINE_FRAG), layout = .Debug_Line}
	return vk_program_add(program)
}

vk_gpu_program_create_ui :: proc() -> Gpu_Program {
	if !g_vk.ready { return 0 }
	program := Vk_Program{vert = vk_shader_module(SPIRV_UI_VERT), frag = vk_shader_module(SPIRV_UI_FRAG), layout = .UI}
	return vk_program_add(program)
}

vk_gpu_program_destroy :: proc(program: ^Gpu_Program) {
	p := vk_table_get(&g_vk.programs, u32(program^))
	if p == nil { program^ = 0; return }
	keys := make([dynamic]Vk_Pipeline_Key, context.temp_allocator)
	for key, pipeline in g_vk.pipelines {
		if key.program == program^ {
			vk_retire({pipeline = pipeline})
			append(&keys, key)
		}
	}
	for key in keys { delete_key(&g_vk.pipelines, key) }
	vk_retire({module = p.vert})
	vk_retire({module = p.frag})
	if g_vk.program == program^ { g_vk.program = 0 }
	g_vk.bound_pipeline = 0
	vk_table_remove(&g_vk.programs, u32(program^))
	program^ = 0
}

vk_gpu_program_bind :: proc(program: Gpu_Program) {
	g_vk.program = program
}

vk_gpu_draw_state_set :: proc(state: Gpu_Draw_State) {
	g_vk.draw_state = state
}

vk_gpu_draw_state_reset :: proc() {
	gpu_flush_deferred()
	g_vk.draw_state = GPU_DRAW_STATE_DEFAULT
}

@(private = "file")
vk_pipeline_get :: proc(key: Vk_Pipeline_Key) -> vk.Pipeline {
	if pipeline, ok := g_vk.pipelines[key]; ok { return pipeline }
	pipeline := vk_pipeline_build(key)
	if pipeline == 0 { return 0 }
	g_vk.pipelines[key] = pipeline
	if g_vk.recording && g_vk.in_pass { g_vk_stats.draw_time_pipelines += 1 }
	return pipeline
}

// Compiles the pipelines that do not exist yet, each on its own worker thread
// (off the game core), and waits for all of them. Driver compilation is the
// slow part and vkCreateGraphicsPipelines may run concurrently (the pipeline
// cache is internally synchronized); only the map insert stays on this thread.
@(private = "file")
vk_pipelines_precompile :: proc(keys: []Vk_Pipeline_Key) {
	Job :: struct { key: Vk_Pipeline_Key, pipeline: vk.Pipeline }
	jobs := make([dynamic]Job, context.temp_allocator)
	for key in keys {
		if key in g_vk.pipelines { continue }
		duplicate := false
		for job in jobs { if job.key == key { duplicate = true; break } }
		if !duplicate { append(&jobs, Job{key = key}) }
	}
	if len(jobs) == 0 { return }
	if len(jobs) == 1 {
		vk_pipeline_get(jobs[0].key)
		return
	}
	workers := make([]^thread.Thread, len(jobs), context.temp_allocator)
	for &job, i in jobs {
		workers[i] = thread.create_and_start_with_poly_data(&job, proc(job: ^Job) {
			cpu_pin_current_thread_off_game_core()
			job.pipeline = vk_pipeline_build(job.key)
		}, name = "vulkan pipeline")
	}
	for worker, i in workers {
		if worker == nil {
			jobs[i].pipeline = vk_pipeline_build(jobs[i].key) // thread creation failed
			continue
		}
		thread.join(worker)
		thread.destroy(worker)
	}
	for job in jobs {
		if job.pipeline != 0 { g_vk.pipelines[job.key] = job.pipeline }
	}
}

// Creates one pipeline. Reads only state that is fixed while it runs, so
// several may run at once (vk_pipelines_precompile).
@(private = "file")
vk_pipeline_build :: proc(key: Vk_Pipeline_Key) -> vk.Pipeline {
	p := vk_table_get(&g_vk.programs, u32(key.program))
	if p == nil { return 0 }
	stages := [2]vk.PipelineShaderStageCreateInfo{
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.VERTEX}, module = p.vert, pName = "main"},
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.FRAGMENT}, module = p.frag, pName = "main"},
	}
	binding: vk.VertexInputBindingDescription
	attributes: [6]vk.VertexInputAttributeDescription
	attribute_count: u32
	switch p.layout {
	case .Batched:
		binding = {binding = 0, stride = size_of(Batched_Vertex), inputRate = .VERTEX}
		attributes[0] = {location = 0, binding = 0, format = .R32G32B32_SFLOAT, offset = u32(offset_of(Batched_Vertex, position))}
		attributes[1] = {location = 1, binding = 0, format = .R32G32_SFLOAT, offset = u32(offset_of(Batched_Vertex, tex_coord))}
		attributes[2] = {location = 2, binding = 0, format = .R32_SFLOAT, offset = u32(offset_of(Batched_Vertex, face_idx))}
		attributes[3] = {location = 3, binding = 0, format = .R32_SFLOAT, offset = u32(offset_of(Batched_Vertex, object_index))}
		attribute_count = 4
	case .Basic:
		binding = {binding = 0, stride = size_of(Vertex), inputRate = .VERTEX}
		attributes[0] = {location = 0, binding = 0, format = .R32G32B32_SFLOAT, offset = u32(offset_of(Vertex, position))}
		attributes[1] = {location = 1, binding = 0, format = .R32G32_SFLOAT, offset = u32(offset_of(Vertex, tex_coord))}
		attribute_count = 2
	case .UI:
		binding = {binding = 0, stride = size_of(UI_Vertex), inputRate = .VERTEX}
		attributes[0] = {location = 0, binding = 0, format = .R32G32_SFLOAT, offset = u32(offset_of(UI_Vertex, position))}
		attributes[1] = {location = 1, binding = 0, format = .R32G32_SFLOAT, offset = u32(offset_of(UI_Vertex, local))}
		attributes[2] = {location = 2, binding = 0, format = .R32G32_SFLOAT, offset = u32(offset_of(UI_Vertex, uv))}
		attributes[3] = {location = 3, binding = 0, format = .R32G32B32A32_SFLOAT, offset = u32(offset_of(UI_Vertex, color))}
		attributes[4] = {location = 4, binding = 0, format = .R32G32B32A32_SFLOAT, offset = u32(offset_of(UI_Vertex, radii))}
		attributes[5] = {location = 5, binding = 0, format = .R32G32B32A32_SFLOAT, offset = u32(offset_of(UI_Vertex, params))}
		attribute_count = 6
	case .Debug_Line:
		binding = {binding = 0, stride = size_of(Debug_Line_Vertex), inputRate = .VERTEX}
		attributes[0] = {location = 0, binding = 0, format = .R32G32B32_SFLOAT, offset = u32(offset_of(Debug_Line_Vertex, position))}
		attributes[1] = {location = 1, binding = 0, format = .R32G32B32A32_SFLOAT, offset = u32(offset_of(Debug_Line_Vertex, color))}
		attribute_count = 2
	}
	vertex_input := vk.PipelineVertexInputStateCreateInfo{sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO, vertexBindingDescriptionCount = 1, pVertexBindingDescriptions = &binding, vertexAttributeDescriptionCount = attribute_count, pVertexAttributeDescriptions = &attributes[0]}
	assembly := vk.PipelineInputAssemblyStateCreateInfo{sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO, topology = p.layout == .Debug_Line ? .LINE_LIST : .TRIANGLE_LIST}
	viewport := vk.PipelineViewportStateCreateInfo{sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO, viewportCount = 1, scissorCount = 1}
	raster := vk.PipelineRasterizationStateCreateInfo{
		sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		polygonMode = key.wireframe && g_vk.wireframe ? .LINE : .FILL,
		frontFace = .CLOCKWISE, // GL's counter-clockwise, measured with y down
		lineWidth = 1,
	}
	multisample := vk.PipelineMultisampleStateCreateInfo{sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO, rasterizationSamples = vk_sample_count(u32(max(key.samples, 1)))}
	// Test, write and compare op are dynamic (vk_dynamic_state_apply).
	depth := vk.PipelineDepthStencilStateCreateInfo{sType = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO}
	blend_attachment := vk.PipelineColorBlendAttachmentState{
		blendEnable = b32(key.blend),
		srcColorBlendFactor = .SRC_ALPHA, dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA, colorBlendOp = .ADD,
		srcAlphaBlendFactor = .SRC_ALPHA, dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA, alphaBlendOp = .ADD,
		colorWriteMask = {.R, .G, .B, .A},
	}
	blend := vk.PipelineColorBlendStateCreateInfo{sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO, attachmentCount = key.depth_only ? 0 : 1, pAttachments = &blend_attachment}
	dynamic_states := [?]vk.DynamicState{.VIEWPORT, .SCISSOR, .CULL_MODE, .DEPTH_TEST_ENABLE, .DEPTH_WRITE_ENABLE, .DEPTH_COMPARE_OP}
	dynamic_info := vk.PipelineDynamicStateCreateInfo{sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO, dynamicStateCount = len(dynamic_states), pDynamicStates = &dynamic_states[0]}
	color_format := VK_COLOR_FORMAT
	rendering := vk.PipelineRenderingCreateInfo{
		sType = .PIPELINE_RENDERING_CREATE_INFO,
		colorAttachmentCount = key.depth_only ? 0 : 1, pColorAttachmentFormats = &color_format,
		depthAttachmentFormat = VK_DEPTH_FORMAT,
	}
	info := vk.GraphicsPipelineCreateInfo{
		sType = .GRAPHICS_PIPELINE_CREATE_INFO, pNext = &rendering,
		stageCount = 2, pStages = &stages[0],
		pVertexInputState = &vertex_input, pInputAssemblyState = &assembly, pViewportState = &viewport,
		pRasterizationState = &raster, pMultisampleState = &multisample, pDepthStencilState = &depth,
		pColorBlendState = &blend, pDynamicState = &dynamic_info, layout = g_vk.pipeline_layout,
	}
	pipeline: vk.Pipeline
	if !vk_ok(vk.CreateGraphicsPipelines(g_vk.device, g_vk.pipeline_cache, 1, &info, nil, &pipeline), "vkCreateGraphicsPipelines") { return 0 }
	return pipeline
}

@(private = "file")
vk_set_viewport :: proc(cmd: vk.CommandBuffer, width, height: u32) {
	viewport := vk.Viewport{x = 0, y = 0, width = f32(width), height = f32(height), minDepth = 0, maxDepth = 1}
	scissor := vk.Rect2D{extent = {width, height}}
	vk.CmdSetViewport(cmd, 0, 1, &viewport)
	vk.CmdSetScissor(cmd, 0, 1, &scissor)
}

@(private = "file")
vk_pass_end :: proc() {
	if !g_vk.in_pass { return }
	vk.CmdEndRendering(g_vk.frames[g_vk.slot].cmd)
	g_vk.in_pass = false
}

// Starts rendering to the current colour target, turning pending clears
// into load ops.
@(private = "file")
vk_pass_begin_color :: proc() -> bool {
	t := vk_table_get(&g_vk.targets, u32(g_vk.target))
	if t == nil || t.depth_only {
		if !g_vk.warned_no_target {
			fmt.eprintln("[Vulkan] Draw without a colour target (the window is not supported yet); skipped")
			g_vk.warned_no_target = true
		}
		return false
	}
	cmd := vk_cmd()
	vk_transition(cmd, &t.color, 0, 1, .COLOR_ATTACHMENT_OPTIMAL)
	vk_transition(cmd, &t.depth, 0, 1, .DEPTH_ATTACHMENT_OPTIMAL)
	color := vk.RenderingAttachmentInfo{
		sType = .RENDERING_ATTACHMENT_INFO, imageView = t.color.view, imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
		loadOp = g_vk.pending_color ? .CLEAR : .LOAD, storeOp = .STORE,
	}
	color.clearValue.color.float32 = g_vk.clear_color
	depth := vk.RenderingAttachmentInfo{
		sType = .RENDERING_ATTACHMENT_INFO, imageView = t.depth.view, imageLayout = .DEPTH_ATTACHMENT_OPTIMAL,
		loadOp = g_vk.pending_depth ? .CLEAR : .LOAD, storeOp = .STORE,
	}
	depth.clearValue.depthStencil = {depth = 1}
	info := vk.RenderingInfo{
		sType = .RENDERING_INFO, renderArea = {extent = {t.width, t.height}}, layerCount = 1,
		colorAttachmentCount = 1, pColorAttachments = &color, pDepthAttachment = &depth,
	}
	vk.CmdBeginRendering(cmd, &info)
	vw := g_vk.viewport.x > 0 ? u32(g_vk.viewport.x) : t.width
	vh := g_vk.viewport.y > 0 ? u32(g_vk.viewport.y) : t.height
	vk_set_viewport(cmd, min(vw, t.width), min(vh, t.height))
	g_vk.bound_scissor = {extent = {min(vw, t.width), min(vh, t.height)}}
	g_vk.pending_color, g_vk.pending_depth = false, false
	g_vk.in_pass, g_vk.pass_depth_only, g_vk.pass_cull_front = true, false, false
	g_vk.pass_samples = max(t.samples, 1)
	return true
}

// Clears requested on a target that is then left without drawing still happen.
@(private = "file")
vk_flush_pending_clear :: proc() {
	if !(g_vk.pending_color || g_vk.pending_depth) || g_vk.in_pass { return }
	if vk_pass_begin_color() { vk_pass_end() }
	g_vk.pending_color, g_vk.pending_depth = false, false
}

// Target 0 is the default target, as GL's 0 is the window.
gpu_vk_set_default_target :: proc(target: Gpu_Render_Target) {
	g_vk.default_target = target
}

@(private = "file")
vk_resolve_target :: proc(target: Gpu_Render_Target) -> Gpu_Render_Target {
	return target != 0 ? target : g_vk.default_target
}

vk_gpu_set_target :: proc(target: Gpu_Render_Target, width, height: i32) {
	gpu_flush_deferred()
	target := vk_resolve_target(target)
	if target != g_vk.target {
		// Clears requested for the old target still happen there.
		vk_pass_end()
		vk_flush_pending_clear()
		g_vk.target = target
	}
	g_vk.viewport = {width, height}
}

// MSAA: averages the source's samples into the destination's colour. Draws
// after it (the interface) go to the destination with its old depth, which
// they do not test.
vk_gpu_resolve :: proc(source, destination: Gpu_Render_Target, width, height: i32) {
	gpu_flush_deferred()
	src := vk_table_get(&g_vk.targets, u32(vk_resolve_target(source)))
	dst := vk_table_get(&g_vk.targets, u32(vk_resolve_target(destination)))
	if src == nil || dst == nil || src.depth_only || dst.depth_only || src.samples <= 1 || dst.samples > 1 { return }
	// Clears pending for the current target (either side) land first.
	vk_pass_end()
	vk_flush_pending_clear()
	cmd := vk_cmd()
	vk_transition(cmd, &src.color, 0, 1, .TRANSFER_SRC_OPTIMAL)
	vk_transition(cmd, &dst.color, 0, 1, .TRANSFER_DST_OPTIMAL)
	w := u32(clamp(width, 0, i32(min(src.width, dst.width))))
	h := u32(clamp(height, 0, i32(min(src.height, dst.height))))
	region := vk.ImageResolve{
		srcSubresource = {aspectMask = {.COLOR}, layerCount = 1},
		dstSubresource = {aspectMask = {.COLOR}, layerCount = 1},
		extent = {w, h, 1},
	}
	vk.CmdResolveImage(cmd, src.color.image, .TRANSFER_SRC_OPTIMAL, dst.color.image, .TRANSFER_DST_OPTIMAL, 1, &region)
	g_vk_stats.resolves += 1
}

vk_gpu_set_clear_color :: proc(color: [3]f32) {
	g_vk.clear_color = {color.r, color.g, color.b, 1}
}

vk_gpu_clear :: proc(color, depth: bool) {
	gpu_flush_deferred()
	if g_vk.in_pass && !g_vk.pass_depth_only {
		attachments: [2]vk.ClearAttachment
		n: u32
		if color {
			attachments[n] = {aspectMask = {.COLOR}, colorAttachment = 0}
			attachments[n].clearValue.color.float32 = g_vk.clear_color
			n += 1
		}
		if depth {
			attachments[n] = {aspectMask = {.DEPTH}}
			attachments[n].clearValue.depthStencil = {depth = 1}
			n += 1
		}
		t := vk_table_get(&g_vk.targets, u32(g_vk.target))
		rect := vk.ClearRect{rect = {extent = {t.width, t.height}}, baseArrayLayer = 0, layerCount = 1}
		if n > 0 { vk.CmdClearAttachments(g_vk.frames[g_vk.slot].cmd, n, &attachments[0], 1, &rect) }
		return
	}
	if color { g_vk.pending_color = true }
	if depth { g_vk.pending_depth = true }
}

// Set 0 for the next draw: the uniform ring, the batch objects and the shadow
// maps (placeholders inside a depth pass, which may render into them).
@(private = "file")
vk_set0 :: proc() -> vk.DescriptorSet {
	if !g_vk.set0_dirty && g_vk.set0 != 0 { return g_vk.set0 }
	frame := &g_vk.frames[g_vk.slot]
	layout := g_vk.set0_layout
	alloc := vk.DescriptorSetAllocateInfo{sType = .DESCRIPTOR_SET_ALLOCATE_INFO, descriptorPool = frame.pool, descriptorSetCount = 1, pSetLayouts = &layout}
	set: vk.DescriptorSet
	if !vk_ok(vk.AllocateDescriptorSets(g_vk.device, &alloc, &set), "vkAllocateDescriptorSets (frame)") { return g_vk.set0 }
	pass_info := vk.DescriptorBufferInfo{buffer = g_vk.ring.buffer, offset = 0, range = size_of(Basic_Pass_Uniforms)}
	draw_info := vk.DescriptorBufferInfo{buffer = g_vk.ring.buffer, offset = 0, range = VK_UNIFORM_RING_PER_FRAME}
	storage_info := vk.DescriptorBufferInfo{buffer = g_vk.dummy_storage.buffer, offset = 0, range = vk.DeviceSize(VK_WHOLE_SIZE)}
	if b := vk_table_get(&g_vk.buffers, u32(g_vk.objects)); b != nil { storage_info.buffer = b.buffer }
	shadow, player := g_vk.shadow_texture, g_vk.player_texture
	if g_vk.pass_depth_only || vk_table_get(&g_vk.textures, u32(shadow)) == nil { shadow = g_vk.placeholder_array }
	if g_vk.pass_depth_only || vk_table_get(&g_vk.textures, u32(player)) == nil { player = g_vk.placeholder_2d }
	st := vk_table_get(&g_vk.textures, u32(shadow))
	pt := vk_table_get(&g_vk.textures, u32(player))
	shadow_info := vk.DescriptorImageInfo{sampler = st.sampler, imageView = st.image.view, imageLayout = .SHADER_READ_ONLY_OPTIMAL}
	player_info := vk.DescriptorImageInfo{sampler = pt.sampler, imageView = pt.image.view, imageLayout = .SHADER_READ_ONLY_OPTIMAL}
	writes := [5]vk.WriteDescriptorSet{
		{sType = .WRITE_DESCRIPTOR_SET, dstSet = set, dstBinding = 0, descriptorCount = 1, descriptorType = .UNIFORM_BUFFER_DYNAMIC, pBufferInfo = &pass_info},
		{sType = .WRITE_DESCRIPTOR_SET, dstSet = set, dstBinding = 1, descriptorCount = 1, descriptorType = .STORAGE_BUFFER_DYNAMIC, pBufferInfo = &draw_info},
		{sType = .WRITE_DESCRIPTOR_SET, dstSet = set, dstBinding = 2, descriptorCount = 1, descriptorType = .STORAGE_BUFFER, pBufferInfo = &storage_info},
		{sType = .WRITE_DESCRIPTOR_SET, dstSet = set, dstBinding = 4, descriptorCount = 1, descriptorType = .COMBINED_IMAGE_SAMPLER, pImageInfo = &shadow_info},
		{sType = .WRITE_DESCRIPTOR_SET, dstSet = set, dstBinding = 5, descriptorCount = 1, descriptorType = .COMBINED_IMAGE_SAMPLER, pImageInfo = &player_info},
	}
	vk.UpdateDescriptorSets(g_vk.device, len(writes), &writes[0], 0, nil)
	g_vk.set0, g_vk.set0_dirty = set, false
	return set
}

// Sets the dynamic state that differs from what the command buffer has.
@(private = "file")
vk_dynamic_state_apply :: proc(cmd: vk.CommandBuffer, want: Vk_Dynamic_State) {
	have := &g_vk.dyn_state
	if !have.valid || have.cull_front != want.cull_front {
		vk.CmdSetCullMode(cmd, want.cull_front ? {.FRONT} : {})
	}
	if !have.valid || have.depth_test != want.depth_test {
		vk.CmdSetDepthTestEnable(cmd, b32(want.depth_test != .Off))
		vk.CmdSetDepthCompareOp(cmd, want.depth_test == .Less_Equal ? .LESS_OR_EQUAL : .LESS)
	}
	if !have.valid || have.depth_write != want.depth_write {
		vk.CmdSetDepthWriteEnable(cmd, b32(want.depth_write))
	}
	have^ = want
}

vk_gpu_draw_indexed :: proc(index_count: i32, first_index: u32) {
	if !g_vk.ready || index_count <= 0 { return }
	cmd := vk_cmd()
	// Before the pass: making the texture's set may first create the blank
	// texture, whose upload must run outside a render pass.
	set1 := vk_color_set()
	if !g_vk.in_pass && !vk_pass_begin_color() { return }
	state := g_vk.draw_state
	key := Vk_Pipeline_Key{program = g_vk.program, blend = state.blend && !g_vk.pass_depth_only, wireframe = state.wireframe, depth_only = g_vk.pass_depth_only, samples = g_vk.pass_depth_only ? 1 : u8(g_vk.pass_samples)}
	pipeline := vk_pipeline_get(key)
	if pipeline == 0 { return }
	if pipeline != g_vk.bound_pipeline {
		vk.CmdBindPipeline(cmd, .GRAPHICS, pipeline)
		g_vk.bound_pipeline = pipeline
	}
	vk_dynamic_state_apply(cmd, {valid = true, cull_front = g_vk.pass_depth_only && g_vk.pass_cull_front, depth_test = state.depth_test, depth_write = state.depth_write})
	set0 := vk_set0()
	offsets := [2]u32{g_vk.pass_offset, u32(g_vk.slot * VK_UNIFORM_RING_PER_FRAME)}
	if set0 != g_vk.bound_set0 || offsets != g_vk.bound_offsets {
		vk.CmdBindDescriptorSets(cmd, .GRAPHICS, g_vk.pipeline_layout, 0, 1, &set0, 2, &offsets[0])
		g_vk.bound_set0, g_vk.bound_offsets = set0, offsets
		g_vk_stats.set0_binds += 1
	}
	if set1 != g_vk.bound_set1 && set1 != 0 {
		vk.CmdBindDescriptorSets(cmd, .GRAPHICS, g_vk.pipeline_layout, 1, 1, &set1, 0, nil)
		g_vk.bound_set1 = set1
	}
	if g_vk.draw_vec4 != g_vk.pushed_draw_vec4 {
		vk.CmdPushConstants(cmd, g_vk.pipeline_layout, {.VERTEX}, 0, size_of(u32), &g_vk.draw_vec4)
		g_vk.pushed_draw_vec4 = g_vk.draw_vec4
	}
	if g_vk.transient_active {
		if g_vk.bound_input != 0 || g_vk.bound_transient != g_vk.transient_offsets {
			vertex_offset := g_vk.transient_offsets[0]
			vk.CmdBindVertexBuffers(cmd, 0, 1, &g_vk.transient.buffer, &vertex_offset)
			vk.CmdBindIndexBuffer(cmd, g_vk.transient.buffer, g_vk.transient_offsets[1], .UINT32)
			g_vk.bound_input, g_vk.bound_transient = 0, g_vk.transient_offsets
		}
	} else if g_vk.input != g_vk.bound_input || g_vk.bound_transient[0] != max(vk.DeviceSize) {
		input := vk_table_get(&g_vk.inputs, u32(g_vk.input))
		if input == nil { return }
		vb := vk_table_get(&g_vk.buffers, u32(input.vertices))
		ib := vk_table_get(&g_vk.buffers, u32(input.indices))
		if vb == nil || ib == nil { return }
		offset: vk.DeviceSize
		vk.CmdBindVertexBuffers(cmd, 0, 1, &vb.buffer, &offset)
		vk.CmdBindIndexBuffer(cmd, ib.buffer, 0, .UINT32)
		g_vk.bound_input = g_vk.input
		g_vk.bound_transient = {max(vk.DeviceSize), max(vk.DeviceSize)}
	}
	if !g_vk.pass_depth_only {
		scissor := vk_scissor_rect()
		if scissor != g_vk.bound_scissor {
			vk.CmdSetScissor(cmd, 0, 1, &scissor)
			g_vk.bound_scissor = scissor
		}
	}
	vk.CmdDrawIndexed(cmd, u32(index_count), 1, first_index, 0, 0)
}

// The scissor for the next draw: the gpu_scissor rect clamped to the current
// target, or the whole viewport while scissoring is off.
@(private = "file")
vk_scissor_rect :: proc() -> vk.Rect2D {
	t := vk_table_get(&g_vk.targets, u32(g_vk.target))
	if t == nil { return {} }
	vw := g_vk.viewport.x > 0 ? min(u32(g_vk.viewport.x), t.width) : t.width
	vh := g_vk.viewport.y > 0 ? min(u32(g_vk.viewport.y), t.height) : t.height
	if !g_vk.scissor_on { return {extent = {vw, vh}} }
	r := g_vk.scissor_rect
	x0, y0 := clamp(r[0], 0, i32(vw)), clamp(r[1], 0, i32(vh))
	x1, y1 := clamp(r[0] + max(r[2], 0), x0, i32(vw)), clamp(r[1] + max(r[3], 0), y0, i32(vh))
	return {offset = {x0, y0}, extent = {u32(x1 - x0), u32(y1 - y0)}}
}

// ---------------------------------------------------------------------------
// Depth passes (shadow maps).

@(private = "file")
vk_depth_pass_finish :: proc() {
	if !g_vk.in_pass || !g_vk.pass_depth_only { return }
	vk_pass_end()
	if t := vk_table_get(&g_vk.targets, u32(g_vk.depth_pass_target)); t != nil {
		if tex := vk_table_get(&g_vk.textures, u32(t.texture)); tex != nil {
			vk_transition(g_vk.frames[g_vk.slot].cmd, &tex.image, t.layer, 1, .SHADER_READ_ONLY_OPTIMAL)
		}
	}
	g_vk.pass_depth_only = false
	g_vk.depth_pass_target = 0
	g_vk.set0_dirty = true
}

vk_gpu_depth_pass_begin :: proc(target: Gpu_Render_Target, size: i32, cull_front: bool) {
	gpu_flush_deferred()
	t := vk_table_get(&g_vk.targets, u32(target))
	if t == nil || !t.depth_only { return }
	tex := vk_table_get(&g_vk.textures, u32(t.texture))
	if tex == nil { return }
	cmd := vk_cmd()
	vk_depth_pass_finish()
	vk_pass_end()
	vk_flush_pending_clear()
	vk_transition(cmd, &tex.image, t.layer, 1, .DEPTH_ATTACHMENT_OPTIMAL)
	depth := vk.RenderingAttachmentInfo{
		sType = .RENDERING_ATTACHMENT_INFO, imageView = t.layer_view, imageLayout = .DEPTH_ATTACHMENT_OPTIMAL,
		loadOp = .CLEAR, storeOp = .STORE,
	}
	depth.clearValue.depthStencil = {depth = 1}
	info := vk.RenderingInfo{sType = .RENDERING_INFO, renderArea = {extent = {t.width, t.height}}, layerCount = 1, pDepthAttachment = &depth}
	vk.CmdBeginRendering(cmd, &info)
	vk_set_viewport(cmd, u32(size), u32(size))
	g_vk.in_pass, g_vk.pass_depth_only, g_vk.pass_cull_front = true, true, cull_front
	g_vk.depth_pass_target = target
	g_vk.draw_state = GPU_DRAW_STATE_DEFAULT
	g_vk.set0_dirty = true
}

vk_gpu_depth_pass_end :: proc(restore: Gpu_Render_Target, viewport: [4]i32) {
	if g_vk.recording { vk_depth_pass_finish() }
	g_vk.target = vk_resolve_target(restore)
	g_vk.viewport = {viewport[2], viewport[3]}
}

// ---------------------------------------------------------------------------
// Window: swapchain and presentation.

// The target the game draws a window frame into (its size follows the
// framebuffer). The handle stays the same across resizes.
vk_gpu_window_target :: proc() -> Gpu_Render_Target {
	return g_vk.present.target
}

// FIFO when on. Off is IMMEDIATE, like GL's swap interval 0: frames go out as
// soon as they are done, so the game's FPS limit (or none) sets the rate and
// VRR displays follow it. MAILBOX only where IMMEDIATE is missing: it still
// presents on vblank (measured: 480 FPS uncapped against ~2500 with
// IMMEDIATE on an RTX 4070, windowed). Applied by recreating the swapchain
// before the next frame.
vk_gpu_set_vsync :: proc(on: bool) {
	if g_vk.present.vsync == on { return }
	g_vk.present.vsync = on
	sync.atomic_store(&g_vk.present.dirty, true)
}

@(private = "file")
vk_swapchain_release :: proc() {
	sc := &g_vk.present
	for semaphore in sc.rendered { vk.DestroySemaphore(g_vk.device, semaphore, nil) }
	clear(&sc.rendered)
	clear(&sc.images)
	if sc.swapchain != 0 { vk.DestroySwapchainKHR(g_vk.device, sc.swapchain, nil) }
	sc.swapchain = 0
}

@(private = "file")
vk_present_mode :: proc(vsync: bool) -> vk.PresentModeKHR {
	if vsync { return .FIFO }
	count: u32
	vk.GetPhysicalDeviceSurfacePresentModesKHR(g_vk.physical, g_vk.present.surface, &count, nil)
	modes := make([]vk.PresentModeKHR, count, context.temp_allocator)
	vk.GetPhysicalDeviceSurfacePresentModesKHR(g_vk.physical, g_vk.present.surface, &count, raw_data(modes))
	has :: proc(modes: []vk.PresentModeKHR, mode: vk.PresentModeKHR) -> bool {
		for m in modes { if m == mode { return true } }
		return false
	}
	if has(modes, .IMMEDIATE) { return .IMMEDIATE }
	if has(modes, .MAILBOX) { return .MAILBOX }
	return .FIFO
}

// The window's UNORM format: the frame is blitted unchanged, like GL's
// default framebuffer.
@(private = "file")
vk_surface_format :: proc() -> vk.SurfaceFormatKHR {
	count: u32
	vk.GetPhysicalDeviceSurfaceFormatsKHR(g_vk.physical, g_vk.present.surface, &count, nil)
	formats := make([]vk.SurfaceFormatKHR, count, context.temp_allocator)
	vk.GetPhysicalDeviceSurfaceFormatsKHR(g_vk.physical, g_vk.present.surface, &count, raw_data(formats))
	for wanted in ([2]vk.Format{.B8G8R8A8_UNORM, .R8G8B8A8_UNORM}) {
		for f in formats { if f.format == wanted && f.colorSpace == .SRGB_NONLINEAR { return f } }
	}
	if count > 0 {
		fmt.eprintfln("[Vulkan] No BGRA8/RGBA8 UNORM window format; using %v (colours may differ from OpenGL)", formats[0].format)
		return formats[0]
	}
	return {format = .B8G8R8A8_UNORM, colorSpace = .SRGB_NONLINEAR}
}

// (Re)creates the swapchain for the framebuffer's current size. Returns false
// while the window is minimised (0x0); the next frame tries again.
@(private = "file")
vk_swapchain_build :: proc() -> bool {
	sc := &g_vk.present
	width, height := glfw.GetFramebufferSize(sc.window)
	if width <= 0 || height <= 0 { return false }
	caps: vk.SurfaceCapabilitiesKHR
	vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(g_vk.physical, sc.surface, &caps)
	extent := caps.currentExtent
	if extent.width == max(u32) {
		extent = {
			clamp(u32(width), caps.minImageExtent.width, caps.maxImageExtent.width),
			clamp(u32(height), caps.minImageExtent.height, caps.maxImageExtent.height),
		}
	}
	if extent.width == 0 || extent.height == 0 { return false }
	surface_format := vk_surface_format()
	image_count := caps.minImageCount + 1
	if caps.maxImageCount > 0 { image_count = min(image_count, caps.maxImageCount) }
	alpha := vk.CompositeAlphaFlagsKHR{.OPAQUE}
	for candidate in ([4]vk.CompositeAlphaFlagKHR{.OPAQUE, .INHERIT, .PRE_MULTIPLIED, .POST_MULTIPLIED}) {
		if candidate in caps.supportedCompositeAlpha { alpha = {candidate}; break }
	}
	mode := vk_present_mode(sc.vsync)
	info := vk.SwapchainCreateInfoKHR{
		sType = .SWAPCHAIN_CREATE_INFO_KHR, surface = sc.surface,
		minImageCount = image_count, imageFormat = surface_format.format, imageColorSpace = surface_format.colorSpace,
		imageExtent = extent, imageArrayLayers = 1, imageUsage = {.TRANSFER_DST}, imageSharingMode = .EXCLUSIVE,
		preTransform = caps.currentTransform, compositeAlpha = alpha, presentMode = mode, clipped = true,
		oldSwapchain = sc.swapchain,
	}
	swapchain: vk.SwapchainKHR
	if !vk_ok(vk.CreateSwapchainKHR(g_vk.device, &info, nil, &swapchain), "vkCreateSwapchainKHR") { return false }
	vk_swapchain_release()
	sc.swapchain, sc.format, sc.extent = swapchain, surface_format.format, extent
	count: u32
	vk.GetSwapchainImagesKHR(g_vk.device, swapchain, &count, nil)
	resize(&sc.images, int(count))
	vk.GetSwapchainImagesKHR(g_vk.device, swapchain, &count, raw_data(sc.images))
	semaphore_info := vk.SemaphoreCreateInfo{sType = .SEMAPHORE_CREATE_INFO}
	for _ in 0 ..< count {
		semaphore: vk.Semaphore
		vk.CreateSemaphore(g_vk.device, &semaphore_info, nil, &semaphore)
		append(&sc.rendered, semaphore)
	}
	sync.atomic_store(&sc.dirty, false) // the present thread is drained (vk_idle)
	sc.first_id = sc.present_id + 1
	fmt.printfln("[Vulkan] Swapchain %dx%d, %d images, %v, %v%s", extent.width, extent.height, count, surface_format.format, mode, sc.present_wait ? ", present wait" : "")
	return true
}

// Before a window frame: follows the framebuffer size (window target and
// swapchain) and applies vsync changes. Waits for the GPU only on a change.
// The device offers VK_KHR_present_id and VK_KHR_present_wait with both
// features. SR_VK_PRESENT_WAIT=0 turns the pacing off.
@(private = "file")
vk_present_wait_supported :: proc(physical: vk.PhysicalDevice) -> bool {
	if os.get_env("SR_VK_PRESENT_WAIT", context.temp_allocator) == "0" { return false }
	count: u32
	vk.EnumerateDeviceExtensionProperties(physical, nil, &count, nil)
	extensions := make([]vk.ExtensionProperties, count, context.temp_allocator)
	vk.EnumerateDeviceExtensionProperties(physical, nil, &count, raw_data(extensions))
	has_id, has_wait: bool
	for &e in extensions {
		name := string(cstring(&e.extensionName[0]))
		if name == vk.KHR_PRESENT_ID_EXTENSION_NAME { has_id = true }
		if name == vk.KHR_PRESENT_WAIT_EXTENSION_NAME { has_wait = true }
	}
	if !has_id || !has_wait { return false }
	present_id := vk.PhysicalDevicePresentIdFeaturesKHR{sType = .PHYSICAL_DEVICE_PRESENT_ID_FEATURES_KHR}
	present_wait := vk.PhysicalDevicePresentWaitFeaturesKHR{sType = .PHYSICAL_DEVICE_PRESENT_WAIT_FEATURES_KHR, pNext = &present_id}
	features := vk.PhysicalDeviceFeatures2{sType = .PHYSICAL_DEVICE_FEATURES_2, pNext = &present_wait}
	vk.GetPhysicalDeviceFeatures2(physical, &features)
	return bool(present_id.presentId) && bool(present_wait.presentWait)
}

// With vsync on: waits until the frame before the last presented one is on
// screen, so the next frame samples input as late as the display allows
// while one frame stays queued (no missed refresh when a frame runs long).
// A timeout (minimised, occluded) just lets the frame go ahead.
@(private = "file")
vk_present_wait_pace :: proc() {
	sc := &g_vk.present
	sc.last_wait_ms = 0
	if !sc.present_wait || !sc.vsync || sc.swapchain == 0 || sync.atomic_load(&sc.dirty) || sc.present_id < 2 { return }
	if pt := &g_vk_present_thread; pt.running && !g_vk_present_mode.last_inline {
		// The present thread waits for the display after each present; this
		// waits for it to have done so for the newest frame handed over.
		start := time.tick_now()
		sync.mutex_lock(&pt.lock)
		for pt.paced < sc.present_id {
			if !sync.cond_wait_with_timeout(&pt.cond, &pt.lock, 200 * time.Millisecond) { break }
		}
		sync.mutex_unlock(&pt.lock)
		sc.last_wait_ms = time.duration_milliseconds(time.tick_since(start))
		g_vk_stats.present_waits += 1
		g_vk_stats.present_wait_ms += sc.last_wait_ms
		return
	}
	target := sc.present_id - 1
	if target < sc.first_id { return } // presented on an earlier swapchain
	start := time.tick_now()
	result := vk.WaitForPresentKHR(g_vk.device, sc.swapchain, target, 100 * 1_000_000)
	#partial switch result {
	case .SUCCESS, .TIMEOUT, .SUBOPTIMAL_KHR:
	case .ERROR_OUT_OF_DATE_KHR: sync.atomic_store(&sc.dirty, true)
	case: vk_ok(result, "vkWaitForPresentKHR")
	}
	sc.last_wait_ms = time.duration_milliseconds(time.tick_since(start))
	g_vk_stats.present_waits += 1
	g_vk_stats.present_wait_ms += sc.last_wait_ms
}

vk_gpu_last_vsync_wait_ms :: proc() -> f64 { return g_vk.present.last_wait_ms }

@(private = "file")
vk_window_sync :: proc() {
	sc := &g_vk.present
	width, height := glfw.GetFramebufferSize(sc.window)
	if width <= 0 || height <= 0 { return } // minimised: nothing is presented
	t := vk_table_get(&g_vk.targets, u32(sc.target))
	resized := t != nil && (t.width != u32(width) || t.height != u32(height))
	if !resized && !sync.atomic_load(&sc.dirty) && sc.swapchain != 0 && sc.extent.width == u32(width) && sc.extent.height == u32(height) { return }
	vk_idle()
	if resized {
		vk_image_free(&t.color)
		vk_image_free(&t.depth)
		vk_target_images_make(t, u32(width), u32(height))
		if g_vk.target == sc.target { g_vk.viewport = {width, height} }
	}
	vk_swapchain_build()
}

// Blits the window target, flipped to top-down, to the next swapchain image
// and presents it, ending the frame's command buffer. A frame that cannot be
// presented (minimised, swapchain out of date) is still submitted by
// gpu_frame_end.
vk_gpu_present :: proc(window: glfw.WindowHandle = nil) {
	present_start := time.tick_now()
	defer if g_vk_probe.recording { g_vk_probe.present_ms += time.duration_milliseconds(time.tick_since(present_start)) }
	gpu_flush_deferred()
	vk_gpu_pass_mark(.Present)
	sc := &g_vk.present
	if sc.window == nil || sc.swapchain == 0 || sync.atomic_load(&sc.dirty) { return }
	t := vk_table_get(&g_vk.targets, u32(sc.target))
	if t == nil { return }
	cmd := vk_cmd()
	frame := &g_vk.frames[g_vk.slot]
	pm := &g_vk_present_mode
	if vk_present_use_thread() {
		pm.last_inline = false
		pm.thread_frames += 1
		// Close the frame here; the present thread acquires, blits, submits
		// and presents it (and writes its end timestamp after the blit).
		vk_pass_end()
		vk_flush_pending_clear()
		vk_transition(cmd, &t.color, 0, 1, .TRANSFER_SRC_OPTIMAL)
		vk.EndCommandBuffer(frame.cmd)
		job := Vk_Present_Job{
			slot = g_vk.slot, serial = frame.serial, cmd = frame.cmd, fence = frame.fence, acquired = frame.acquired,
			queries = frame.queries, timed = frame.timed,
			source = t.color.image, width = i32(t.width), height = i32(t.height),
			first_id = sc.first_id, pace = sc.vsync && sc.present_wait,
		}
		if sc.present_wait {
			sc.present_id += 1
			job.present_id = sc.present_id
		}
		frame.submitted, frame.presenting = true, true
		g_vk.recording, g_vk.in_pass = false, false
		g_vk.slot = (g_vk.slot + 1) % GPU_FRAMES_IN_FLIGHT
		vk_present_thread_hand_off(job)
		return
	}
	inline_start := time.tick_now()
	pm.last_inline = true
	pm.inline_frames += 1
	defer pm.inline_cost_ns += (f64(time.tick_diff(inline_start, time.tick_now())) - pm.inline_cost_ns) * 0.05
	index: u32
	acquired := vk.AcquireNextImageKHR(g_vk.device, sc.swapchain, max(u64), frame.acquired, 0, &index)
	#partial switch acquired {
	case .SUCCESS:
	case .SUBOPTIMAL_KHR: sync.atomic_store(&sc.dirty, true) // still usable for this frame
	case .ERROR_OUT_OF_DATE_KHR: sync.atomic_store(&sc.dirty, true); return
	case: vk_ok(acquired, "vkAcquireNextImageKHR"); return
	}
	vk_pass_end()
	vk_flush_pending_clear()
	vk_transition(cmd, &t.color, 0, 1, .TRANSFER_SRC_OPTIMAL)
	vk_record_present_blit(cmd, t.color.image, i32(t.width), i32(t.height), sc.images[index], sc.extent)
	rendered := sc.rendered[index]
	vk_submit(frame.acquired, rendered)
	present := vk.PresentInfoKHR{
		sType = .PRESENT_INFO_KHR, waitSemaphoreCount = 1, pWaitSemaphores = &rendered,
		swapchainCount = 1, pSwapchains = &sc.swapchain, pImageIndices = &index,
	}
	present_id: vk.PresentIdKHR
	id: u64
	if sc.present_wait {
		sc.present_id += 1
		id = sc.present_id
		present_id = {sType = .PRESENT_ID_KHR, swapchainCount = 1, pPresentIds = &id}
		present.pNext = &present_id
	}
	sync.mutex_lock(&g_vk_queue_lock)
	presented := vk.QueuePresentKHR(g_vk.queue, &present)
	sync.mutex_unlock(&g_vk_queue_lock)
	#partial switch presented {
	case .SUCCESS:
	case .SUBOPTIMAL_KHR, .ERROR_OUT_OF_DATE_KHR: sync.atomic_store(&sc.dirty, true)
	case: vk_ok(presented, "vkQueuePresentKHR")
	}
}

// Copies the window target (in TRANSFER_SRC), flipped to top-down, to a
// swapchain image and leaves that image ready to present. The copy waits for
// the acquire semaphore at the transfer stage.
@(private = "file")
vk_record_present_blit :: proc(cmd: vk.CommandBuffer, source: vk.Image, w, h: i32, image: vk.Image, extent: vk.Extent2D) {
	range := vk.ImageSubresourceRange{aspectMask = {.COLOR}, levelCount = 1, layerCount = 1}
	to_transfer := vk.ImageMemoryBarrier2{
		sType = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask = {.ALL_TRANSFER}, dstStageMask = {.ALL_TRANSFER}, dstAccessMask = {.TRANSFER_WRITE},
		oldLayout = .UNDEFINED, newLayout = .TRANSFER_DST_OPTIMAL,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED, dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image = image, subresourceRange = range,
	}
	dep := vk.DependencyInfo{sType = .DEPENDENCY_INFO, imageMemoryBarrierCount = 1, pImageMemoryBarriers = &to_transfer}
	vk.CmdPipelineBarrier2(cmd, &dep)
	ew, eh := i32(extent.width), i32(extent.height)
	blit := vk.ImageBlit{
		srcSubresource = {aspectMask = {.COLOR}, layerCount = 1},
		srcOffsets = {{0, 0, 0}, {w, h, 1}},
		dstSubresource = {aspectMask = {.COLOR}, layerCount = 1},
		dstOffsets = {{0, eh, 0}, {ew, 0, 1}}, // row 0 is GL's bottom row
	}
	filter: vk.Filter = w == ew && h == eh ? .NEAREST : .LINEAR
	vk.CmdBlitImage(cmd, source, .TRANSFER_SRC_OPTIMAL, image, .TRANSFER_DST_OPTIMAL, 1, &blit, filter)
	to_present := vk.ImageMemoryBarrier2{
		sType = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask = {.ALL_TRANSFER}, srcAccessMask = {.TRANSFER_WRITE},
		oldLayout = .TRANSFER_DST_OPTIMAL, newLayout = .PRESENT_SRC_KHR,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED, dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image = image, subresourceRange = range,
	}
	dep.pImageMemoryBarriers = &to_present
	vk.CmdPipelineBarrier2(cmd, &dep)
}

// ---------------------------------------------------------------------------
// Readback.

@(private = "file")
vk_readback_copy :: proc(target: Gpu_Render_Target, depth: bool, width, height: i32) -> (data: [^]u8, ok: bool) {
	target := vk_resolve_target(target)
	t := vk_table_get(&g_vk.targets, u32(target))
	if t == nil || t.depth_only || t.samples > 1 { return }
	// Draws and clears still pending for it land first.
	if g_vk.target == target { vk_pass_end(); vk_flush_pending_clear() }
	size := int(width) * int(height) * 4
	if g_vk.readback.size < size {
		vk_retire({buffer = g_vk.readback})
		g_vk.readback = vk_buffer_make(size, {.TRANSFER_DST}, {.HOST_VISIBLE, .HOST_COHERENT, .HOST_CACHED})
		if g_vk.readback.mapped == nil { g_vk.readback = vk_buffer_make(size, {.TRANSFER_DST}, {.HOST_VISIBLE, .HOST_COHERENT}) }
	}
	cmd := vk_cmd()
	vk_pass_end()
	img := depth ? &t.depth : &t.color
	attachment_layout := img.layouts[0]
	vk_transition(cmd, img, 0, 1, .TRANSFER_SRC_OPTIMAL)
	region := vk.BufferImageCopy{imageSubresource = {aspectMask = img.aspect, layerCount = 1}, imageExtent = {u32(width), u32(height), 1}}
	vk.CmdCopyImageToBuffer(cmd, img.image, .TRANSFER_SRC_OPTIMAL, g_vk.readback.buffer, 1, &region)
	// The copy's writes become visible to the CPU, which reads the mapped
	// buffer after the fence.
	to_host := vk.MemoryBarrier2{
		sType = .MEMORY_BARRIER_2,
		srcStageMask = {.ALL_TRANSFER}, srcAccessMask = {.TRANSFER_WRITE},
		dstStageMask = {.HOST}, dstAccessMask = {.HOST_READ},
	}
	host_dep := vk.DependencyInfo{sType = .DEPENDENCY_INFO, memoryBarrierCount = 1, pMemoryBarriers = &to_host}
	vk.CmdPipelineBarrier2(cmd, &host_dep)
	vk_transition(cmd, img, 0, 1, attachment_layout == .UNDEFINED ? (depth ? .DEPTH_ATTACHMENT_OPTIMAL : .COLOR_ATTACHMENT_OPTIMAL) : attachment_layout)
	slot := g_vk.slot
	vk_submit()
	vk_collect(slot)
	g_vk_stats.readbacks += 1
	return g_vk.readback.mapped, true
}

// RGB8, rows bottom-up like GL (see the orientation note at the top).
vk_gpu_read_color_rgb :: proc(target: Gpu_Render_Target, width, height: i32, pixels: []u8) {
	if len(pixels) < int(width) * int(height) * 3 { return }
	gpu_flush_deferred()
	data, ok := vk_readback_copy(target, false, width, height)
	if !ok { return }
	for i in 0 ..< int(width) * int(height) {
		pixels[i * 3 + 0] = data[i * 4 + 0]
		pixels[i * 3 + 1] = data[i * 4 + 1]
		pixels[i * 3 + 2] = data[i * 4 + 2]
	}
}

// f32 depth bits; compare only with other reads on this backend.
vk_gpu_read_depth :: proc(target: Gpu_Render_Target, width, height: i32, depth: []u32) {
	if len(depth) < int(width) * int(height) { return }
	gpu_flush_deferred()
	data, ok := vk_readback_copy(target, true, width, height)
	if !ok { return }
	mem.copy(raw_data(depth), data, int(width) * int(height) * 4)
}

