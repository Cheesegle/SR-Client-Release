package main

import "core:fmt"
import "core:math/rand"
import shared "../shared"

// Volumes, rates and ranges are Krunker's own (Krunker's client sound code):
// play() is 2D at vol * category volume (1), play3D multiplies by 0.55 and
// uses the inverse distance model, playerSound culls beyond its range.
client_audio_present :: proc(client: ^Client, event: shared.Presentation_Event) {
	audio := client.audio
	if audio == nil { return }
	local := client.me != nil && event.uid == client.me.uid
	spatial := !local
	variant := audio.variation % 2
	audio.variation += 1
	crouched := event.value >= 1
	switch event.kind {
	case .FIRE:
		if event.weapon_id < 0 || int(event.weapon_id) >= len(client.game.weapons) { return }
		weapon := client.game.weapons[event.weapon_id]
		if weapon == nil { return }
		path := audio_weapon_path(weapon)
		if weapon.melee && len(weapon.sound) == 0 { path = fmt.tprintf("%ssound/swsh_def_%d.mp3", shared.assets_path(), variant) }
		// Krunker: playSound(weapon.sound, 0.85, sid, x, y, z, rate 0.9..1.1,
		// weapon refDist/rollOff (25/1)); remote shots have no range limit.
		audio_play(audio, path, .EFFECTS, 0.85, event.position, spatial, priority = 3, rate = rand.float32_range(0.9, 1.1))
	case .STEP:
		// playerStep: vol 0.15..0.25 (a fully crouched player: half for you,
		// silent for others), rate 0.8 crouched, remote steps culled past 170.
		gain := rand.float32_range(0.15, 0.25) * (!crouched ? 1 : local ? 0.5 : 0)
		if gain <= 0 { return }
		audio_play_effect(audio, audio_step_sound(), .FOOTSTEPS, gain, event.position, spatial, KRUNKER_STEP_RANGE, 1, rate = crouched ? 0.8 : 1)
	case .JUMP:
		// Only your own jump makes a sound (jump_0/1 at 0.04).
		// getJumpSound: jump_0 or jump_1 at random.
		if local && !audio_play_effect(audio, rand.int_max(2) == 0 ? "jump_0" : "jump_1", .FOOTSTEPS, 0.04, priority = 1) {
			audio_play_effect(audio, "jump_0", .FOOTSTEPS, 0.04, priority = 1)
		}
	case .LAND:
		// resetStep: your own landing plays a step sound at 0.7.
		if local { audio_play_effect(audio, audio_step_sound(), .FOOTSTEPS, 0.7, priority = 1) }
	case .SLIDE:
		if local { audio_play_effect(audio, "slide_0", .FOOTSTEPS, 0.35, priority = 1) }
	case .RELOAD:
		// getReloadSnd: reload_1 when it starts, reload_2 when it ends, at 0.25.
		if local { audio_play_effect(audio, "reload_1", .EFFECTS, 0.25) }
	case .RELOAD_END:
		if local { audio_play_effect(audio, "reload_2", .EFFECTS, 0.25) }
	case .SWAP:
		// Weapon switching is silent.
	case .DAMAGE:
		// takedmg_0/1 at 0.45, at most every 500 ms.
		if local && audio.damage_cooldown <= 0 {
			audio.damage_cooldown = 0.5
			audio_play_effect(audio, fmt.tprintf("takedmg_%d", variant), .EFFECTS, 0.45, priority = 4)
		}
	case .HIT:
		if local { audio_play_effect(audio, event.headshot ? "crit_0" : "hit_0", .EFFECTS, KRUNKER_HIT_VOLUME, priority = 4) }
	case .EXPLOSION: audio_play_effect(audio, "explosion", .EFFECTS, 0.85, event.position, true, priority = 3)
	}
}

// Krunker's hit confirmation: play(headshot ? "crit_0" : "hit_0", 2.1).
KRUNKER_HIT_VOLUME :: 2.1

// Krunker's default floor steps: step_0, step_1, step_0, picked at random.
audio_step_sound :: proc() -> string {
	return rand.int_max(3) == 1 ? "step_1" : "step_0"
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
	if client.audio != nil { client.audio.damage_cooldown = max(client.audio.damage_cooldown - delta, 0) }
	if client.audio != nil && client.krunker.connected {
		world := &client.krunker_world
		if world.hit_revision != client.audio.hit_revision {
			client.audio.hit_revision = world.hit_revision
			if world.hit_revision > 0 { audio_play_effect(client.audio, world.hit_headshot ? "crit_0" : "hit_0", gain = KRUNKER_HIT_VOLUME, priority = 4) }
		}
		// GET_KILL carries the kill sound; a headshot kill is headshot_0.
		if world.kill_revision != client.audio.kill_revision {
			client.audio.kill_revision = world.kill_revision
			if world.kill_revision > 0 && world.kill_sound_headshot { audio_play_effect(client.audio, "headshot_0", priority = 4) }
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
