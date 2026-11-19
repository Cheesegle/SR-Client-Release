package main

import "core:testing"
import "core:math"
import shared "../shared"

// Krunker's kill cam: camLookAt once at death, then per frame the camera turns
// by (angle difference) x ms x 0.0022 and flies (distance) x ms x 0.0012
// towards a spot 24 units short of the killer. Mouse turns fight a pull that
// grows with the angle.
@(test)
kill_cam_turns_and_flies_like_krunkers_cam_look_at :: proc(t: ^testing.T) {
	saved := g_death
	defer g_death = saved
	g_death = {active = true}
	client := new(Client); defer free(client)
	client.camera.position = {0, 10, 0}
	death_cam_look_at({0, 10, -100}, client.camera.position) // straight ahead (-z)
	testing.expect(t, g_death.has_target && abs(g_death.target_yaw) < 1e-5 && abs(g_death.target_position.z - (-76)) < 1e-3, "24 units short of the killer")
	// Turned 90 degrees away: one 10 ms frame pulls back 2.2% of the angle.
	client.camera.rotation.y = math.PI/2
	death_cam_update(client, 0.010)
	testing.expect(t, abs(client.camera.rotation.y - math.PI/2*(1 - 0.022)) < 1e-4, "turn = angle x ms x 0.0022")
	testing.expect(t, abs(client.camera.position.z - (-76*0.012)) < 1e-3, "fly = distance x ms x 0.0012")
	testing.expect(t, client.camera.zoom == 1, "Krunker's kill cam does not zoom")
	_ = shared.Vec3{}
}
