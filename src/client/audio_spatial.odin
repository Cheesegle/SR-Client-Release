package main

import "base:runtime"
import "core:math"
import "core:sync"
import ma "vendor:miniaudio"
import shared "../shared"

// Krunker plays remote sounds through Howler's spatial plugin, which wraps a
// WebAudio PannerNode. Values below come from the client's sound manager
// (play3D / playerSound / playerStep) and Howler's pannerAttr defaults.
KRUNKER_3D_VOLUME :: 0.55         // play3D multiplies every 3D volume by this constant.
KRUNKER_REF_DISTANCE :: 25        // play3D refDistance fallback (0x19); every weapon has refDist 25.
KRUNKER_ROLLOFF :: 1              // play3D rolloffFactor fallback; every weapon has rollOff 1.
KRUNKER_MAX_DISTANCE :: 10000     // Howler's default maxDistance; the inverse model ignores it.
KRUNKER_STEP_RANGE :: 170         // playerStep culls remote footsteps beyond 170 units (0xaa).

Audio_Listener :: struct {
	position, forward: shared.Vec3,
}

// Parameters handed from the game thread to the mixer thread.
Spatial_Params :: struct {
	spatial, stereo_source: bool,
	gain: f32,                 // Distance gain including Krunker's 3D volume.
	azimuth, elevation: f32,   // Degrees; WebAudio convention, +azimuth = right.
}

// One per voice. The node runs on miniaudio's mixer thread. It reads its
// parameters through a sequence lock and never allocates or blocks.
Spatial_Node :: struct {
	base: ma.node_base,
	sequence: u32,               // Odd while the game thread writes `pending`.
	pending: Spatial_Params,
	pending_reset: u32,          // Increments when a new sound starts on the voice.
	// Mixer-thread state.
	params: Spatial_Params,
	seen_reset: u32,
	mix: [4]f32,                 // outL = m0*inL + m1*inR, outR = m2*inL + m3*inR.
	primed: bool,
}

@(private="file") spatial_node_channels := [1]u32{2}
@(private="file") spatial_node_vtable := ma.node_vtable{
	onProcess = spatial_node_process,
	inputBusCount = 1,
	outputBusCount = 1,
}

spatial_node_init :: proc(engine: ^ma.engine, node: ^Spatial_Node) -> bool {
	config := ma.node_config_init()
	config.vtable = &spatial_node_vtable
	config.pInputChannels = &spatial_node_channels[0]
	config.pOutputChannels = &spatial_node_channels[0]
	if ma.node_init(ma.engine_get_node_graph(engine), &config, nil, cast(^ma.node)node) != .SUCCESS { return false }
	if ma.node_attach_output_bus(cast(^ma.node)node, 0, ma.engine_get_endpoint(engine), 0) != .SUCCESS {
		ma.node_uninit(cast(^ma.node)node, nil)
		return false
	}
	node.primed = true
	return true
}

spatial_node_uninit :: proc(node: ^Spatial_Node) {
	if !node.primed { return }
	ma.node_uninit(cast(^ma.node)node, nil)
	node.primed = false
}

spatial_node_publish :: proc(node: ^Spatial_Node, params: Spatial_Params, reset: bool) {
	sync.atomic_add_explicit(&node.sequence, 1, .Acq_Rel)
	node.pending = params
	if reset { node.pending_reset += 1 }
	sync.atomic_add_explicit(&node.sequence, 1, .Release)
}

@(private="file")
spatial_node_read :: proc "contextless" (node: ^Spatial_Node) -> (params: Spatial_Params, reset: u32, ok: bool) {
	// The writer holds the lock for a few stores; a short bounded retry keeps a
	// freshly started sound from playing one block with its predecessor's pose.
	for _ in 0 ..< 16 {
		before := sync.atomic_load_explicit(&node.sequence, .Acquire)
		if before & 1 != 0 { continue }
		params = node.pending
		reset = node.pending_reset
		sync.atomic_thread_fence(.Acquire)
		if sync.atomic_load_explicit(&node.sequence, .Relaxed) == before { return params, reset, true }
	}
	return
}

// WebAudio PannerNode::CalculateAzimuthElevation, using the listener's
// forward vector and Howler's +Y up vector.
audio_azimuth_elevation :: proc "contextless" (listener: Audio_Listener, position: shared.Vec3) -> (azimuth, elevation: f32) {
	normalize :: proc "contextless" (v: shared.Vec3) -> shared.Vec3 {
		length := math.sqrt(v.x*v.x + v.y*v.y + v.z*v.z)
		return length > 0 ? v / length : v
	}
	cross :: proc "contextless" (a, b: shared.Vec3) -> shared.Vec3 { return {a.y*b.z - a.z*b.y, a.z*b.x - a.x*b.z, a.x*b.y - a.y*b.x} }
	dot :: proc "contextless" (a, b: shared.Vec3) -> f32 { return a.x*b.x + a.y*b.y + a.z*b.z }
	source := position - listener.position
	if source == {} { return 0, 0 }
	source = normalize(source)
	forward := normalize(listener.forward)
	right := normalize(cross(listener.forward, {0, 1, 0}))
	up := cross(right, forward)
	projected := normalize(source - up*dot(source, up))
	az := math.to_degrees(math.acos(clamp(dot(projected, right), -1, 1)))
	if dot(projected, forward) < 0 { az = 360 - az }
	azimuth = az >= 0 && az <= 270 ? 90 - az : 450 - az
	elevation = 90 - math.to_degrees(math.acos(clamp(dot(source, up), -1, 1)))
	if elevation > 90 { elevation = 180 - elevation } else if elevation < -90 { elevation = -180 - elevation }
	return
}

// WebAudio "inverse" distance model (Krunker/Howler default).
audio_inverse_distance_gain :: proc "contextless" (distance, ref_distance, rolloff: f32) -> f32 {
	if ref_distance <= 0 { return 0 }
	d := max(distance, ref_distance)
	return ref_distance / (ref_distance + rolloff*(d - ref_distance))
}

// WebAudio equal-power panning for mono and stereo sources. Rear azimuths are
// mirrored to the front exactly as the browser does.
audio_equal_power_matrix :: proc "contextless" (azimuth: f32, stereo_source: bool) -> [4]f32 {
	az := clamp(azimuth, -180, 180)
	if az < -90 { az = -180 - az } else if az > 90 { az = 180 - az }
	if !stereo_source {
		x := (az + 90) / 180
		return {math.cos(x * math.PI / 2), 0, math.sin(x * math.PI / 2), 0}
	}
	if az <= 0 {
		x := (az + 90) / 90
		return {1, math.cos(x * math.PI / 2), 0, math.sin(x * math.PI / 2)}
	}
	x := az / 90
	return {math.cos(x * math.PI / 2), 0, math.sin(x * math.PI / 2), 1}
}

@(private="file")
spatial_target_matrix :: proc "contextless" (params: Spatial_Params) -> [4]f32 {
	if !params.spatial { return {1, 0, 0, 1} }
	m := audio_equal_power_matrix(params.azimuth, params.stereo_source)
	return m * params.gain
}

@(private="file")
spatial_node_process :: proc "c" (base: ^ma.node, frames_in: ^[^]f32, frame_count_in: ^u32, frames_out: ^[^]f32, frame_count_out: ^u32) {
	context = runtime.default_context()
	node := cast(^Spatial_Node)base
	input, output := frames_in^, frames_out^
	count := int(frame_count_out^)
	if params, reset, ok := spatial_node_read(node); ok {
		node.params = params
		if reset != node.seen_reset {
			node.seen_reset = reset
			node.mix = spatial_target_matrix(params)
		}
	}
	target := spatial_target_matrix(node.params)
	if !node.params.spatial && node.mix == target {
		copy(output[:count*2], input[:count*2])
		return
	}
	start := node.mix
	step := count > 0 ? (target - start) / f32(count) : {}
	m := start
	for i in 0 ..< count {
		m += step
		l, r := input[i*2], input[i*2+1]
		output[i*2] = m[0]*l + m[1]*r
		output[i*2+1] = m[2]*l + m[3]*r
	}
	node.mix = target
}
