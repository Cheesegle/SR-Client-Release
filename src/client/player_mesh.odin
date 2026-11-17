package main

import "core:fmt"
import "core:math"
import shared "../shared"
import menuui "../menu"

// v3 first-person knife orientation relative to the right arm pivot.
MELEE_ROT_X :: -math.PI / 3.5
MELEE_ROT_Y :: 0.3
MELEE_ROT_Z :: -math.PI * 0.9

REFLEX_SIGHT_AIM_OFFSET_Y :: 0.16

player_scope_visible :: proc(player: ^shared.Player, view_aim: f32) -> bool {
	return player != nil && player.active && player.is_you && player.weapon != nil && player.weapon.scope &&
		!player_uses_third_person_camera(player) && view_aim >= 0.99
}

generate_weapon_attachment :: proc(weapon: ^shared.Weapon, parent: ^Mesh_Transform) -> ^Mesh {
	model_path := shared.concat(shared.assets_path(), "models/attach/attach_0.obj")
	texture_path := shared.concat(shared.assets_path(), "textures/attach/attach_0.png")
	defer delete(model_path)
	defer delete(texture_path)
	geometry := load_obj_model(model_path, false)
	if geometry == nil { return nil }
	texture := load_texture(texture_path)
	material := basic_material_init()
	if material == nil {
		geometry_release(geometry)
		texture_release(texture)
		return nil
	}
	material.texture = texture
	material.transparent = true
	mesh := mesh_init(geometry, &material.base)
	mesh.transform.parent = parent
	mesh.transform.position = {0, -weapon.origin.y + weapon.attach_y_offset, -weapon.attach_z_offset}
	mesh.transform.rotation.y = math.PI / 2
	mesh.transform.scale = {1.2, 1.2, 1.2}
	return mesh
}

Color_Cube_Segment :: struct {
	color:  i32,
	height: f32,
	scale:  f32,
}

// Segments stack downwards from `top` (genColorCube's offset): 0 centres the
// cube on its transform, -0.5 hangs it below its transform like Krunker's legs.
generate_color_cube :: proc(width, height, length: f32, segments: []Color_Cube_Segment, top: f32 = 0) -> ^Color_Cube {
	color_cube := new(Color_Cube)
	color_cube.mesh_count = i32(len(segments))

	color_cube.transform.scale = shared.Vec3{width, height, length}

	offset: f32 = 0.5 + top

	for segment in segments {
		geo := create_cube_geo()
		material := basic_material_init()

		mesh := mesh_init(geo, &material.base)

		material.color = shared.hex_to_vec(segment.color)

		mesh.transform.scale.x = segment.scale
		mesh.transform.scale.z = segment.scale
		mesh.transform.scale.y = segment.height

		mesh.transform.position.y = offset - segment.height
		mesh.transform.parent = &color_cube.transform

		offset -= segment.height
		append(&color_cube.meshes, mesh)
	}

	return color_cube
}

generate_arm :: proc(x, y: f32, weapon: ^shared.Weapon, is_left, third_person, left_handed: bool, shirt_color, sleeve_color, skin_color: i32) -> ^Player_Arm_Mesh {
	arm := new(Player_Arm_Mesh)

	left_handed_mlt: f32 = left_handed ? -1.0 : 1.0

	hold := shared.Vec3{
		(is_left ? weapon.left_hold.x : weapon.right_hold.x) * left_handed_mlt,
		is_left ? weapon.left_hold.y : weapon.right_hold.y,
		(is_left ? weapon.left_hold.z : weapon.right_hold.z) + (third_person ? 0.0 : weapon.hold_distance_offset),
	}

	arm_scale := shared.GAME_CONSTANTS.arm_scale * (third_person ? 1.0 : 0.68)
	arm_length := min(
		shared.GAME_CONSTANTS.upper_arm_length + shared.GAME_CONSTANTS.lower_arm_length - 0.01,
		math.sqrt(
			math.pow((weapon.offset.x * left_handed_mlt - hold.x) * (is_left && weapon.akimbo ? -1.0 : 1.0) - x, 2.0) +
			math.pow(weapon.offset.y + hold.y - y, 2.0) +
			math.pow(weapon.offset.z - hold.z, 2.0),
		),
	)

	arm_angles := shared.angles_from_sides(arm_length, shared.GAME_CONSTANTS.upper_arm_length, shared.GAME_CONSTANTS.lower_arm_length)

	if third_person {
		upper_material := basic_material_init()
		joint_material := basic_material_init()

		upper_material.color = shared.hex_to_vec(shirt_color)
		joint_material.color = shared.hex_to_vec(shirt_color)

		arm.upper = mesh_init(create_cube_geo(), &upper_material.base)
		arm.joint = mesh_init(create_cube_geo(), &joint_material.base)

		arm.upper.transform.scale.x = arm_scale
		arm.upper.transform.scale.z = arm_scale
		arm.upper.transform.scale.y = shared.GAME_CONSTANTS.upper_arm_length

		arm.upper.transform.rotation.x = -math.PI * 0.5
		arm.upper.transform.parent = &arm.anchor

		joint_length := math.sqrt(2.0 * arm_scale * 0.5 * arm_scale * 0.5 - 2.0 * arm_scale * 0.5 * arm_scale * 0.5 * math.cos(math.PI - arm_angles[0]))
		joint_height := math.sqrt(arm_scale * 0.5 * arm_scale * 0.5 - joint_length * 0.5 * joint_length * 0.5) * 2.0

		arm.joint.transform.scale.x = arm_scale
		arm.joint.transform.scale.y = joint_height
		arm.joint.transform.scale.z = joint_length

		arm.joint.transform.rotation.x = math.PI * 0.5 - arm_angles[0] * 0.5

		arm.joint.transform.position.y = -joint_height * 0.5 * math.cos(arm.joint.transform.rotation.x)
		arm.joint.transform.position.z = -shared.GAME_CONSTANTS.upper_arm_length - joint_height * 0.5 * math.sin(arm.joint.transform.rotation.x)

		arm.joint.transform.parent = &arm.anchor
	} else {
		material := basic_material_init()
		material.color = shared.hex_to_vec(shirt_color)

		arm.extender = mesh_init(create_cube_geo(), &material.base)
		arm.extender.transform.parent = &arm.anchor

		arm.extender.transform.scale.x = arm_scale
		arm.extender.transform.scale.z = arm_scale
		arm.extender.transform.scale.y = 20.0

		arm.extender.transform.rotation.x = -math.PI * 0.5 - arm_angles[0]
		arm.extender.transform.position.z = -shared.GAME_CONSTANTS.upper_arm_length
	}

	lower_segments := []Color_Cube_Segment{
		{shirt_color, 0.65, 1.0},
		{sleeve_color, 0.15, 1.1},
		{skin_color, 0.2, 1.0},
	}

	arm.lower = generate_color_cube(arm_scale, shared.GAME_CONSTANTS.lower_arm_length, arm_scale, lower_segments)
	arm.lower.transform.parent = &arm.anchor

	arm.lower.transform.rotation.x = -math.PI * 0.5 - arm_angles[0]

	arm.lower.transform.position.y = -shared.GAME_CONSTANTS.lower_arm_length * 0.5 * math.cos(arm.lower.transform.rotation.x)
	arm.lower.transform.position.z = -shared.GAME_CONSTANTS.upper_arm_length - shared.GAME_CONSTANTS.lower_arm_length * 0.5 * math.sin(arm.lower.transform.rotation.x)

	arm.anchor.position.x = x - weapon.offset.x * left_handed_mlt
	arm.anchor.position.y = y - weapon.offset.y
	arm.anchor.position.z = -weapon.offset.z + (third_person ? 0.0 : weapon.hold_distance_offset)
	arm.anchor.scale = shared.Vec3{1.0, 1.0, 1.0}

	arm.anchor.rotation.x = -arm_angles[1] + math.atan2(weapon.offset.y + hold.y - y, -(weapon.offset.z - hold.z))
	arm.anchor.rotation.y = math.atan2(x - (weapon.offset.x * left_handed_mlt - hold.x) * (is_left && weapon.akimbo ? -1.0 : 1.0), -(weapon.offset.z - hold.z))
	arm.anchor.rotation_order = .EXTRINSIC
	arm.anchor.parent = &arm.pivot
	arm.pivot.scale = shared.Vec3{1.0, 1.0, 1.0}

	return arm
}

generate_arms :: proc(weapon: ^shared.Weapon, third_person, left_handed: bool, shirt_color, sleeve_color, skin_color: i32) -> ^Player_Arms {
	arms := new(Player_Arms)

	offset := (-shared.GAME_CONSTANTS.chest_width + shared.GAME_CONSTANTS.arm_scale * 0.5 - shared.GAME_CONSTANTS.arm_inset) * (third_person ? 1.0 : weapon.hold_width != 0 ? weapon.hold_width : 0.4)

	arms.left = generate_arm(offset, shared.GAME_CONSTANTS.arm_offset, weapon, !left_handed, third_person, left_handed, shirt_color, sleeve_color, skin_color)
	arms.right = generate_arm(-offset, shared.GAME_CONSTANTS.arm_offset, weapon, left_handed, third_person, left_handed, shirt_color, sleeve_color, skin_color)

	arms.anchor.scale = shared.Vec3{1.0, 1.0, 1.0}
	arms.left.pivot.parent = &arms.anchor
	arms.right.pivot.parent = &arms.anchor

	return arms
}

generate_head :: proc(skin_color, hair_color: i32) -> ^Color_Cube {
	segments := []Color_Cube_Segment{
		{hair_color, 0.2, 1.0},
		{skin_color, 0.8, 1.0},
	}

	head := generate_color_cube(
		shared.GAME_CONSTANTS.head_scale,
		shared.GAME_CONSTANTS.head_scale,
		shared.GAME_CONSTANTS.head_scale,
		segments,
	)

	if head != nil {
		head.transform.position.y = shared.GAME_CONSTANTS.body_height + shared.GAME_CONSTANTS.head_scale * 0.5
	}

	return head
}

generate_body :: proc(shirt_color, pants_color: i32) -> ^Color_Cube {
	segments := []Color_Cube_Segment{
		{shirt_color, 0.8, 1.0},
		{pants_color, 0.2, 1.05},
	}

	body := generate_color_cube(
		shared.GAME_CONSTANTS.chest_width,
		shared.GAME_CONSTANTS.body_height,
		shared.GAME_CONSTANTS.chest_scale,
		segments,
	)

	if body != nil {
		body.transform.position.y = shared.GAME_CONSTANTS.body_height * 0.5
	}

	return body
}

generate_leg :: proc(is_left: bool, pants_color, shoe_color: i32) -> ^Color_Cube {
	segments := []Color_Cube_Segment{
		{pants_color, 0.75, 1.0},
		{shoe_color, 0.25, 1.0},
	}

	// Krunker's genLeg hangs the leg from the hip (genColorCube offset -0.5,
	// mesh at legHeight), so the stride swings it about the hip, not mid-thigh.
	leg := generate_color_cube(shared.GAME_CONSTANTS.leg_scale, shared.GAME_CONSTANTS.leg_height, shared.GAME_CONSTANTS.leg_scale, segments, -0.5)

	if leg != nil {
		leg.transform.position.x = shared.GAME_CONSTANTS.leg_scale * 0.5 * (is_left ? -1.0 : 1.0)
		leg.transform.position.y = shared.GAME_CONSTANTS.leg_height
	}

	return leg
}

generate_crouched_leg :: proc(is_left: bool, pants_color, shoe_color: i32) -> ^Player_Crouched_Leg {
	leg := new(Player_Crouched_Leg)

	leg_angles := [2]f32{2.0, 0.5}

	upper_material := basic_material_init()
	joint_material := basic_material_init()

	upper_material.color = shared.hex_to_vec(pants_color)
	joint_material.color = shared.hex_to_vec(pants_color)

	leg.upper = mesh_init(create_cube_geo(), &upper_material.base)
	leg.joint = mesh_init(create_cube_geo(), &joint_material.base)

	leg.upper.transform.scale.x = shared.GAME_CONSTANTS.leg_scale
	leg.upper.transform.scale.z = shared.GAME_CONSTANTS.leg_scale
	leg.upper.transform.scale.y = shared.GAME_CONSTANTS.leg_height * 0.5

	leg.upper.transform.rotation.x = leg_angles[0]

	leg.upper.transform.position.y = -shared.GAME_CONSTANTS.leg_height * 0.5 * math.cos(leg.upper.transform.rotation.x)
	leg.upper.transform.position.z = -shared.GAME_CONSTANTS.leg_height * 0.5 * math.sin(leg.upper.transform.rotation.x)

	leg.upper.transform.parent = &leg.anchor

	joint_length := math.sqrt(2.0 * shared.GAME_CONSTANTS.leg_scale * 0.5 * shared.GAME_CONSTANTS.leg_scale * 0.5 - 2.0 * shared.GAME_CONSTANTS.leg_scale * 0.5 * shared.GAME_CONSTANTS.leg_scale * 0.5 * math.cos(math.PI - (leg_angles[0] - leg_angles[1])))
	joint_height := math.sqrt(shared.GAME_CONSTANTS.leg_scale * 0.5 * shared.GAME_CONSTANTS.leg_scale * 0.5 - joint_length * 0.5 * joint_length * 0.5) * 2.0

	leg.joint.transform.scale.x = shared.GAME_CONSTANTS.leg_scale
	leg.joint.transform.scale.y = joint_height
	leg.joint.transform.scale.z = joint_length

	leg.joint.transform.rotation.x = (leg_angles[0] + leg_angles[1]) * 0.5

	leg.joint.transform.position.y = -shared.GAME_CONSTANTS.leg_height * 0.5 * math.cos(leg.upper.transform.rotation.x) - joint_height * 0.5 * math.cos(leg.joint.transform.rotation.x)
	leg.joint.transform.position.z = -shared.GAME_CONSTANTS.leg_height * 0.5 * math.sin(leg.upper.transform.rotation.x) - joint_height * 0.5 * math.sin(leg.joint.transform.rotation.x)

	leg.joint.transform.parent = &leg.anchor

	lower_segments := []Color_Cube_Segment{
		{pants_color, 0.5, 1.0},
		{shoe_color, 0.5, 1.0},
	}

	leg.lower = generate_color_cube(shared.GAME_CONSTANTS.leg_scale, shared.GAME_CONSTANTS.leg_height * 0.5, shared.GAME_CONSTANTS.leg_scale, lower_segments)
	leg.lower.transform.parent = &leg.anchor

	leg.lower.transform.rotation.x = leg_angles[1]

	leg.lower.transform.position.y = -shared.GAME_CONSTANTS.leg_height * 0.5 * math.cos(leg.upper.transform.rotation.x) - shared.GAME_CONSTANTS.leg_height * 0.25 * math.cos(leg.lower.transform.rotation.x)
	leg.lower.transform.position.z = -shared.GAME_CONSTANTS.leg_height * 0.5 * math.sin(leg.upper.transform.rotation.x) - shared.GAME_CONSTANTS.leg_height * 0.25 * math.sin(leg.lower.transform.rotation.x)

	leg.anchor.scale = shared.Vec3{1.0, 1.0, 1.0}

	leg.anchor.position.x = shared.GAME_CONSTANTS.leg_scale * 0.5 * (is_left ? -1.0 : 1.0)
	// Full crouch; player_update_meshes moves the hip with the crouch amount.
	leg.anchor.position.y = player_crouched_leg_hip_y(1)

	leg.anchor.rotation.y = is_left ? math.PI / 8.0 : -math.PI / 6.0

	return leg
}

player_generate_meshes :: proc(player: ^shared.Player, render_you: bool) {
	if player.mesh != nil {
		return
	}

	player.render_you = render_you

	colors := player.game.classes[player.class_index].colors

	third_person := !render_you || player_uses_third_person_camera(player)

	player_mesh := new(Player_Mesh)

	player_mesh.anchor = new(Mesh_Transform)
	player_mesh.body_anchor = new(Mesh_Transform)
	player_mesh.upper_body_anchor = new(Mesh_Transform)

	player_mesh.body_anchor.position.y = shared.GAME_CONSTANTS.leg_height
	player_mesh.body_anchor.parent = player_mesh.anchor
	player_mesh.upper_body_anchor.parent = player_mesh.body_anchor

	player_mesh.anchor.scale = shared.Vec3{1.0, 1.0, 1.0}
	player_mesh.body_anchor.scale = shared.Vec3{1.0, 1.0, 1.0}
	player_mesh.upper_body_anchor.scale = shared.Vec3{1.0, 1.0, 1.0}

	player.mesh = player_mesh

	if player.game.map_inst.config.model != .SPRITE {
		if third_person {
			player_mesh.body = generate_body(colors[1], colors[2])
			player_mesh.head = generate_head(colors[0], colors[4])

			player_mesh.body.transform.parent = player_mesh.body_anchor
			player_mesh.head.transform.parent = player_mesh.body_anchor
		}

		if third_person {
			for i in 0 ..< 2 {
				leg := generate_leg(i == 0, colors[2], colors[3])

				leg.transform.parent = player_mesh.anchor
				player_mesh.legs[i] = leg
			}

			for i in 0 ..< 2 {
				leg := generate_crouched_leg(i == 0, colors[2], colors[3])

				leg.anchor.parent = player_mesh.anchor
				player_mesh.crouched_legs[i] = leg
			}
		}

		for i in 0 ..< player.loadout_size {
			weapon := player.game.weapons[player.loadout[i]]

			arms := generate_arms(weapon, third_person, player.left_handed, colors[1], colors[5], colors[0])
			if arms == nil {
				continue
			}

			arms.anchor.parent = player_mesh.upper_body_anchor
			append(&player_mesh.arms, arms)

			// melee mesh
			if weapon.melee {
				model_path := shared.concat(shared.assets_path(), "models/melee/melee_0.obj")
				texture_path := shared.concat(shared.assets_path(), "textures/melee/melee_0.png")
				defer delete(model_path)
				defer delete(texture_path)

				melee_geo := load_obj_model(model_path, false)
				melee_texture := load_texture(texture_path)

				if melee_geo != nil && melee_texture != 0 {
					melee_mat := basic_material_init()
					melee := mesh_init(melee_geo, &melee_mat.base)

					melee_mat.texture = melee_texture

					melee.transform.parent = render_you ? &arms.right.pivot : &arms.anchor
					melee.transform.position = shared.Vec3{render_you ? 0.9 : 1.7, render_you ? -0.95 : -0.4, render_you ? 0.72 : 1.2}
					melee.transform.rotation = shared.Vec3{MELEE_ROT_X, render_you ? MELEE_ROT_Y : math.PI * 0.5, MELEE_ROT_Z}
					melee.transform.scale = shared.Vec3{0.9, 0.9, 0.9}

					arms.weapon_right = melee
				} else {
					geometry_release(melee_geo)
					texture_release(melee_texture)
				}
			}

			// weapon model
			if len(weapon.src) > 0 || len(weapon.model) > 0 {
				for j in 0 ..< 2 {
					model_path: string
					if len(weapon.model) > 0 {
						model_path = shared.concat(shared.assets_path(), weapon.model)
					} else {
						model_src := weapon.src
						if model_src == "weapon-7" {
							model_src = "weapon_7"
						}
						model_path = shared.concat(shared.assets_path(), fmt_tprintf("models/weapons/%s.obj", model_src))
					}

					texture_path: string
					if len(weapon.texture) > 0 {
						texture_path = shared.concat(shared.assets_path(), weapon.texture)
					} else {
						texture_src := weapon.src
						// The configured LMG source follows the old asset naming
						// convention, while the unpacked mod uses weapon_7.
						if texture_src == "weapon-7" {
							texture_src = "weapon_7"
						}
						texture_path = shared.concat(shared.assets_path(), fmt_tprintf("textures/weapons/%s.png", texture_src))
					}
					defer delete(model_path)
					defer delete(texture_path)

					weapon_geo := load_obj_model(model_path, false)
					weapon_tex := load_texture(texture_path)

					if weapon_geo == nil {
						texture_release(weapon_tex)
						continue
					}

					weapon_mat := basic_material_init()
					weapon_mesh := mesh_init(weapon_geo, &weapon_mat.base)

					weapon_mat.texture = weapon_tex

					weapon_mesh.transform.position = weapon.model_offset
					if j == 1 {
						weapon_mesh.transform.position.x += weapon.offset.x * -2.0 * (player.left_handed ? -1.0 : 1.0)
					}

					model_scale := weapon.scale != 0 ? weapon.scale : 1.0
					weapon_mesh.transform.scale = {model_scale, model_scale, model_scale}

					weapon_mesh.transform.rotation.y = weapon.rotation != 0 ? weapon.rotation : math.PI * 0.5
					if weapon.model_rotation != (shared.Vec3{}) {
						weapon_mesh.transform.rotation = weapon.model_rotation
					}
					weapon_mesh.transform.parent = &arms.anchor

					if j == 1 {
						arms.weapon_left = weapon_mesh
					} else {
						arms.weapon_right = weapon_mesh
					}

					if !weapon.akimbo {
						break
					}
				}
			}
			// Krunker adds the selected sight only to first-person/preview rigs.
			if weapon.has_attachment && (render_you || player.uid == -1) {
				arms.attachment = generate_weapon_attachment(weapon, &arms.anchor)
			}
		}
	}
}

fmt_tprintf :: proc(format: string, args: ..any) -> string {
	return fmt.tprintf(format, ..args)
}

player_uses_third_person_camera :: proc(player: ^shared.Player) -> bool {
	if player == nil || player.game == nil || player.game.map_inst == nil {
		return false
	}

	offset := player.game.map_inst.config.cam_offset
	return player.game.config.third_person || offset.x != 0 || offset.y != 0 || offset.z != 0
}

// Krunker's updateHeight: bent legs hang 0.5 inside the base of the lower
// body, which drops by crouchDst * crouchVal.
player_crouched_leg_hip_y :: proc(crouch: f32) -> f32 {
	return shared.GAME_CONSTANTS.leg_height + 0.5 - shared.GAME_CONSTANTS.crouch_distance * crouch
}

// The crouch amount the rig shows. Krunker's server sends remote players'
// crouch as Math.round(crouchVal), so their model is only ever standing or
// fully crouched; a partial value (from interpolating between snapshots)
// would show bent legs on a standing body. Rendered-you uses its own value.
player_rig_crouch :: proc(player: ^shared.Player) -> f32 {
	if player.render_you || g_rig_continuous_crouch { return player.crouch_val }
	if player.server_crouch_valid { return player.server_crouch } // as the server's hit test
	return math.round(clamp(player.crouch_val, 0, 1))
}

player_update_meshes :: proc(player: ^shared.Player, is_preview: bool) {
	if player.mesh == nil {
		return
	}

	player_mesh := cast(^Player_Mesh)player.mesh
	crouch_val := player_rig_crouch(player)

	third_person := player_uses_third_person_camera(player)
	local_viewmodel := player.render_you && !third_person && !is_preview && g_client != nil && g_client.me == player
	settings := menuui.DEFAULT_VIEWMODEL_SETTINGS
	if local_viewmodel { settings = client_viewmodel_values(g_client) }
	// The official renderer mirrors the entire upper-body rig. Keeping the
	// reflection on this parent also mirrors hands, sights and muzzle origins
	// live, without rebuilding models or changing the player's gameplay state.
	player_mesh.upper_body_anchor.scale.x = local_viewmodel && settings.toggles[.LEFT_HANDED] ? -1 : 1
	animate_aim := settings.toggles[.AIM_ANIMATION]
	weapon_bobbing_mlt := settings.values[.BOBBING]
	weapon_lean_mlt := settings.values[.LEANING]
	weapon_rotation := settings.values[.ROTATION]
	weapon_offset_mlt := shared.Vec3{settings.values[.OFFSET_X], settings.values[.OFFSET_Y], settings.values[.OFFSET_Z]}
	// Ballistic recoil controls spread and camera pitch, not first-person gun
	// sway. Keep its legacy mesh offsets for world models; view_kick supplies
	// the independent first-person firing animation.
	ballistic_motion_mlt: f32 = player.render_you && !third_person ? 0.0 : 1.0
	view_aim := player.aim_val
	view_position := player.position
	if g_client != nil && g_client.krunker.connected && g_client.me == player && !is_preview {
		sample := krunker_client_render_sample(g_client)
		view_aim, view_position = sample.aim, sample.position
	}
	aim_val_mlt: f32 = animate_aim && player.is_you ? view_aim : 0.0
	// Keep the calibrated sight pose fixed at full first-person ADS. Residual
	// step bob and speed-dependent lean otherwise move it away from the aim ray.
	// Apply this at the cosmetic transforms so smoothed jump/landing state also
	// fades out, without changing recoil, reloads, swaps or third-person motion.
	movement_mlt: f32 = 1.0
	if player.render_you && !third_person && !player.weapon.melee && !player.weapon.no_aim {
		movement_mlt = 1.0 - clamp(aim_val_mlt, 0.0, 1.0)
	}
	aim_mlt: f32 = player.weapon.animate_while_aiming ? 0.0 : aim_val_mlt
	anim_mlt := (1.0 - (1.0 - shared.GAME_CONSTANTS.aim_anim_mlt) * aim_val_mlt) * shared.GAME_CONSTANTS.anim_mlt * weapon_bobbing_mlt
	anim_mlt_crouch := 1.0 - crouch_val * 0.8
	anim_mlt_lean := player.render_you ? (1.0 - aim_val_mlt) * shared.GAME_CONSTANTS.anim_mlt : 0.0
	recoil_y_mlt := (1.0 - aim_val_mlt) * shared.GAME_CONSTANTS.anim_mlt * ballistic_motion_mlt
	recoil_z_mlt := (1.0 - (player.weapon.recoil_z_mlt != 0 ? player.weapon.recoil_z_mlt : 0.5) * aim_mlt) * ballistic_motion_mlt
	anim_rotate_mlt := (1.0 - (player.weapon.z_rotation != 0 ? player.weapon.z_rotation : 0.3) * aim_mlt) * (player.weapon.z_rotation_mlt != 0 ? player.weapon.z_rotation_mlt : 1.0) * weapon_bobbing_mlt
	anim_y_mlt := 1.0 - (player.weapon.jump_y_mlt != 0 ? player.weapon.jump_y_mlt : 1.0) * aim_mlt
	lean_aim_mlt := 1.0 - aim_mlt * 0.45
	bob_anim_y := player.bob_anim.y * 0.9 * anim_y_mlt * anim_mlt_lean * weapon_bobbing_mlt
	land_bob_y := (player.land_bob_y * (player.weapon.land_bob != 0 ? player.weapon.land_bob : 1.0) * 0.6) * (1.0 - aim_mlt * 0.75) * weapon_bobbing_mlt

	if player.land_bob_yr != land_bob_y {
		player.land_bob_yr += (land_bob_y - player.land_bob_yr) * 0.1
	}

	land_bob_ya := player.land_bob_y * (player.weapon.land_bob != 0 ? player.weapon.land_bob : 1.0) * 0.1
	bob_crouch_mlt := 1.0 - crouch_val * 0.5
	jump_rotate := player.jump_rotate * bob_crouch_mlt * anim_mlt_lean * weapon_bobbing_mlt

	if player.jump_rotate_mlt != jump_rotate {
		player.jump_rotate_mlt += (jump_rotate - player.jump_rotate_mlt) * 0.08
	}

	jump_bob_y := player.jump_bob_y * (player.weapon.jump_bob_y_mlt != 0 ? player.weapon.jump_bob_y_mlt : 1.0) * anim_mlt_lean * bob_crouch_mlt * weapon_bobbing_mlt
	recoil_aim_mlt := (1.0 - aim_mlt * 0.75) * ballistic_motion_mlt
	recoil_mlt := 1.0 - (player.weapon.aim_recoil_mlt != 0 ? player.weapon.aim_recoil_mlt : 1.0) * aim_mlt
	step_mlt := is_preview ? 0.05 : shared.GAME_CONSTANTS.step_anim
	stride := !player.render_you && player.server_step_valid ? player.server_step : player.step_val
	step_anim := math.sin(stride) * step_mlt
	step_half := math.cos(2.0 * stride) * 0.5 * step_mlt
	step_anim_rotate := -math.sin(player.step_chase) * step_mlt
	step_half_rotate := -math.cos(2.0 * player.step_chase) * 0.5 * step_mlt
	aim_val := third_person ? 0.0 : aim_val_mlt
	aim_lean := (aim_val <= 0.5 ? aim_val : 0.5 - (aim_val - 0.5)) * (player.weapon.aim_lean != 0 ? player.weapon.aim_lean : 0.5)
	swap_anim := player.swap_timer / player.weapon.swap_time
	left_hand_mlt: f32 = player.left_handed ? -1.0 : 1.0

	weapon_offset := shared.Vec3{
		player.weapon.offset.x * (player.render_you ? weapon_offset_mlt.x : 1.0) * left_hand_mlt,
		player.weapon.offset.y * (player.render_you ? weapon_offset_mlt.y : 1.0),
		player.weapon.offset.z * (player.render_you ? weapon_offset_mlt.z : 1.0),
	}

	reload_anim: f32 = 0
	if player.reload_timer > 0.0 {
		reload_anim = 1.0 - player.reload_timer / (player.weapon.reload_time * player.game.config.reload_speed)
	}
	if reload_anim > 0.5 {
		reload_anim = 1.0 - reload_anim
	}

	reload_anim *= player.render_you ? 1.0 : 0.3

	idle_anim := (1.0 - aim_val_mlt * 0.88) * 1.75 * weapon_bobbing_mlt
	// Other players bob exactly as their Krunker hitboxes do (root at
	// |sin(stepVal) * stepAnim * 6|), so the drawn body sits where the server
	// tests it. It was 3.5: the head drew up to 0.2 units below its hitbox.
	step_y := player.render_you && !third_person ? abs(step_anim_rotate * 0.5) * anim_mlt_lean : player.render_you ? abs(step_anim * 3.5) : abs(step_anim * 6)
	step_yaw := player.render_you ? (third_person ? -step_anim * 0.5 : 0.0) : -step_anim * 2.0

	// Every entity's root follows its authoritative position. Previously this
	// was restricted to the local/preview player, leaving network peers moving
	// and rotating at the world origin despite receiving correct snapshots.
	player_mesh.anchor.position = view_position
	player_mesh.anchor.position.y += step_y
	// Standing inside another player (spawns, intermission): Krunker draws only
	// the outside of a model, so from inside you see past them. SR's cubes are
	// two-sided, which filled the screen; hide a player whose body holds your eye.
	if !player.render_you && g_client != nil && g_client.me != nil && g_client.me != player && g_client.me.active {
		me := g_client.me
		eye := shared.Vec3{me.position.x, me.position.y + me.height - shared.GAME_CONSTANTS.camera_height, me.position.z}
		dx, dz := eye.x - view_position.x, eye.z - view_position.z
		reach := shared.GAME_CONSTANTS.chest_width * 0.5 + 0.75
		inside := dx*dx + dz*dz < reach*reach && eye.y > view_position.y - 0.5 && eye.y < view_position.y + shared.GAME_CONSTANTS.player_height + 0.5
		player_mesh.anchor.scale = inside ? shared.Vec3{} : shared.Vec3{1, 1, 1}
	}

	if player.game.map_inst.config.model != .SPRITE {
		player_mesh.anchor.rotation.y = player.direction.y + step_yaw
	}

	step_half -= step_half * crouch_val * shared.GAME_CONSTANTS.crouch_anim_mlt
	step_anim -= step_anim * crouch_val * shared.GAME_CONSTANTS.crouch_anim_mlt

	// Krunker strides every leg mesh it built (remote and third-person you):
	// rotation.x = stepAnim * 9 * side, bent legs tucked a further -0.6. In
	// Krunker (model and server hitboxes alike) the LEFT leg (-x) swings +1 and
	// the right leg -1. SR's legs[0] / crouched_legs[0] are the left legs, so
	// index 0 takes +1 (it took -1 before, striding mirrored to the hitboxes).
	for i in 0 ..< 2 {
		side: f32 = i == 0 ? 1.0 : -1.0
		if player_mesh.legs[i] != nil {
			player_mesh.legs[i].transform.rotation.x = step_anim * side * 9.0
		}
		if player_mesh.crouched_legs[i] != nil {
			player_mesh.crouched_legs[i].anchor.rotation.x = step_anim * side * 9.0 + -0.6
		}
	}

	// Shared weapon swapping cannot manipulate client meshes. Keep all loadout
	// arms hidden except the active slot here so swaps remain renderer-agnostic.
	viewmodel_visible := !local_viewmodel || (viewmodel_weapon_visible(player.weapon, settings) &&
		!(settings.toggles[.HIDE_ON_ADS] && view_aim >= 0.99))
	for arms, i in player_mesh.arms {
		if arms == nil {
			continue
		}

		visible := i == int(player.loadout_index) && !(!is_preview && player_scope_visible(player, view_aim)) && viewmodel_visible
		hands_visible := visible && (!local_viewmodel || settings.toggles[.SHOW_HANDS])

		if arms.weapon_right != nil {
			arms.weapon_right.visible = visible
		}
		if arms.weapon_left != nil {
			arms.weapon_left.visible = visible
		}
		if arms.attachment != nil {
			arms.attachment.visible = visible
		}

		arm_meshes := [2]^Player_Arm_Mesh{arms.left, arms.right}
		for arm in arm_meshes {
			if arm == nil {
				continue
			}

			if arm.extender != nil {
				arm.extender.visible = hands_visible
			}
			if arm.upper != nil {
				arm.upper.visible = hands_visible
			}
			if arm.joint != nil {
				arm.joint.visible = hands_visible
			}

			for mesh in arm.lower.meshes {
				mesh.visible = hands_visible
			}
		}
	}

	reload_mlt: f32 = third_person ? 0.4 : settings.values[.RELOAD_Y]
	// Match camera pitch here so camera recoil does not displace the sight.
	player_mesh.upper_body_anchor.rotation.x = (bob_anim_y * -0.2 + land_bob_ya) * movement_mlt + reload_anim * (reload_mlt * -2.8) +
		player.direction.x * (player.render_you && !third_person ? 1.0 : 0.5) +
		(-math.PI * 0.25 * swap_anim * settings.values[.SWAP_Y] + player.recoil_anim_y * shared.GAME_CONSTANTS.recoil_mlt) +
		(player.weapon.y_rotation != 0 ? player.weapon.y_rotation : 0.0)

	player_mesh.upper_body_anchor.rotation.y = reload_anim * -reload_mlt
	player_mesh.upper_body_anchor.rotation.z = 0.35 * weapon_rotation

	player_mesh.upper_body_anchor.position.x = 0.0
	player_mesh.upper_body_anchor.position.z = 0.0
	player_mesh.upper_body_anchor.position.y = player.recoil_anim_y * (player.weapon.recoil_y_mlt != 0 ? player.weapon.recoil_y_mlt : 0.3) * recoil_y_mlt + (player.render_you && !third_person ? player.height : shared.GAME_CONSTANTS.player_height) - shared.GAME_CONSTANTS.camera_height - shared.GAME_CONSTANTS.leg_height

	if player.loadout_index < 0 || player.loadout_index >= i32(len(player_mesh.arms)) || player_mesh.arms[player.loadout_index] == nil {
		return
	}

	arms := player_mesh.arms[player.loadout_index]
	arm_anchor := &arms.anchor
	aim_offset_y := player.weapon.has_attachment ? REFLEX_SIGHT_AIM_OFFSET_Y + player.weapon.aim_offset_y : 0.0
	if local_viewmodel && settings.values[.ADS_OFFSET_Y] != 1 {
		aim_offset_y = (aim_offset_y != 0 ? aim_offset_y : 0.1) * settings.values[.ADS_OFFSET_Y]
	}

	arm_anchor.rotation.x = (-math.cos(player.idle_anim) * bob_crouch_mlt * 0.01 * idle_anim -
		player.land_bob_yr * 0.4 +
		player.lean_anim.y * lean_aim_mlt * (player.weapon.lean_mlt != 0 ? player.weapon.lean_mlt : 1.0) * weapon_lean_mlt +
		step_half_rotate * -0.9 * anim_mlt) * movement_mlt +
		player.weapon.rotation_offset * anim_mlt_lean + player.weapon.rotation_offset_aim * (1.0 - anim_mlt_lean) +
		player.view_kick[0] * recoil_mlt

	arm_anchor.rotation.y = (player.jump_rotate_mlt * 0.2 +
		player.lean_anim.x * lean_aim_mlt * (player.weapon.lean_mlt != 0 ? player.weapon.lean_mlt : 1.0) * weapon_lean_mlt +
		(-step_anim_rotate * 0.16 * anim_mlt_lean * anim_mlt_crouch + player.lean_anim.z * 0.2) * anim_mlt) * movement_mlt

	arm_anchor.rotation.z = (jump_rotate +
		player.lean_anim.z * 0.7 * anim_rotate_mlt +
		player.weapon.crouch_lean * left_hand_mlt * crouch_val * anim_mlt_lean * anim_mlt) * movement_mlt +
		aim_lean + player.view_kick[1] * recoil_mlt

	arm_anchor.position.x = player.recoil.x * recoil_aim_mlt +
		(-player.jump_rotate_mlt * anim_mlt_lean * 1.3 +
		(player.lean_anim.z * 0.35 - player.weapon.crouch_rotation * left_hand_mlt * crouch_val * anim_mlt_lean + step_anim * 0.5 * anim_mlt_crouch * anim_mlt_lean) * (1.0 - aim_val_mlt) * anim_mlt) * movement_mlt +
		weapon_offset.x - (weapon_offset.x - player.weapon.origin.x * left_hand_mlt) * aim_val

	arm_anchor.position.y = player.recoil.z * recoil_aim_mlt +
		player.view_kick[2] * recoil_mlt +
		(math.sin(player.idle_anim) * 0.02 * idle_anim +
		jump_bob_y + land_bob_y * 0.5 - bob_anim_y * 1.5 +
		(step_half * 0.85 - player.weapon.crouch_drop * crouch_val * anim_mlt_lean) * anim_mlt) * movement_mlt -
		(player.weapon.bomb ? player.interact_progress * 3.0 : 0.0) +
		weapon_offset.y - (weapon_offset.y - player.weapon.origin.y + aim_offset_y) * aim_val

	arm_anchor.position.z = weapon_offset.z - (weapon_offset.z - player.weapon.origin.z) * aim_val +
		player.view_kick[3] +
		player.bob_anim.z * anim_mlt * movement_mlt + player.recoil_anim * player.weapon.recoil_z * recoil_z_mlt

	if arms.right != nil {
		arms.right.pivot.position = {}
		arms.right.pivot.rotation = {}
	}
	if arms.left != nil {
		arms.left.pivot.position = {}
		arms.left.pivot.rotation = {}
	}
	if player.weapon.melee && player.render_you && !third_person && arms.right != nil && arms.left != nil {
		pose := player.melee_pose
		arms.right.pivot.position = {0.4, 0.3, -step_anim}
		arms.right.pivot.rotation = {-0.4, 0, -0.3}
		arms.left.pivot.position = {0.3, -0.5, step_anim}
		arms.left.pivot.rotation = {0, 0, -0.4}
		arms.left.pivot.position.z += pose[shared.MELEE_L_ARM]
		arms.left.pivot.position.y -= pose[shared.MELEE_L_ARM] * 0.27
		arms.left.pivot.rotation.y += pose[shared.MELEE_L_ARM] * 0.1
		arms.left.pivot.position.x -= pose[shared.MELEE_L_ARM] * 0.3
		arms.right.pivot.rotation.z += crouch_val * 0.12 - step_half_rotate + player.jump_bob_y * 0.2
		if arms.weapon_right != nil {
			arms.weapon_right.visible = player.can_throw && viewmodel_visible
			arms.weapon_right.transform.position = {0.9, -0.95, 0.72}
			arms.weapon_right.transform.rotation = {MELEE_ROT_X, MELEE_ROT_Y, MELEE_ROT_Z}
		}
		if view_aim > 0 && player.can_throw && player.weapon.can_throw {
			wind_up := view_aim
			arms.right.pivot.rotation.z -= wind_up * 1.3
			arms.right.pivot.position.x += wind_up * 1.7
			arms.right.pivot.position.z += wind_up * 1.8
			arms.right.pivot.position.y += wind_up * 2.9
			arms.right.pivot.rotation.y += wind_up
			arms.right.pivot.rotation.x += wind_up * 1.7
		} else if !player.inspecting {
			r_arm := pose[shared.MELEE_R_ARM]
			arms.right.pivot.rotation.z += pose[shared.MELEE_ARM_R]
			arms.right.pivot.rotation.y += pose[shared.MELEE_ARM_T] - r_arm * 0.25
			arms.right.pivot.rotation.x += pose[shared.MELEE_ARM_S]
			arms.right.pivot.position.x += pose[shared.MELEE_ARM_M] + r_arm * 0.3
			arms.right.pivot.position.z += pose[shared.MELEE_ARM_E] + r_arm * 1.15
			arms.right.pivot.position.y += pose[shared.MELEE_ARM_Y] - r_arm * 0.3
			if arms.weapon_right != nil {
				arms.weapon_right.transform.rotation.z += pose[shared.MELEE_WEA_R]
				arms.weapon_right.transform.position.x += pose[shared.MELEE_WEA_M]
				arms.weapon_right.transform.rotation.y += pose[shared.MELEE_FLIP_W]
			}
		}
	}


	if local_viewmodel { client_apply_inspect_pose(g_client, arms) }

	// Other players: the upper body and arms take Krunker's hit-test pose
	// exactly (shared.krunker_hurtbox_arm_pose), so the gun and hands you see
	// are where the server tests them. Reload, swap and recoil motion used to
	// move them away from their hitboxes.
	if !player.render_you {
		pose := shared.krunker_hurtbox_pose(player, false)
		pose.crouch = crouch_val
		hold, arms_position, rotation_x, rotation_y := shared.krunker_hurtbox_arm_pose(pose)
		// Firing kick stays (a few frames); the weapon's own model tilt stays.
		player_mesh.upper_body_anchor.position = hold + {0, player.recoil_anim_y * (player.weapon.recoil_y_mlt != 0 ? player.weapon.recoil_y_mlt : 0.3) * recoil_y_mlt, 0}
		player_mesh.upper_body_anchor.rotation = {pose.pitch * 0.5 + player.recoil_anim_y * shared.GAME_CONSTANTS.recoil_mlt + player.weapon.y_rotation, 0, 0}
		arm_anchor.position = arms_position + {
			player.recoil.x * recoil_aim_mlt,
			player.recoil.z * recoil_aim_mlt + player.view_kick[2] * recoil_mlt,
			player.view_kick[3] + player.recoil_anim * player.weapon.recoil_z * recoil_z_mlt,
		}
		arm_anchor.rotation = {rotation_x + player.view_kick[0] * recoil_mlt, rotation_y, player.view_kick[1] * recoil_mlt}
	}

	if !player.render_you || third_person {
		crouch_distance := shared.GAME_CONSTANTS.crouch_distance * crouch_val
		crouch_lean := shared.GAME_CONSTANTS.crouch_lean * crouch_val

		player_mesh.body_anchor.rotation.y = 0.0
		player_mesh.body_anchor.rotation.z = 0.0
		player_mesh.body_anchor.rotation.x = crouch_lean + player.direction.x * 0.5

		if player.render_you { player_mesh.upper_body_anchor.rotation.x -= crouch_lean } // others: as their hitboxes

		player_mesh.body_anchor.position.x = 0.0
		player_mesh.body_anchor.position.z = 0.0
		player_mesh.body_anchor.position.y = shared.GAME_CONSTANTS.leg_height - crouch_distance

		for leg in player_mesh.legs {
			if leg == nil {
				continue
			}

			for mesh in leg.meshes {
				mesh.visible = crouch_val == 0
			}
		}

		for leg in player_mesh.crouched_legs {
			if leg == nil {
				continue
			}

			leg.anchor.position.y = player_crouched_leg_hip_y(crouch_val)
			leg.upper.visible = crouch_val != 0
			leg.joint.visible = crouch_val != 0

			for mesh in leg.lower.meshes {
				mesh.visible = crouch_val != 0
			}
		}
	}
}

player_meshes_fini :: proc(player: ^shared.Player) {
	if player.mesh == nil {
		return
	}

	player_mesh := cast(^Player_Mesh)player.mesh

	if player_mesh.body != nil {
		for mesh in player_mesh.body.meshes {
			mesh_fini(mesh)
		}

		delete(player_mesh.body.meshes)
		free(player_mesh.body)
	}

	if player_mesh.head != nil {
		for mesh in player_mesh.head.meshes {
			mesh_fini(mesh)
		}

		delete(player_mesh.head.meshes)
		free(player_mesh.head)
	}

	for arms in player_mesh.arms {
		if arms == nil {
			continue
		}

		if arms.weapon_right != nil {
			mesh_fini(arms.weapon_right)
		}
		if arms.weapon_left != nil {
			mesh_fini(arms.weapon_left)
		}
		if arms.attachment != nil {
			mesh_fini(arms.attachment)
		}

		for j in 0 ..< 2 {
			arm := arms.left if j == 1 else arms.right

			if arm == nil {
				continue
			}

			if arm.extender != nil {
				mesh_fini(arm.extender)
			}

			if arm.upper != nil {
				mesh_fini(arm.upper)
			}
			if arm.joint != nil {
				mesh_fini(arm.joint)
			}

			for mesh in arm.lower.meshes {
				mesh_fini(mesh)
			}

			delete(arm.lower.meshes)
			free(arm.lower)
			free(arm)
		}

		free(arms)
	}

	delete(player_mesh.arms)

	for leg in player_mesh.legs {
		if leg == nil {
			continue
		}

		for mesh in leg.meshes {
			mesh_fini(mesh)
		}

		delete(leg.meshes)
		free(leg)
	}

	for leg in player_mesh.crouched_legs {
		if leg == nil {
			continue
		}

		mesh_fini(leg.upper)
		mesh_fini(leg.joint)

		for mesh in leg.lower.meshes {
			mesh_fini(mesh)
		}

		delete(leg.lower.meshes)
		free(leg.lower)
		free(leg)
	}

	free(player_mesh.upper_body_anchor)
	free(player_mesh.body_anchor)
	free(player_mesh.anchor)
	free(player_mesh)

	player.mesh = nil
}
