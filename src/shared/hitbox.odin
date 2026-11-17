package shared

import "core:math"
import "core:math/linalg"

// Player hitbox geometry. SR Client's native/offline hit tests and the developer
// hitbox visualizer both read it from here, so what is drawn is what is hit.

// An axis-aligned box in ray_box_hit's convention: `origin` is the centre of
// the bottom face, `scale` the full size.
Box :: struct {
	origin: Vec3,
	scale:  Vec3,
}

// The two native hit tests use different player boxes: melee swings test a
// box 10% wider (body) / 12.5% wider (head) than hitscan shots do.
Hitbox_Kind :: enum u8 {
	SHOT,  // player_shoot
	MELEE, // player_melee (non-throw swing)
}

// SR Client's player hitboxes: a body box from the feet to 72% of the current
// height, and a head box on top of it up to the current height. Crouching
// shrinks both through `height` (player_update_height); nothing else (no
// hitbox padding, no head multiplier) changes them.
player_hitboxes :: proc(target: ^Player, kind := Hitbox_Kind.SHOT) -> (body, head: Box) {
	body_width, head_width: f32 = 2.0, 1.6
	if kind == .MELEE { body_width, head_width = 2.2, 1.8 }
	body_height := max(0.1, target.height * 0.72)
	body = {
		origin = {target.position.x, target.position.y, target.position.z},
		scale  = {target.scale * body_width, body_height, target.scale * body_width},
	}
	head_height := max(0.1, target.height - body_height)
	head = {
		origin = {target.position.x, target.position.y + body_height, target.position.z},
		scale  = {target.scale * head_width, head_height, target.scale * head_width},
	}
	return
}

// Unit-cube transform of a Box: maps [-0.5, 0.5]^3 onto it.
box_transform :: proc(box: Box) -> Mat4 {
	return linalg.matrix4_translate_f32(box.origin + Vec3{0, box.scale.y * 0.5, 0}) * linalg.matrix4_scale_f32(box.scale)
}

// The shot filter both native hitscan loops (player_shoot, player_melee) apply
// to map objects: only these stop a bullet.
map_object_blocks_shots :: proc(object: ^Object) -> bool {
	if object == nil { return false }
	return !(!object.active || object.no_shoot || object.collision_type == .NONE || object.score_zone || object.objective || object.team_zone || object.bomb_site || object.flag || object.trigger || object.premium || object.verified || object.teleporter || object.checkpoint || object.pickup)
}

// ---------------------------------------------------------------------------
// Krunker's live hitboxes ("complexHitboxes", Krunker's client updateComplexHitboxes,
// the per-shot pose update and the server ray test). On official servers every
// hitscan hit is decided by these oriented boxes, not by SR Client's two boxes:
//
//   root     at (x, y + |sin(sV) * stepAnim * 6|, z), yaw xD - 2 sin(sV) stepAnim
//   upper    at legHeight - crouchDst * cV above the root, pitched yD * 0.5
//     head   headScale^3 cube centred playerHeight - headScale/2 - legHeight up
//     torso  chestWidth x (playerHeight - headScale - legHeight) x chestScale
//     arms   3 boxes per arm (upper, elbow connector, forearm), IK to the
//            weapon's hold points, pitched another yD * 0.5 ("torsoshot")
//   legs     standing: legScale x legHeight x legScale per leg, swung by the
//            stride; crouched (cV = round(crouchVal)): 3 bent boxes per leg
//
// Every box grows by 1 unit on each side (before hurtboxScale) while the target
// is moving. The server rewinds the pose to the shooter's view (fetchState).

KRUNKER_HURTBOX_MAX :: 14

Krunker_Hurtbox_Part :: enum u8 { HEAD, TORSO, ARM, LEG }

// `transform` maps the unit cube [-0.5, 0.5]^3 onto the oriented box.
Krunker_Hurtbox :: struct {
	part:      Krunker_Hurtbox_Part,
	transform: Mat4,
}

Krunker_Hurtbox_Pose :: struct {
	position:      Vec3,
	yaw, pitch:    f32, // Krunker xD and yD (SR Client direction.y and direction.x).
	crouch:        f32, // Krunker's cV: 0 or 1.
	step_val:      f32, // sV
	step_chase:    f32,
	moving:        bool, // Target velocity non-zero: every box grows by 1.
	head_mlt:      f32, // Head-size multiplier (1 unless a mode grows heads).
	hurtbox_scale: f32, // Server hurtboxScale setting (1 by default).
	weapon:        ^Weapon, // Arm IK targets; nil leaves the arms out.
}

krunker_hurtbox_pose :: proc(player: ^Player, moving: bool) -> Krunker_Hurtbox_Pose {
	return {
		position = player.position,
		yaw = player.direction.y, pitch = player.direction.x,
		// The server keeps Math.round(crouchVal) in its pose history and rewinds
		// with the newest snapshot's crouch (fetchState keeps the newer cV).
		crouch = player.server_crouch_valid ? player.server_crouch : math.round(clamp(player.crouch_val, 0, 1)),
		step_val = player.server_step_valid ? player.server_step : player.step_val, step_chase = player.step_chase,
		moving = moving, head_mlt = 1, hurtbox_scale = 1,
		weapon = player.weapon,
	}
}

@(private="file")
euler_xyz :: proc(x, y, z: f32) -> Mat4 {
	return linalg.matrix4_rotate_f32(x, {1, 0, 0}) * linalg.matrix4_rotate_f32(y, {0, 1, 0}) * linalg.matrix4_rotate_f32(z, {0, 0, 1})
}

@(private="file")
node :: proc(position: Vec3, rotation: Mat4 = 1) -> Mat4 {
	return linalg.matrix4_translate_f32(position) * rotation
}

@(private="file")
hurtbox_append :: proc(out: ^[KRUNKER_HURTBOX_MAX]Krunker_Hurtbox, count: ^int, part: Krunker_Hurtbox_Part, parent: Mat4, size: Vec3, scale: f32, moving: bool) {
	if count^ >= KRUNKER_HURTBOX_MAX { return }
	// three.js OBB.fromBox3 + halfSize + 1, then applyMatrix4(matrixWorld),
	// which includes the mesh's own scale.
	full := size + (moving ? Vec3{2, 2, 2} : Vec3{})
	out[count^] = {part, parent * linalg.matrix4_scale_f32(full * scale)}
	count^ += 1
}

// Where the arms (and the gun) sit in Krunker's hit-test pose: the arm hold
// above the upper body (pitched another pitch * 0.5), and the arms' offset and
// rotation inside it. Other players' models use exactly this, so their drawn
// arms are where the server tests them.
krunker_hurtbox_arm_pose :: proc(pose: Krunker_Hurtbox_Pose) -> (hold, position: Vec3, rotation_x, rotation_y: f32) {
	g := GAME_CONSTANTS
	weapon := pose.weapon
	if weapon == nil { return }
	step := g.step_anim
	cv := pose.crouch
	anim_mlt := g.anim_mlt
	arm_anim := g.anim_mlt * 0.7
	d := math.sin(pose.step_val) * step
	v := math.cos(pose.step_val * 2) / 2 * step
	v -= v * (cv * g.crouch_anim_mlt)
	d -= d * (cv * g.crouch_anim_mlt)
	c := -math.cos(pose.step_chase * 2) / 2 * step
	n_mlt := 1 - cv * 0.8
	h := -math.sin(pose.step_chase) * step
	hold = {0, g.player_height - g.camera_height - g.leg_height, 0}
	position = {
		weapon.offset.x + (-weapon.crouch_rotation * cv * anim_mlt + d * 0.5 * n_mlt * anim_mlt) * arm_anim,
		weapon.offset.y + (v * 0.85 - weapon.crouch_drop * cv * anim_mlt) * arm_anim,
		weapon.offset.z,
	}
	rotation_x = -c * 1.5 + weapon.rotation_offset * anim_mlt + weapon.rotation_offset_aim * (1 - anim_mlt) + c * -0.9 * arm_anim
	rotation_y = (-h * 0.16 * anim_mlt * n_mlt) * arm_anim
	return
}

// Fills `out` with Krunker's hit-test boxes for one pose; returns the count.
krunker_player_hurtboxes :: proc(pose: Krunker_Hurtbox_Pose, out: ^[KRUNKER_HURTBOX_MAX]Krunker_Hurtbox) -> (count: int) {
	g := GAME_CONSTANTS
	step := g.step_anim
	cv := pose.crouch
	head_mlt := pose.head_mlt != 0 ? pose.head_mlt : 1
	hurt := pose.hurtbox_scale != 0 ? pose.hurtbox_scale : 1
	anim_mlt := g.anim_mlt                            // Y
	arm_anim := g.anim_mlt * 0.7                      // G
	d := math.sin(pose.step_val) * step
	bounce := abs(d * 6)
	sway := -d * 2
	v := math.cos(pose.step_val * 2) / 2 * step
	v -= v * (cv * g.crouch_anim_mlt)
	d -= d * (cv * g.crouch_anim_mlt)
	c := -math.cos(pose.step_chase * 2) / 2 * step

	root := node(pose.position + Vec3{0, bounce, 0}, linalg.matrix4_rotate_f32(pose.yaw + sway, {0, 1, 0}))
	upper := root * node({0, g.leg_height - g.crouch_distance * cv, 0}, linalg.matrix4_rotate_f32(g.crouch_lean * cv + pose.pitch * 0.5, {1, 0, 0}))

	head_offset := g.head_scale * (head_mlt - 1) / 2
	head := upper * node({0, g.player_height - g.head_scale * 0.5 - g.leg_height + head_offset, 0})
	hurtbox_append(out, &count, .HEAD, head, {g.head_scale, g.head_scale, g.head_scale}, hurt * head_mlt, pose.moving)

	torso_height := g.player_height - g.head_scale - g.leg_height
	torso := upper * node({0, torso_height * 0.5, 0})
	hurtbox_append(out, &count, .TORSO, torso, {g.chest_width, torso_height, g.chest_scale}, hurt, pose.moving)

	if weapon := pose.weapon; weapon != nil {
		hold, arms_position, arms_rotation_x, arms_rotation_y := krunker_hurtbox_arm_pose(pose)
		arm_hold := upper * node(hold, linalg.matrix4_rotate_f32(pose.pitch * 0.5, {1, 0, 0}))
		arms := arm_hold * node(arms_position, euler_xyz(arms_rotation_x, arms_rotation_y, 0))
		shoulder_x := -g.chest_width + g.arm_scale / 2 - g.arm_inset
		for is_left in ([2]bool{true, false}) {
			krunker_arm_hurtboxes(out, &count, arms, weapon, is_left, is_left ? shoulder_x : -shoulder_x, g.arm_offset, hurt, pose.moving)
		}
	}

	legs := root
	if cv == 0 {
		for i in 0 ..< 2 {
			side: f32 = i == 0 ? 1 : -1
			swing := d * (i == 1 ? 1 : -1) * 9
			holder := legs * node({g.leg_scale * 0.5 * side, g.leg_height, 0}, linalg.matrix4_rotate_f32(swing, {1, 0, 0}))
			hurtbox_append(out, &count, .LEG, holder * node({0, -g.leg_height * 0.5, 0}), {g.leg_scale, g.leg_height, g.leg_scale}, hurt, pose.moving)
		}
	} else {
		s := g.leg_scale
		o := g.leg_height / 2
		l := s / 2
		x0, x1: f32 = 0.5, 2
		p := math.sqrt(l * l + l * l - l * 2 * l * math.cos(x0 - x1))
		f := math.sqrt(l * l - p / 2 * (p / 2)) * 2
		for i in 2 ..< 4 {
			is_left := i == 3
			side: f32 = is_left ? -1 : 1
			swing := d * (i == 3 ? 1 : -1) * 9 - 0.6
			holder := legs * node({g.leg_scale * 0.5 * side, g.leg_height - g.crouch_distance + 0.5, 0}, euler_xyz(swing, is_left ? math.PI / 8 : -math.PI / 6, 0))
			hurtbox_append(out, &count, .LEG, holder * node({0, -o / 2 * math.cos(x1), -o / 2 * math.sin(x1)}, linalg.matrix4_rotate_f32(x1, {1, 0, 0})), {s, o, s}, hurt, pose.moving)
			hurtbox_append(out, &count, .LEG, holder * node({0, -o * math.cos(x1), -o * math.sin(x1)}, linalg.matrix4_rotate_f32((x1 + x0) / 2, {1, 0, 0})), {s, p, f}, hurt, pose.moving)
			hurtbox_append(out, &count, .LEG, holder * node({0, -o * math.cos(x1) - o / 2 * math.cos(x0), -o * math.sin(x1) - o / 2 * math.sin(x0)}, linalg.matrix4_rotate_f32(x0, {1, 0, 0})), {s, o, s}, hurt, pose.moving)
		}
	}
	return
}

// One arm (Krunker's client): a two-bone IK chain from the shoulder to the weapon's
// hold point, as upper arm, elbow connector and forearm boxes.
@(private="file")
krunker_arm_hurtboxes :: proc(out: ^[KRUNKER_HURTBOX_MAX]Krunker_Hurtbox, count: ^int, arms: Mat4, weapon: ^Weapon, is_left: bool, r, n: f32, hurt: f32, moving: bool) {
	g := GAME_CONSTANTS
	hold := is_left ? weapon.left_hold : weapon.right_hold
	akimbo_flip: f32 = is_left && weapon.akimbo ? -1 : 1
	target := Vec3{(weapon.offset.x - hold.x) * akimbo_flip, weapon.offset.y + hold.y, weapon.offset.z - hold.z}
	reach := linalg.length(Vec3{r, n, 0} - target)
	reach = min(g.upper_arm_length + g.lower_arm_length - 0.01, reach)
	// hN(d, uArm, lArm) = [-r - PI/2, n, PI - r - n]
	ua, la := g.upper_arm_length, g.lower_arm_length
	elbow := math.acos((ua * ua + la * la - reach * reach) / (ua * 2 * la))
	shoulder := math.acos((la * la + reach * reach - ua * ua) / (la * 2 * reach))
	p0 := -elbow - math.PI / 2
	f := g.arm_scale
	v := f32(math.PI / 2)
	m := f / 2
	gap := math.sqrt(m * m + m * m - m * 2 * m * math.cos(math.PI + p0 + math.PI / 2))
	ys :: proc(e, a, t, r: f32) -> f32 { return math.atan2(a - r, e - t) }
	rot_x := -shoulder - ys(0, n, weapon.offset.z - hold.z, weapon.offset.y + hold.y)
	rot_y := ys(-r, 0, (is_left && weapon.akimbo ? 1 : -1) * (weapon.offset.x - hold.x), weapon.offset.z - hold.z) - math.PI / 2
	// Euler order YXZ.
	holder := arms * node({r - weapon.offset.x, n - weapon.offset.y, -weapon.offset.z}, linalg.matrix4_rotate_f32(rot_y, {0, 1, 0}) * linalg.matrix4_rotate_f32(rot_x, {1, 0, 0}))
	connector_depth := math.sqrt(m * m - gap / 2 * (gap / 2)) * 2
	half_lower := la / 2
	hurtbox_append(out, count, .ARM, holder * node({0, -ua / 2 * math.cos(v), -ua / 2 * math.sin(v)}, linalg.matrix4_rotate_f32(v, {1, 0, 0})), {f, ua, f}, hurt, moving)
	hurtbox_append(out, count, .ARM, holder * node({0, -ua * math.cos(v), -ua * math.sin(v)}, linalg.matrix4_rotate_f32((v + p0) / 2, {1, 0, 0})), {f, gap, connector_depth}, hurt, moving)
	hurtbox_append(out, count, .ARM, holder * node({0, -ua * math.cos(v) - half_lower * math.cos(p0), -ua * math.sin(v) - half_lower * math.sin(p0)}, linalg.matrix4_rotate_f32(p0, {1, 0, 0})), {f, la, f}, hurt, moving)
}
