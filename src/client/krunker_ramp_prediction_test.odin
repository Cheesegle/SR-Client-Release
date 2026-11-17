package main

import "core:fmt"
import "core:math"
import "core:testing"
import shared "../shared"
import kproto "../krunker"

when ODIN_TEST {
	Krunker_Ramp_Run :: struct {
		corrections, ramp_ticks: int,
		max_error, max_y: f32,
	}

	// Live prediction against a simulated authoritative peer on one real ramp.
	// Commands go through the wire encoder; every l snapshot carries only the
	// fields Krunker sends and arrives `latency` commands after its ACK.
	krunker_test_ramp_run :: proc(t: ^testing.T, config: ^shared.Gameplay_Config, map_inst: ^shared.Map, ramp: ^shared.Object, side, jump_period, latency: int) -> (run: Krunker_Ramp_Run) {
		client: Client
		shared.game_configure(&client.game, &config.game, []^shared.Map{map_inst}, nil, config.weapons, config.classes)
		shared.game_init(&client.game, 0, 0, false)
		defer shared.game_destroy(&client.game)
		defer delete(client.predicted_inputs)
		defer krunker_ws_disconnect(&client.krunker)
		// Live comp lobbies in the log use fixed movement.
		client.game.config.fixed_movement = true
		client.me = shared.player_init(&client.game)
		shared.game_players_add(&client.game, client.me)
		shared.player_spawn(client.me, 2)
		client.me.is_you = true
		client.me.swap_timer = 0
		server := shared.player_init(&client.game)
		defer shared.player_destroy(server)
		shared.player_spawn(server, 2)
		server.swap_timer = 0
		client.krunker.spawned, client.krunker.bootstrapped = true, true
		client.krunker.input_sequence = 1

		// Approach from 15 units before the low end (side 0) or the high end.
		length := ramp.direction % 2 == 1 ? ramp.scale.z : ramp.scale.x
		heading := math.PI * 0.5 * f32(ramp.direction) + (side == 0 ? 0 : math.PI)
		back := length * 0.5 + 15
		start := shared.Vec3{ramp.position.x - back * math.cos(heading), ramp.position.y + (side == 0 ? 0.5 : ramp.scale.y + 0.5), ramp.position.z - back * math.sin(heading)}
		client.me.position, server.position = start, start
		client.me.last_position, server.last_position = start, start

		Pending_Snapshot :: struct { at: i32, snapshot: kproto.Krunker_World_Player }
		pending: [dynamic]Pending_Snapshot
		defer delete(pending)
		sync_revision: u64
		frames := 0
		for client.krunker.input_sequence < 1500 {
			// Native move 4 runs along -cos/-sin of (PI/2 - yaw); reverse halfway.
			theta := client.krunker.input_sequence < 750 ? heading : heading + math.PI
			frame := shared.Input{delta = 1.0 / 144, move_dir = 4, y_dir = shared.normalize_angle(math.PI / 2 - theta),
				jump = jump_period > 0 && frames % jump_period < 4}
			frames += 1
			krunker_client_predict_input(&client, &frame, 0)
			if client.me.on_ramp { run.ramp_ticks += 1 }
			if client.krunker.send_elapsed >= KRUNKER_SEND_SECONDS && len(client.krunker.input_commands) > 0 {
				ack := krunker_test_deliver_commands(t, &client, server)
				sync_revision += 1
				append(&pending, Pending_Snapshot{ack + i32(latency), {
					position = server.position, velocity = server.velocity, on_ground = server.on_ground,
					did_jump = server.did_jump, did_wall_jump = server.did_wall_jump, wall_jump_count = server.wall_jump_count,
					on_wall = i32(server.on_wall), on_ladder = server.on_ladder, on_terrain = server.on_terrain,
					slide_timer = server.slide_timer, can_slide = server.can_slide, can_slide_timer = server.can_slide_timer,
					crouch_val = server.crouch_val, aim_val = server.aim_val, weapon_slot = server.loadout_index,
					has_ack = true, ack_seq = ack, sync_revision = sync_revision,
				}})
			}
			for len(pending) > 0 && pending[0].at <= client.krunker.input_sequence {
				before := client.me.position
				krunker_client_apply_motion(&client, client.me, &pending[0].snapshot, false)
				ordered_remove(&pending, 0)
				d := client.me.position - before
				error := math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z)
				run.corrections += 1
				if error > run.max_error { run.max_error, run.max_y = error, d.y }
			}
		}
		return
	}

	// Snapshots omit rampFix. Reconciling with the newest prediction's value
	// grounded a player who had just left a ramp, so held jumps fired early and
	// later ACKs pulled the player back by several units of Y.
	@(test)
	krunker_ramp_reconciliation_converges :: proc(t: ^testing.T) {
		config := shared.config_load_gameplay()
		defer shared.config_destroy_gameplay(config)
		Case :: struct { map_name: string, position: shared.Vec3, direction: u8 }
		// Every Sandstorm orientation (d=0..3) plus Site's west ramp.
		cases := []Case{
			{"sandstorm_v3.json", {64, 13, -4}, 0}, {"sandstorm_v3.json", {-208, 33, 101}, 1},
			{"sandstorm_v3.json", {80, 33, -106}, 2}, {"sandstorm_v3.json", {-174, 33, -89}, 3},
			{"site.json", {-185, 33, -157}, 1},
		}
		worst: Krunker_Ramp_Run
		total_corrections, total_ramp_ticks := 0, 0
		for c in cases {
			path := shared.concat(shared.assets_path(), fmt.tprintf("maps/%s", c.map_name))
			map_inst, loaded := shared.map_load_from_file(path)
			delete(path)
			if !testing.expectf(t, loaded, "%s must load", c.map_name) { return }
			defer shared.map_destroy(map_inst)
			ramp: ^shared.Object
			for object in map_inst.objects { if object.ramp != nil && object.position == c.position { ramp = object } }
			if !testing.expectf(t, ramp != nil && ramp.direction == c.direction && ramp.collision_type == .BOX, "%s ramp %v (d=%d) must load", c.map_name, c.position, c.direction) { return }
			for side in 0 ..< 2 {
				for jump_period in ([]int{0, 37, 61, 97}) {
					for latency in ([]int{21, 72}) {
						run := krunker_test_ramp_run(t, config, map_inst, ramp, side, jump_period, latency)
						total_corrections += run.corrections
						total_ramp_ticks += run.ramp_ticks
						if run.max_error > worst.max_error {
							worst = run
							fmt.printf("%s ramp d=%d side=%d jump=%d latency=%d: correction %.4f (dy %.4f)\n", c.map_name, c.direction, side, jump_period, latency, run.max_error, run.max_y)
						}
					}
				}
			}
		}
		testing.expectf(t, total_ramp_ticks > 1000 && total_corrections > 500, "runs must cover ramps and many ACKs (ramp ticks %d, corrections %d)", total_ramp_ticks, total_corrections)
		testing.expectf(t, worst.max_error < 0.001, "a deterministic peer must never correct prediction on a ramp; worst %.4f (dy %.4f)", worst.max_error, worst.max_y)
	}
}
