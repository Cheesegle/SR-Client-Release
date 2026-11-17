package main

import "core:fmt"
import shared "../shared"

client_audio_present :: proc(client: ^Client, event: shared.Presentation_Event) {
	audio := client.audio
	if audio == nil { return }
	local := client.me != nil && event.uid == client.me.uid
	spatial := !local
	variant := audio.variation % 2
	audio.variation += 1
	switch event.kind {
	case .FIRE:
		if event.weapon_id < 0 || int(event.weapon_id) >= len(client.game.weapons) { return }
		weapon := client.game.weapons[event.weapon_id]
		if weapon == nil { return }
		path := audio_weapon_path(weapon)
		if weapon.melee && len(weapon.sound) == 0 { path = fmt.tprintf("%ssound/swsh_def_%d.mp3", shared.assets_path(), variant) }
		// Krunker: remote shots arrive as 's' packets -> playerSound -> play3D with
		// the weapon's refDist/rollOff (25/1) and no range limit.
		audio_play(audio, path, .EFFECTS, 0.8, event.position, spatial, priority = 3)
	case .STEP:
		audio_play_effect(audio, fmt.tprintf("step_%d", variant), .FOOTSTEPS, 0.65 * (1 - event.value * 0.75), event.position, spatial, KRUNKER_STEP_RANGE, 1)
	case .JUMP: audio_play_effect(audio, "jump_0", .FOOTSTEPS, 0.45, event.position, spatial, KRUNKER_STEP_RANGE, 1)
	case .LAND: audio_play_effect(audio, "land_1", .FOOTSTEPS, 0.65, event.position, spatial, KRUNKER_STEP_RANGE, 1)
	case .SLIDE: audio_play_effect(audio, "slide_0", .FOOTSTEPS, 0.5, event.position, spatial, KRUNKER_STEP_RANGE, 1)
	case .RELOAD:
		if local { audio_play_effect(audio, "reload_1", .EFFECTS, 0.7) }
	case .SWAP:
		// Weapon switching is silent.
	case .DAMAGE:
		if local { audio_play_effect(audio, fmt.tprintf("takedmg_%d", variant), .EFFECTS, 0.65, priority = 4) }
	case .HIT:
		if local { audio_play_effect(audio, event.headshot ? "crit_0" : "hit_0", .EFFECTS, 0.7, priority = 4) }
	case .EXPLOSION: audio_play_effect(audio, "explosion", .EFFECTS, 0.85, event.position, true, priority = 3)
	}
}

// Krunker places Howler's listener at the player's eye (x, y + height - camera
// offset, z) even in third person, and orients it by the look yaw and pitch
// without recoil animation. Spectator and free cameras use the camera itself.
client_audio_update_listener :: proc(client: ^Client) {
	if client.audio == nil { return }
	position := client.camera.position
	yaw, pitch := client.camera.rotation.y, client.camera.rotation.x
	if client.me != nil && client.me.active && !client.freecam_enabled {
		if client.me.game != nil && client.me.game.map_inst != nil && player_uses_third_person_camera(client.me) {
			position -= client.me.game.map_inst.config.cam_offset
		}
		yaw, pitch = client.me.direction.y, client.me.direction.x
	}
	audio_set_listener(client.audio, position, yaw, pitch)
}

client_audio_tick :: proc(client: ^Client, delta: f32) {
	client_audio_update_listener(client)
	for event in client.game.presentation_events {
		client_hit_marker_present(client, event)
		client_damage_present(client, event)
		client_audio_present(client, event)
	}
	client_hit_marker_tick_live(client)
	client_damage_tick_live(client)
	clear(&client.game.presentation_events)
	if client.audio != nil && client.krunker.connected {
		world := &client.krunker_world
		if world.hit_revision != client.audio.hit_revision {
			client.audio.hit_revision = world.hit_revision
			if world.hit_revision > 0 { audio_play_effect(client.audio, world.hit_headshot ? "crit_0" : "hit_0", gain = 0.7, priority = 4) }
		}
	}
	if client.audio_settings_dirty {
		client.audio_save_delay -= delta
		if client.audio_save_delay <= 0 {
			client.audio_settings_dirty = false
			audio_settings_save(client.audio_settings)
		}
	}
}
