package main

import "core:testing"
import "core:math"
import shared "../shared"

// Krunker's server lets a weapon fire on the first command after which the
// summed whole-ms command durations reach the cooldown (t-=u until t<=0),
// counted in f64 ms. SR must pick exactly the same command for every weapon
// time, input rate and fire-rate multiplier, including non-integer results
// such as 450 * 0.9 = 405 or 95 * 1.15 = 109.25.
@(test)
weapon_timers_fire_on_krunkers_command :: proc(t: ^testing.T) {
	// Whole-ms durations at 120/240/480/720/840/1000 inputs/s (and 360).
	patterns := [][]int{{8, 8, 9}, {4, 4, 5}, {3, 3, 2}, {2, 2, 2, 3}, {1, 2}, {1, 1, 2, 1, 1, 1, 2}, {1}}
	rates_ms := []int{45, 60, 70, 95, 100, 115, 120, 125, 150, 175, 200, 225, 300, 400, 450, 500, 600, 700, 900, 1000, 1200, 1500}
	multipliers := []f32{1, 0.9, 1.15, 0.5, 2, 0.75}
	for pattern in patterns {
		for rate_ms in rates_ms {
			for mult in multipliers {
				cooldown_js := f64(rate_ms) * math.round(f64(mult) * 1e6) / 1e6
				// Reference: count commands in plain f64 ms like game.min.js.
				reference := 0
				{
					remaining := cooldown_js
					for remaining > 0 {
						remaining -= f64(pattern[reference % len(pattern)])
						reference += 1
					}
				}
				// SR: registry seconds -> ms, stepped with the shared helpers.
				timer := shared.weapon_seconds_to_ms(f32(rate_ms) / 1000) * shared.weapon_timer_multiplier(mult)
				commands := 0
				for timer > 0 && commands < 10000 {
					shared.weapon_timer_tick(&timer, shared.input_delta_ms(f32(pattern[commands % len(pattern)]) / 1000))
					commands += 1
				}
				testing.expectf(t, commands == reference, "rate %d ms x%v with %v: SR ready after %d commands, Krunker after %d", rate_ms, mult, pattern, commands, reference)
			}
		}
	}
}
