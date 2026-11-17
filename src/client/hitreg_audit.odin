package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:strings"
import shared "../shared"
import kproto "../krunker"

// Hit registration log (logs/hitreg.log), for live games, developer builds only.
//
// Krunker's server decides every hit with its own boxes (shared
// krunker_player_hurtboxes), rewound to the moment the shooter saw. For each
// of your shots this log records what SR showed you: whether the centre of
// your crosshair was on a player's Krunker boxes at the drawn pose, and at
// poses a little earlier and later, next to whether Krunker confirmed a hit.
// Over a few dozen shots this shows if (and by how much) what SR draws is
// ahead of or behind what the server tests.
//
// Performance: work happens only when you shoot (a few box tests); lines are
// written in batches. Nothing runs per frame except a timer check.

// Developer builds only (build.bat dev): release builds carry none of this.
HITREG_AUDIT :: #config(SR_HITREG_AUDIT, SR_DEV)
HITREG_LOG :: "logs/hitreg.log"
HITREG_CONFIRM_WINDOW :: 0.6 // seconds a server hit may arrive after the shot
HITREG_OFFSETS_MS := [?]i32{-150, -100, -75, -50, -25, 0, 25, 50, 75, 100, 150}
HITREG_MAX_PENDING :: 32

Hitreg_Shot :: struct {
	time:        f64,
	weapon:      string,
	aimed_sid:   i32,  // player under the crosshair at the drawn pose, -1 none
	aimed_part:  shared.Krunker_Hurtbox_Part,
	nearest_sid: i32,  // closest player to the ray when it missed
	miss:        f32,  // distance from the ray to that player's nearest box centre
	offsets:     [len(HITREG_OFFSETS_MS)]u8, // per offset: '.', 'H' head, 'B' body
	moving:      bool,
	target_speed: f32,
	target_step: f32,
	hits_seen:   int, // hit_event_next at shot time, to match confirmations
}

Hitreg_Audit :: struct {
	pending:     [HITREG_MAX_PENDING]Hitreg_Shot,
	count:       int,
	lines:       strings.Builder,
	last_hit_event: int,
	started:     bool,
	shots, predicted, confirmed, agreed: int,
}
g_hitreg: Hitreg_Audit

@(private = "file")
hitreg_ray_obb :: proc(origin, direction: shared.Vec3, transform: shared.Mat4) -> (f32, bool) {
	inverse := linalg.inverse(transform)
	o := inverse * shared.Vec4{origin.x, origin.y, origin.z, 1}
	d := inverse * shared.Vec4{direction.x, direction.y, direction.z, 0}
	t_min, t_max: f32 = 0, 1
	for axis in 0 ..< 3 {
		if abs(d[axis]) < 1e-8 {
			if o[axis] < -0.5 || o[axis] > 0.5 { return 0, false }
			continue
		}
		t1 := (-0.5 - o[axis]) / d[axis]
		t2 := (0.5 - o[axis]) / d[axis]
		if t1 > t2 { t1, t2 = t2, t1 }
		t_min, t_max = max(t_min, t1), min(t_max, t2)
		if t_min > t_max { return 0, false }
	}
	return t_min, true
}

@(private = "file")
hitreg_pose_at :: proc(source: ^kproto.Krunker_World_Player, time: f64) -> (pose: kproto.Krunker_World_Pose, ok: bool) {
	if source.history_count == 0 { return }
	n := len(source.history)
	oldest := (source.history_next - source.history_count + n) % n
	previous := source.history[oldest]
	if time <= previous.time { return previous, true }
	for i in 1 ..< source.history_count {
		current := source.history[(oldest + i) % n]
		if time <= current.time {
			span := current.time - previous.time
			alpha := span > 0 ? f32((time - previous.time) / span) : 1
			pose = current
			pose.position = previous.position + (current.position - previous.position) * alpha
			pose.direction.x = previous.direction.x + (current.direction.x - previous.direction.x) * alpha
			pose.direction.y = previous.direction.y + shared.normalize_angle(current.direction.y - previous.direction.y) * alpha
			pose.crouch = previous.crouch + (current.crouch - previous.crouch) * alpha
			return pose, true
		}
		previous = current
	}
	return previous, true
}

// The part of one player's Krunker boxes the ray hits first, if any.
@(private = "file")
hitreg_test :: proc(origin, direction: shared.Vec3, pose: shared.Krunker_Hurtbox_Pose) -> (part: shared.Krunker_Hurtbox_Part, t: f32, hit: bool) {
	boxes: [shared.KRUNKER_HURTBOX_MAX]shared.Krunker_Hurtbox
	count := shared.krunker_player_hurtboxes(pose, &boxes)
	t = 2
	for box in boxes[:count] {
		if distance, ok := hitreg_ray_obb(origin, direction, box.transform); ok && distance < t { t, part, hit = distance, box.part, true }
	}
	return
}

@(private = "file")
hitreg_miss_distance :: proc(origin, direction: shared.Vec3, pose: shared.Krunker_Hurtbox_Pose) -> f32 {
	boxes: [shared.KRUNKER_HURTBOX_MAX]shared.Krunker_Hurtbox
	count := shared.krunker_player_hurtboxes(pose, &boxes)
	best: f32 = 1e9
	length := linalg.length(direction)
	if length <= 0 { return best }
	unit := direction / length
	for box in boxes[:count] {
		center := (box.transform * shared.Vec4{0, 0, 0, 1}).xyz
		along := linalg.dot(center - origin, unit)
		if along < 0 { continue }
		best = min(best, linalg.length(center - (origin + unit * along)))
	}
	return best
}

// Called once per local shot in a live game (from the input that fired it).
hitreg_audit_shot :: proc(client: ^Client, now: f64) {
	when !HITREG_AUDIT { return }
	me := client.me
	if me == nil || me.weapon == nil || me.weapon.melee || !client.krunker.connected { return }
	world := &client.krunker_world
	shot := Hitreg_Shot{time = now, weapon = me.weapon.name, aimed_sid = -1, nearest_sid = -1, miss = 1e9, hits_seen = world.hit_event_next}
	for &c in shot.offsets { c = '.' }
	range := me.weapon.range > 0 ? me.weapon.range : 1000
	origin := shared.Vec3{me.position.x, me.position.y + me.height - shared.GAME_CONSTANTS.camera_height, me.position.z}
	// The crosshair: view direction plus the recoil kick (the camera and
	// Krunker's shot ray both include recoilAnimY * recoilMlt).
	angles := shared.player_hitscan_angles(me, -1)
	direction := shared.Vec3{
		range * math.sin(angles.y + math.PI) * math.cos(angles.x),
		range * math.sin(angles.x),
		range * math.cos(angles.y + math.PI) * math.cos(angles.x),
	}
	display_time := kproto.krunker_display_time(now, world.send_rate)
	best_t: f32 = 2
	for &source in world.players {
		if source.sid == world.local_sid || !source.active || source.life_ended { continue }
		if world.local_sid >= 0 && source.team != 0 && client.lobby_team != 0 && source.team == client.lobby_team { continue }
		player := client_find_player(client, source.sid)
		if player == nil || !player.active { continue }
		// What SR drew this frame.
		speed := linalg.length(player.position.xz - player.last_position.xz)
		pose := shared.krunker_hurtbox_pose(player, speed > 0.0001)
		if part, t, hit := hitreg_test(origin, direction, pose); hit && t < best_t {
			best_t, shot.aimed_sid, shot.aimed_part = t, source.sid, part
			shot.moving, shot.target_speed, shot.target_step = pose.moving, speed, source.server_step
		}
		if miss := hitreg_miss_distance(origin, direction, pose); miss < shot.miss {
			shot.miss, shot.nearest_sid = miss, source.sid
			if shot.aimed_sid < 0 { shot.moving, shot.target_speed, shot.target_step = pose.moving, speed, source.server_step }
		}
		// The same player at other times: would the shot hit if SR drew them
		// earlier (-) or later (+)?
		for offset, i in HITREG_OFFSETS_MS {
			sample, ok := hitreg_pose_at(&source, display_time + f64(offset) / 1000)
			if !ok { continue }
			moved := pose
			moved.position, moved.yaw, moved.pitch = sample.position, sample.direction.y, sample.direction.x
			moved.crouch = math.round(clamp(sample.crouch, 0, 1))
			if part, _, hit := hitreg_test(origin, direction, moved); hit {
				shot.offsets[i] = part == .HEAD ? 'H' : 'B'
			}
		}
	}
	if g_hitreg.count == HITREG_MAX_PENDING { hitreg_audit_resolve(client, now, true) }
	if g_hitreg.count < HITREG_MAX_PENDING {
		g_hitreg.pending[g_hitreg.count] = shot
		g_hitreg.count += 1
	}
}

// Every frame while connected: resolves shots older than the confirm window.
hitreg_audit_tick :: proc(client: ^Client, now: f64) {
	when !HITREG_AUDIT { return }
	if g_hitreg.count == 0 { return }
	if now - g_hitreg.pending[0].time < HITREG_CONFIRM_WINDOW { return }
	hitreg_audit_resolve(client, now, false)
}

@(private = "file")
hitreg_audit_resolve :: proc(client: ^Client, now: f64, all: bool) {
	world := &client.krunker_world
	if !g_hitreg.started {
		g_hitreg.lines = strings.builder_make()
		g_hitreg.started = true
		fmt.sbprintf(&g_hitreg.lines, "# SR Client hit registration log. One line per shot.\n# aimed: player/part under your crosshair as drawn (H head, B body, - none); server: Krunker's confirmation;\n# offsets %v ms: would the shot hit if the player were drawn that much earlier(-)/later(+)\n", HITREG_OFFSETS_MS)
	}
	resolved := 0
	for i in 0 ..< g_hitreg.count {
		shot := g_hitreg.pending[i]
		if !all && now - shot.time < HITREG_CONFIRM_WINDOW { break }
		server_sid: i32 = -1
		server_head := false
		for j in 0 ..< len(world.hit_events) {
			event := world.hit_events[j]
			if event.time >= shot.time - 0.001 && event.time - shot.time <= HITREG_CONFIRM_WINDOW && event.sid >= 0 {
				server_sid, server_head = event.sid, event.headshot
				world.hit_events[j].sid = -1 // one confirmation per shot
				break
			}
		}
		aimed := shot.aimed_sid >= 0
		g_hitreg.shots += 1
		if aimed { g_hitreg.predicted += 1 }
		if server_sid >= 0 { g_hitreg.confirmed += 1 }
		if aimed == (server_sid >= 0) { g_hitreg.agreed += 1 }
		fmt.sbprintf(&g_hitreg.lines, "t=%.3f %s aimed=%s server=%s target=%d moving=%v speed=%.3f step=%.2f miss=%.2f offsets=%s\n",
			shot.time, shot.weapon,
			aimed ? fmt.tprintf("%d%s", shot.aimed_sid, shot.aimed_part == .HEAD ? "H" : "B") : "-",
			server_sid >= 0 ? fmt.tprintf("%d%s", server_sid, server_head ? "H" : "B") : "-",
			aimed ? shot.aimed_sid : shot.nearest_sid, shot.moving, shot.target_speed, shot.target_step,
			shot.miss < 1e8 ? shot.miss : -1, string(shot.offsets[:]))
		resolved += 1
	}
	copy(g_hitreg.pending[:], g_hitreg.pending[resolved:g_hitreg.count])
	g_hitreg.count -= resolved
	if strings.builder_len(g_hitreg.lines) > 4096 || all { hitreg_audit_flush() }
}

// Writes buffered lines (also at disconnect and exit).
hitreg_audit_flush :: proc() {
	when !HITREG_AUDIT { return }
	if !g_hitreg.started || strings.builder_len(g_hitreg.lines) == 0 { return }
	_ = os.make_directory("logs")
	if file, err := os.open(HITREG_LOG, {.Write, .Create, .Append}); err == nil {
		os.write_string(file, strings.to_string(g_hitreg.lines))
		if g_hitreg.shots > 0 {
			os.write_string(file, fmt.tprintf("# so far: %d shots, crosshair on a player %d, server hits %d, agreed %d\n", g_hitreg.shots, g_hitreg.predicted, g_hitreg.confirmed, g_hitreg.agreed))
		}
		os.close(file)
	}
	strings.builder_reset(&g_hitreg.lines)
}
