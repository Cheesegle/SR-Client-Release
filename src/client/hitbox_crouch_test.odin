package main

import "core:testing"
import shared "../shared"

// Krunker's server rewinds a shot between the newest snapshot and the one before
// it but keeps the newest one's crouch, so SR's hit-test pose and the remote
// model must use that crouch, not the rounded in-between value.
@(test)
remote_crouch_follows_newest_snapshot :: proc(t: ^testing.T) {
	player: shared.Player
	player.crouch_val = 0.3 // drawn 30% of the way into a crouch
	player.server_crouch, player.server_crouch_valid = 1, true
	testing.expect_value(t, shared.krunker_hurtbox_pose(&player, false).crouch, 1)
	testing.expect_value(t, player_rig_crouch(&player), 1)
	player.server_crouch_valid = false
	testing.expect_value(t, shared.krunker_hurtbox_pose(&player, false).crouch, 0)
}
