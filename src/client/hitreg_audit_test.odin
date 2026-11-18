package main

import "core:testing"
import kproto "../krunker"

// A Desert Eagle fires every 0.45 s; at 100 ms ping the second shot's hit
// arrives inside the first shot's 0.6 s window. It must stay with the second.
@(test)
hitreg_confirmation_goes_to_the_shot_that_fits_its_round_trip :: proc(t: ^testing.T) {
	saved := g_hitreg
	defer g_hitreg = saved
	g_hitreg = {}
	g_hitreg.pending[0].time = 10.0
	g_hitreg.pending[1].time = 10.45
	g_hitreg.count = 2
	world: kproto.Krunker_World_State
	world.ping, world.has_ping = 100, true
	testing.expect(t, hitreg_event_fits_later_shot(&world, 10.58, 10.0, 0), "a hit 130 ms after the second shot belongs to the second shot")
	testing.expect(t, !hitreg_event_fits_later_shot(&world, 10.13, 10.0, 0), "a hit 130 ms after the first shot (before the second) stays with the first")
	testing.expect(t, !hitreg_event_fits_later_shot(&world, 10.48, 10.0, 0), "the second shot is too recent to have caused a hit 30 ms after it")
}
