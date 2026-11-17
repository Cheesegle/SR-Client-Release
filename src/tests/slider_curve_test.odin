package main

import "core:fmt"
import "core:math"
import menuui "../menu"

// Curved crosshair sliders: small values get more of the bar, drags snap to
// the step, and linear sliders behave exactly as before.
test_slider_curve :: proc() -> bool {
	near :: proc(a, b: f32) -> bool { return abs(a - b) < 0.0005 }

	// Linear (curve 1): no curve, only the slider's one decimal.
	if !near(menuui.slider_value_at(0.4321, 0, 100, 1, 0.5), 43.2) || !near(menuui.slider_progress(25, 0, 100, 1), 0.25) {
		fmt.println("Linear slider mapping changed"); return false
	}

	// Thickness / size (0-100, curve 2): the first 20% of the bar covers 0-4,
	// so 1 -> 1.5 now takes 2.2% of the bar instead of 0.5%.
	if !near(menuui.slider_value_at(0.2, 0, 100, 2, 0.1), 4) || !near(menuui.slider_value_at(0.5, 0, 100, 2, 0.1), 25) {
		fmt.println("Curved slider mapping failed"); return false
	}
	span_old := menuui.slider_progress(1.5, 0, 100, 1) - menuui.slider_progress(1, 0, 100, 1)
	span_new := menuui.slider_progress(1.5, 0, 100, 2) - menuui.slider_progress(1, 0, 100, 2)
	if span_new < span_old * 4 {
		fmt.println("Curve does not give small values enough room", span_old, span_new); return false
	}

	// Drags snap to the 0.1 step, and every step value round-trips.
	if !near(menuui.slider_value_at(0.11, 0, 100, 2, 0.1), 1.2) {
		fmt.println("Curved drag did not snap to 0.1", menuui.slider_value_at(0.11, 0, 100, 2, 0.1)); return false
	}
	for i in 0 ..= 200 {
		v := f32(i) * 0.1
		back := menuui.slider_value_at(menuui.slider_progress(v, 0, 100, 2), 0, 100, 2, 0.1)
		if !near(back, v) { fmt.println("Curved slider round trip failed", v, back); return false }
	}

	// Gap (-100..100) curves symmetrically around zero.
	if !near(menuui.slider_progress(0, -100, 100, 2), 0.5) || !near(menuui.slider_value_at(0.5, -100, 100, 2, 0.5), 0) {
		fmt.println("Signed slider is not centred on zero"); return false
	}
	if !near(menuui.slider_value_at(0.6, -100, 100, 2, 0.5), 4) || !near(menuui.slider_value_at(0.4, -100, 100, 2, 0.5), -4) {
		fmt.println("Signed slider is not symmetric"); return false
	}
	for v in ([]f32{-100, -12.5, -0.5, 0, 0.5, 3, 100}) {
		back := menuui.slider_value_at(menuui.slider_progress(v, -100, 100, 2), -100, 100, 2, 0.5)
		if !near(back, v) { fmt.println("Signed slider round trip failed", v, back); return false }
	}

	// Ends stay reachable and clamped.
	if !near(menuui.slider_value_at(0, 0, 100, 2, 0.1), 0) || !near(menuui.slider_value_at(1, 0, 100, 2, 0.1), 100) || math.is_nan(menuui.slider_progress(5, 0, 0, 2)) {
		fmt.println("Slider ends are wrong"); return false
	}
	fmt.println("Crosshair slider curve tests OK")
	return true
}
