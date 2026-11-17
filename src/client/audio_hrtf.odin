package main

import "core:math"

// Krunker's positional sounds go through Howler's spatial plugin, whose
// PannerNode uses panningModel "HRTF" (Howler's default; Krunker never
// changes it). This is the browser's HRTF panner (WebKit/Chromium
// HRTFPanner): per ear a frame delay and a 256-frame head-related impulse
// response from the IRCAM "Composite" subject, picked by azimuth (1.875
// degree steps) and elevation (15 degree steps), with a 2048-frame crossfade
// whenever the direction changes. tools/hrtf/build_hrtf.py prepares the
// kernels exactly as the browser does at 48 kHz.

HRTF_ELEVATIONS :: 10        // -45..90 in 15 degree steps.
HRTF_AZIMUTHS :: 192         // 24 measured azimuths x 8 (interpolated).
HRTF_KERNEL_FRAMES :: 256
HRTF_FFT :: 512              // HRTFPanner::FftSizeForSampleRate(48000).
HRTF_HALF :: HRTF_FFT / 2
HRTF_BINS :: HRTF_HALF + 1
HRTF_SEGMENT :: 128          // WebAudio render quantum.
HRTF_FADE_FRAMES :: 2048     // Crossfade length at <= 48 kHz.
HRTF_DELAY_RING :: 128       // > 2 ms (the panner's maximum delay) at 48 kHz.
HRTF_IDLE_FRAMES :: 2048     // Silence after which a voice's tail is gone.

HRTF_DATA :: #load("data/hrtf_48k.bin")

Hrtf_Database :: struct {
	ready: bool,
	users: int, // Audio systems using the table; freed after the last one.
	delays: [HRTF_ELEVATIONS][HRTF_AZIMUTHS][2]f32,
	spectra: [][HRTF_BINS]complex64, // ((elevation * HRTF_AZIMUTHS) + azimuth) * 2 + ear
}
g_hrtf: Hrtf_Database

// Two convolvers (left and right ear) that share their timing, computed with
// one complex FFT: the left input is the real part, the right the imaginary.
Hrtf_Convolver_Pair :: struct {
	input: [2][HRTF_HALF]f32,
	output: [2][HRTF_FFT]f32,
	overlap: [2][HRTF_HALF]f32,
	position: int,
}

Hrtf_State :: struct {
	delay: [2][HRTF_DELAY_RING]f32,
	delay_write: int,
	pairs: [2]Hrtf_Convolver_Pair,
	azimuth_index: [2]int, // -1 until the first segment.
	elevation: [2]f32,
	crossfade_x, crossfade_incr: f32,
	selection: int, // 0 or 1: which convolver pair is heard when not fading.
	segment_position: int,
	frame_delay: [2]f32,
	kernels: [2][2]int, // [pair][ear] index into g_hrtf.spectra
	idle_frames: int,
	gain: f32,
}

@(private="file") hrtf_twiddles: [HRTF_FFT/2]complex64
@(private="file") hrtf_bit_reverse: [HRTF_FFT]u16

hrtf_fft_init :: proc() {
	bits: uint = 9
	for i in 0 ..< HRTF_FFT {
		r := 0
		for b in 0 ..< bits { if i & (1 << b) != 0 { r |= 1 << (bits - 1 - b) } }
		hrtf_bit_reverse[i] = u16(r)
	}
	for k in 0 ..< HRTF_FFT/2 {
		angle := -2 * math.PI * f64(k) / HRTF_FFT
		hrtf_twiddles[k] = complex(f32(math.cos(angle)), f32(math.sin(angle)))
	}
}

// In-place radix-2 FFT of HRTF_FFT points; inverse is unscaled.
hrtf_fft :: proc "contextless" (data: ^[HRTF_FFT]complex64, inverse: bool) {
	for i in 0 ..< HRTF_FFT {
		j := int(hrtf_bit_reverse[i])
		if j > i { data[i], data[j] = data[j], data[i] }
	}
	for size := 2; size <= HRTF_FFT; size *= 2 {
		half := size / 2
		step := HRTF_FFT / size
		for start := 0; start < HRTF_FFT; start += size {
			for k in 0 ..< half {
				w := hrtf_twiddles[k * step]
				if inverse { w = conj(w) }
				a := data[start + k]
				b := data[start + k + half] * w
				data[start + k] = a + b
				data[start + k + half] = a - b
			}
		}
	}
}

hrtf_load :: proc() -> bool {
	if g_hrtf.ready { g_hrtf.users += 1; return true }
	data := HRTF_DATA
	header :: 24
	delay_bytes :: HRTF_ELEVATIONS * HRTF_AZIMUTHS * 2 * 4
	kernel_bytes :: HRTF_ELEVATIONS * HRTF_AZIMUTHS * 2 * HRTF_KERNEL_FRAMES * 4
	if len(data) != header + delay_bytes + kernel_bytes || string(data[:8]) != "SRHRTF1\x00" { return false }
	read_u32 :: proc(data: []byte, at: int) -> u32 { return u32(data[at]) | u32(data[at+1]) << 8 | u32(data[at+2]) << 16 | u32(data[at+3]) << 24 }
	if read_u32(data, 8) != HRTF_ELEVATIONS || read_u32(data, 12) != HRTF_AZIMUTHS || read_u32(data, 16) != HRTF_KERNEL_FRAMES || read_u32(data, 20) != 48000 { return false }
	read_f32 :: proc(data: []byte, at: int) -> f32 { return transmute(f32)read_u32(data, at) }
	hrtf_fft_init()
	at := header
	for e in 0 ..< HRTF_ELEVATIONS { for a in 0 ..< HRTF_AZIMUTHS { for ear in 0 ..< 2 {
		g_hrtf.delays[e][a][ear] = read_f32(data, at)
		at += 4
	} } }
	g_hrtf.spectra = make([][HRTF_BINS]complex64, HRTF_ELEVATIONS * HRTF_AZIMUTHS * 2)
	buffer: [HRTF_FFT]complex64
	for &spectrum in g_hrtf.spectra {
		for i in 0 ..< HRTF_FFT { buffer[i] = 0 }
		for i in 0 ..< HRTF_KERNEL_FRAMES {
			buffer[i] = complex(read_f32(data, at), 0)
			at += 4
		}
		hrtf_fft(&buffer, false)
		for i in 0 ..< HRTF_BINS { spectrum[i] = buffer[i] }
	}
	g_hrtf.ready, g_hrtf.users = true, 1
	return true
}

// Call after the engine using the table has stopped mixing.
hrtf_unload :: proc() {
	if !g_hrtf.ready { return }
	g_hrtf.users -= 1
	if g_hrtf.users > 0 { return }
	delete(g_hrtf.spectra)
	g_hrtf = {}
}

hrtf_reset :: proc "contextless" (state: ^Hrtf_State) {
	state^ = {}
	state.azimuth_index = {-1, -1}
}

// HRTFPanner::CalculateDesiredAzimuthIndexAndBlend for the WebAudio azimuth
// (+ = right); the database's azimuths run the other way.
hrtf_azimuth_index :: proc "contextless" (desired_azimuth: f32) -> (index: int, blend: f32) {
	azimuth := -clamp(desired_azimuth, -180, 180)
	if azimuth < 0 { azimuth += 360 }
	position := azimuth / (360.0 / HRTF_AZIMUTHS)
	index = int(position)
	blend = position - f32(index)
	index = clamp(index, 0, HRTF_AZIMUTHS - 1)
	return
}

hrtf_elevation_index :: proc "contextless" (elevation: f32) -> int {
	return min(int((clamp(elevation, -45, 90) + 45) / 15), HRTF_ELEVATIONS - 1)
}

// HRTFElevation::GetKernelsFromAzimuth: the kernel at the index, frame delays
// blended toward the next azimuth.
@(private="file")
hrtf_kernels :: proc "contextless" (blend: f32, azimuth_index: int, elevation: f32) -> (kernels: [2]int, delays: [2]f32) {
	e := hrtf_elevation_index(elevation)
	next := (azimuth_index + 1) % HRTF_AZIMUTHS
	for ear in 0 ..< 2 {
		kernels[ear] = (e * HRTF_AZIMUTHS + azimuth_index) * 2 + ear
		a, b := g_hrtf.delays[e][azimuth_index][ear], g_hrtf.delays[e][next][ear]
		delays[ear] = a + (b - a) * blend
	}
	return
}

@(private="file")
hrtf_begin_segment :: proc "contextless" (state: ^Hrtf_State, azimuth, elevation: f32) {
	index, blend := hrtf_azimuth_index(azimuth)
	for i in 0 ..< 2 { if state.azimuth_index[i] < 0 { state.azimuth_index[i], state.elevation[i] = index, elevation } }
	if state.crossfade_x == 0 && state.selection == 0 && (index != state.azimuth_index[0] || elevation != state.elevation[0]) {
		state.crossfade_incr = 1.0 / HRTF_FADE_FRAMES
		state.azimuth_index[1], state.elevation[1] = index, elevation
	}
	if state.crossfade_x == 1 && state.selection == 1 && (index != state.azimuth_index[1] || elevation != state.elevation[1]) {
		state.crossfade_incr = -1.0 / HRTF_FADE_FRAMES
		state.azimuth_index[0], state.elevation[0] = index, elevation
	}
	kernels0, delays0 := hrtf_kernels(blend, state.azimuth_index[0], state.elevation[0])
	kernels1, delays1 := hrtf_kernels(blend, state.azimuth_index[1], state.elevation[1])
	state.kernels = {kernels0, kernels1}
	x := state.crossfade_x
	for ear in 0 ..< 2 { state.frame_delay[ear] = (1 - x) * delays0[ear] + x * delays1[ear] }
}

@(private="file")
hrtf_end_segment :: proc "contextless" (state: ^Hrtf_State) {
	if state.crossfade_incr > 0 && abs(state.crossfade_x - 1) < state.crossfade_incr {
		state.selection, state.crossfade_x, state.crossfade_incr = 1, 1, 0
	} else if state.crossfade_incr < 0 && abs(state.crossfade_x) < -state.crossfade_incr {
		state.selection, state.crossfade_x, state.crossfade_incr = 0, 0, 0
	}
}

// FFTConvolver::Process for both ears: 256 frames in, then one FFT.
@(private="file")
hrtf_convolve :: proc "contextless" (pair: ^Hrtf_Convolver_Pair, kernels: [2]int, left, right: f32) -> (out_left, out_right: f32) {
	out_left, out_right = pair.output[0][pair.position], pair.output[1][pair.position]
	pair.input[0][pair.position], pair.input[1][pair.position] = left, right
	pair.position += 1
	if pair.position < HRTF_HALF { return }
	pair.position = 0
	buffer: [HRTF_FFT]complex64
	for i in 0 ..< HRTF_HALF { buffer[i] = complex(pair.input[0][i], pair.input[1][i]) }
	hrtf_fft(&buffer, false)
	spectrum_left, spectrum_right := &g_hrtf.spectra[kernels[0]], &g_hrtf.spectra[kernels[1]]
	product: [HRTF_FFT]complex64
	for k in 0 ..< HRTF_FFT {
		mirror := conj(buffer[(HRTF_FFT - k) % HRTF_FFT])
		x_left := (buffer[k] + mirror) * 0.5
		x_right := (buffer[k] - mirror) * complex64(complex(0, -0.5))
		h_left := k <= HRTF_HALF ? spectrum_left[k] : conj(spectrum_left[HRTF_FFT - k])
		h_right := k <= HRTF_HALF ? spectrum_right[k] : conj(spectrum_right[HRTF_FFT - k])
		product[k] = x_left * h_left + complex64(complex(0, 1)) * (x_right * h_right)
	}
	hrtf_fft(&product, true)
	scale: f32 = 1.0 / HRTF_FFT
	for i in 0 ..< HRTF_FFT {
		pair.output[0][i] = real(product[i]) * scale
		pair.output[1][i] = imag(product[i]) * scale
	}
	for ear in 0 ..< 2 {
		for i in 0 ..< HRTF_HALF { pair.output[ear][i] += pair.overlap[ear][i] }
		for i in 0 ..< HRTF_HALF { pair.overlap[ear][i] = pair.output[ear][HRTF_HALF + i] }
	}
	return
}

// Delay line read with linear interpolation (the panner's delay kernels).
@(private="file")
hrtf_delay_read :: proc "contextless" (state: ^Hrtf_State, ear: int, frames: f32) -> f32 {
	position := f32(state.delay_write) - frames
	for position < 0 { position += HRTF_DELAY_RING }
	first := int(position)
	fraction := position - f32(first)
	a := state.delay[ear][first % HRTF_DELAY_RING]
	b := state.delay[ear][(first + 1) % HRTF_DELAY_RING]
	return a + (b - a) * fraction
}

// Pans interleaved stereo input (a mono sound has equal channels) into
// interleaved stereo output, scaled by a gain that ramps from the last call.
hrtf_process :: proc "contextless" (state: ^Hrtf_State, input, output: []f32, count: int, azimuth, elevation, gain: f32, stereo_source: bool) {
	silent := true
	for i in 0 ..< count*2 { if input[i] != 0 { silent = false; break } }
	if silent {
		state.idle_frames += count
		if state.idle_frames > HRTF_IDLE_FRAMES {
			for i in 0 ..< count*2 { output[i] = 0 }
			state.gain = gain
			return
		}
	} else { state.idle_frames = 0 }
	start_gain := state.gain
	gain_step := count > 0 ? (gain - start_gain) / f32(count) : 0
	for i in 0 ..< count {
		if state.segment_position == 0 { hrtf_begin_segment(state, azimuth, elevation) }
		left, right := input[i*2], input[i*2+1]
		if !stereo_source { right = left }
		state.delay[0][state.delay_write], state.delay[1][state.delay_write] = left, right
		delayed_left := hrtf_delay_read(state, 0, state.frame_delay[0])
		delayed_right := hrtf_delay_read(state, 1, state.frame_delay[1])
		state.delay_write = (state.delay_write + 1) % HRTF_DELAY_RING
		fading := state.crossfade_incr != 0
		l0, r0, l1, r1: f32
		if state.selection == 0 || fading { l0, r0 = hrtf_convolve(&state.pairs[0], state.kernels[0], delayed_left, delayed_right) }
		if state.selection == 1 || fading { l1, r1 = hrtf_convolve(&state.pairs[1], state.kernels[1], delayed_left, delayed_right) }
		out_left, out_right: f32
		if fading {
			x := state.crossfade_x
			out_left, out_right = (1 - x) * l0 + x * l1, (1 - x) * r0 + x * r1
			state.crossfade_x += state.crossfade_incr
		} else if state.selection == 0 {
			out_left, out_right = l0, r0
		} else {
			out_left, out_right = l1, r1
		}
		g := start_gain + gain_step * f32(i + 1)
		output[i*2], output[i*2+1] = out_left * g, out_right * g
		state.segment_position += 1
		if state.segment_position == HRTF_SEGMENT {
			state.segment_position = 0
			hrtf_end_segment(state)
		}
	}
	state.gain = gain
}
