package main

import "core:fmt"
import "core:math"
import "core:testing"
import "core:time"

when ODIN_TEST {
	@(test)
	hrtf_table_loads :: proc(t: ^testing.T) {
		if !testing.expect(t, hrtf_load(), "the embedded HRTF table must load") { return }
		defer hrtf_unload()
		testing.expect(t, len(g_hrtf.spectra) == HRTF_ELEVATIONS * HRTF_AZIMUTHS * 2)
		// The browser's index math: +90 (right) maps to database azimuth 270.
		index, blend := hrtf_azimuth_index(90)
		testing.expect(t, index == 144 && blend == 0, "azimuth +90 must use the 270 degree kernels")
		index, _ = hrtf_azimuth_index(-90)
		testing.expect(t, index == 48)
		testing.expect(t, hrtf_elevation_index(0) == 3 && hrtf_elevation_index(-80) == 0 && hrtf_elevation_index(89) == 8 && hrtf_elevation_index(120) == 9)
	}

	// An impulse comes out as the ear's kernel, after the ear delay and the
	// convolver's 256-frame latency, with the kernel's energy.
	@(test)
	hrtf_impulse_is_the_kernel :: proc(t: ^testing.T) {
		if !testing.expect(t, hrtf_load()) { return }
		defer hrtf_unload()
		state: Hrtf_State
		hrtf_reset(&state)
		state.gain = 1
		frames :: 2048
		input, output: [frames*2]f32
		input[0], input[1] = 1, 1
		hrtf_process(&state, input[:], output[:], frames, 90, 0, 1, false)
		kernel := g_hrtf.spectra[(3 * HRTF_AZIMUTHS + 144) * 2 + 1] // right ear, 270 degrees
		expected_energy: f64
		for k in 0 ..< HRTF_BINS {
			m := f64(abs(kernel[k]))
			expected_energy += (k == 0 || k == HRTF_HALF ? 1 : 2) * m * m
		}
		expected_energy /= HRTF_FFT
		energy: [2]f64
		first: [2]int = {-1, -1}
		for i in 0 ..< frames {
			for ear in 0 ..< 2 {
				v := f64(output[i*2 + ear])
				energy[ear] += v * v
				if first[ear] < 0 && abs(v) > 1e-4 { first[ear] = i }
			}
		}
		// The fractional ear delay is read with linear interpolation, as in
		// the browser, which softens the highest frequencies of an impulse.
		testing.expectf(t, energy[1] < expected_energy && energy[1] > 0.65 * expected_energy, "right ear energy %.4f, kernel %.4f", energy[1], expected_energy)
		testing.expectf(t, energy[1] > 10 * energy[0], "a source on the right is far louder in the right ear (%.4f vs %.4f)", energy[1], energy[0])
		testing.expectf(t, first[1] >= HRTF_HALF && first[0] > first[1], "the near ear hears it first, after the convolver latency (%v)", first)
	}

	// Cost on the mixer thread: one positional voice whose direction changes
	// every render quantum (always crossfading, the worst case).
	@(test)
	hrtf_cost_per_voice :: proc(t: ^testing.T) {
		if !testing.expect(t, hrtf_load()) { return }
		defer hrtf_unload()
		state: Hrtf_State
		hrtf_reset(&state)
		block :: 480
		input, output: [block*2]f32
		for i in 0 ..< block { input[i*2] = f32(math.sin(f64(i) * 0.3)); input[i*2+1] = input[i*2] }
		seconds :: 2
		start := time.tick_now()
		for b in 0 ..< seconds * 48000 / block {
			hrtf_process(&state, input[:], output[:], block, f32(b % 360) - 180, f32(b % 90) - 30, 0.5, false)
		}
		elapsed := time.duration_seconds(time.tick_since(start)) / seconds
		fmt.printfln("[HRTF] %.2f ms of mixer time per second of audio per crossfading voice", elapsed * 1000)
		// Release builds (-o:aggressive) measure about 0.5%; unoptimized test builds ~5-8%.
		limit := ODIN_OPTIMIZATION_MODE == .None ? 0.25 : 0.03
		testing.expectf(t, elapsed < limit, "one voice must stay a small part of a core (%.3f)", elapsed)
	}
}
