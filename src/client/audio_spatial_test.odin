package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:testing"
import ma "vendor:miniaudio"
import shared "../shared"

when ODIN_TEST {
	// A 1 kHz sine written as 16-bit PCM WAV. Synthetic sources keep the
	// channel measurements independent of the game's recorded effects.
	audio_spatial_write_tone :: proc(path: string, sample_rate, channels: int, seconds: f32 = 1, amplitude: f32 = 0.5) -> bool {
		frames := int(f32(sample_rate) * seconds)
		data_size := frames * channels * 2
		bytes := make([]u8, 44 + data_size)
		defer delete(bytes)
		put_u32 :: proc(b: []u8, at: int, v: u32) { b[at], b[at+1], b[at+2], b[at+3] = u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24) }
		put_u16 :: proc(b: []u8, at: int, v: u16) { b[at], b[at+1] = u8(v), u8(v >> 8) }
		copy(bytes[0:], "RIFF"); put_u32(bytes, 4, u32(36 + data_size)); copy(bytes[8:], "WAVEfmt ")
		put_u32(bytes, 16, 16); put_u16(bytes, 20, 1); put_u16(bytes, 22, u16(channels))
		put_u32(bytes, 24, u32(sample_rate)); put_u32(bytes, 28, u32(sample_rate * channels * 2))
		put_u16(bytes, 32, u16(channels * 2)); put_u16(bytes, 34, 16)
		copy(bytes[36:], "data"); put_u32(bytes, 40, u32(data_size))
		for i in 0 ..< frames {
			value := i16(amplitude * 32767 * math.sin(2 * math.PI * 1000 * f32(i) / f32(sample_rate)))
			for c in 0 ..< channels { put_u16(bytes, 44 + (i*channels + c)*2, transmute(u16)value) }
		}
		return os.write_entire_file(path, bytes) == nil
	}

	// Per-channel RMS after the parameter ramps have settled.
	audio_spatial_measure :: proc(audio: ^Audio_System, frames: int = 9600, skip: int = 2400) -> (left, right: f64) {
		buffer := make([]f32, (frames + skip) * 2)
		defer delete(buffer)
		ma.engine_read_pcm_frames(&audio.engine, raw_data(buffer), u64(frames + skip), nil)
		for i in skip ..< frames + skip {
			left += f64(buffer[i*2]) * f64(buffer[i*2])
			right += f64(buffer[i*2+1]) * f64(buffer[i*2+1])
		}
		return math.sqrt(left / f64(frames)), math.sqrt(right / f64(frames))
	}

	audio_spatial_play_at :: proc(audio: ^Audio_System, path: string, position: shared.Vec3) -> (left, right: f64, ok: bool) {
		audio_stop_all(audio)
		audio_spatial_measure(audio, 512, 0)
		ok = audio_play(audio, path, position = position, spatial = true)
		left, right = audio_spatial_measure(audio)
		return
	}

	// The camera's world-space axes come from the same view matrix the renderer uses.
	audio_spatial_camera_axes :: proc(camera: ^Camera) -> (right, flat_forward: shared.Vec3) {
		camera_update_world_inverse_matrix(camera)
		m := camera.world_inverse_matrix
		right = {m[0, 0], m[0, 1], m[0, 2]}
		back := shared.Vec3{m[2, 0], m[2, 1], m[2, 2]}
		flat_forward = {-back.x, 0, -back.z}
		length := math.sqrt(flat_forward.x*flat_forward.x + flat_forward.z*flat_forward.z)
		flat_forward /= length
		return
	}

	@(test)
	audio_positional_directions_follow_camera :: proc(t: ^testing.T) {
		path := "bin/audio-spatial-tone-mono.wav"
		defer os.remove(path)
		if !testing.expect(t, audio_spatial_write_tone(path, 48000, 1)) { return }
		audio := audio_create(nil, {1, 1, 1, 1}, true)
		if !testing.expect(t, audio != nil) { return }
		defer audio_destroy(audio)
		yaws := [?]f32{0, math.PI / 2, math.PI, -2.2}
		pitches := [?]f32{0, 0.5, -0.7}
		for yaw in yaws {
			for pitch in pitches {
				camera := camera_init(1)
				camera.position = {10, 5, -20}
				camera.rotation = {pitch, yaw, 0}
				audio_update_listener(audio, &camera)
				right, forward := audio_spatial_camera_axes(&camera)
				label := fmt.tprintf("yaw %.2f pitch %.2f", yaw, pitch)
				p := camera.position
				front_l, front_r, ok_front := audio_spatial_play_at(audio, path, p + forward*10)
				right_l, right_r, ok_right := audio_spatial_play_at(audio, path, p + right*10)
				left_l, left_r, ok_left := audio_spatial_play_at(audio, path, p - right*10)
				back_l, back_r, ok_back := audio_spatial_play_at(audio, path, p - forward*10)
				up_l, up_r, ok_up := audio_spatial_play_at(audio, path, p + {0, 10, 0})
				far_l, far_r, ok_far := audio_spatial_play_at(audio, path, p + forward*100)
				if !testing.expect(t, ok_front && ok_right && ok_left && ok_back && ok_up && ok_far, label) { continue }
				// Howler's HRTF panner (IRCAM Composite): at 1 kHz the far ear of a
				// side source gets about half, a source behind is louder than one in
				// front, and the measured 1 kHz gains below come from the same table.
				testing.expectf(t, right_r > 1.8*right_l && right_r > 0.05, "%s: right source must sit in the right ear (L %.4f R %.4f)", label, right_l, right_r)
				testing.expectf(t, left_l > 1.8*left_r && left_l > 0.05, "%s: left source must sit in the left ear (L %.4f R %.4f)", label, left_l, left_r)
				testing.expectf(t, abs(front_l - front_r) < 0.05 * (front_l + front_r), "%s: front must be centred (L %.4f R %.4f)", label, front_l, front_r)
				testing.expectf(t, abs(back_l - back_r) < 0.05 * (back_l + back_r), "%s: behind must be centred (L %.4f R %.4f)", label, back_l, back_r)
				testing.expectf(t, abs(up_l - up_r) < 0.05 * (up_l + up_r), "%s: above must be centred (L %.4f R %.4f)", label, up_l, up_r)
				front_energy, back_energy := front_l*front_l + front_r*front_r, back_l*back_l + back_r*back_r
				expected_back := math.pow(0.8412 / 0.5474, 2)
				// Looking up or down moves both sources off the horizon (other kernels).
				if pitch == 0 do testing.expectf(t, abs(back_energy/front_energy - expected_back) < 0.1 * expected_back, "%s: behind must sound different from front like Krunker's HRTF (%.3f, want %.3f)", label, back_energy/front_energy, expected_back)
				// Krunker (Howler PannerNode): inverse model, refDistance 25, rolloff 1.
				far_ratio := math.sqrt((far_l*far_l + far_r*far_r) / front_energy)
				testing.expectf(t, abs(far_ratio - 0.25) < 0.02, "%s: 100 units away must follow 25/d (got %.3f)", label, far_ratio)
				// Near-field level: tone RMS x HRTF front gain at 1 kHz x Krunker's 3D volume 0.55.
				expected := 0.5 / math.SQRT_TWO * 0.5474 * 0.55
				if pitch == 0 do testing.expectf(t, abs(front_l - expected) < 0.05 * expected, "%s: front level %.4f must match Krunker's %.4f", label, front_l, expected)
			}
		}
	}

	@(test)
	audio_positional_krunker_model :: proc(t: ^testing.T) {
		near := [?]f32{0, 10, 25}
		for d in near { testing.expect(t, audio_inverse_distance_gain(d, 25, 1) == 1, "inside refDistance the gain is unity") }
		testing.expect(t, abs(audio_inverse_distance_gain(50, 25, 1) - 0.5) < 1e-6)
		testing.expect(t, abs(audio_inverse_distance_gain(100, 25, 1) - 0.25) < 1e-6)
		testing.expect(t, abs(audio_inverse_distance_gain(1000, 25, 1) - 0.025) < 1e-6)
		listener := Audio_Listener{position = {0, 0, 0}, forward = {0, 0, -1}}
		Case :: struct { position: shared.Vec3, azimuth, elevation: f32 }
		cases := [?]Case{
			{{10, 0, 0}, 90, 0}, {{-10, 0, 0}, -90, 0}, {{0, 0, -10}, 0, 0},
			{{0, 0, 10}, 180, 0}, {{0, 10, 0}, 0, 90}, {{0, -10, 0}, 0, -90}, {{10, 0, 10}, 135, 0},
		}
		for c in cases {
			az, el := audio_azimuth_elevation(listener, c.position)
			if abs(c.azimuth) == 180 { az = abs(az) }
			testing.expectf(t, abs(az - c.azimuth) < 0.01 && abs(el - c.elevation) < 0.01, "%v -> az %.2f el %.2f", c.position, az, el)
		}
		// Krunker's orientation vector: (sin(yaw+PI), pitch, cos(yaw+PI)).
		audio := audio_create(nil, {1, 1, 1, 1}, true)
		if !testing.expect(t, audio != nil) { return }
		defer audio_destroy(audio)
		audio_set_listener(audio, {1, 2, 3}, math.PI / 2, 0.3)
		f := audio.listener.forward
		testing.expect(t, abs(f.x + 1) < 1e-5 && abs(f.y - 0.3) < 1e-6 && abs(f.z) < 1e-5, "yaw PI/2 must face -X like the camera")
		testing.expect(t, audio_play_effect(audio, "step_0", .FOOTSTEPS, position = {1, 2, 3 + 160}, spatial = true, range = KRUNKER_STEP_RANGE))
		testing.expect(t, !audio_play_effect(audio, "step_0", .FOOTSTEPS, position = {1, 2, 3 + 180}, spatial = true, range = KRUNKER_STEP_RANGE),
			"remote footsteps beyond Krunker's 170-unit range must be culled")
		testing.expect(t, audio_play_effect(audio, "weapon_4", position = {1, 2, 3 + 5000}, spatial = true), "gunshots carry as far as Krunker's")
		testing.expect(t, !audio_play_effect(audio, "weapon_4", position = {1, 2, 3 + 20000}, spatial = true), "sounds past maxDistance are culled")
	}

	@(test)
	audio_positional_voice_reuse_is_clean :: proc(t: ^testing.T) {
		path := "bin/audio-spatial-tone-reuse.wav"
		defer os.remove(path)
		if !testing.expect(t, audio_spatial_write_tone(path, 48000, 1)) { return }
		audio := audio_create(nil, {1, 1, 1, 1}, true)
		if !testing.expect(t, audio != nil) { return }
		defer audio_destroy(audio)
		camera := camera_init(1)
		audio_update_listener(audio, &camera)
		testing.expect(t, audio_play(audio, path, position = {10, 0, 0}, spatial = true))
		audio_spatial_measure(audio, 4800, 0)
		serial := audio.serial
		audio_stop_all(audio)
		testing.expect(t, audio_play(audio, path, position = {-10, 0, 0}, spatial = true))
		testing.expect(t, audio.voices[0].serial == serial + 1, "the same voice must be reused")
		// HRTF latency: 256 convolver frames plus the ear delays.
		left, right := audio_spatial_measure(audio, 480, 480)
		testing.expectf(t, right < 0.6 * left, "a reused voice must start at its new position (L %.4f R %.4f)", left, right)
		// Non-spatial voices bypass panning and distance entirely.
		audio_stop_all(audio)
		testing.expect(t, audio_play(audio, path))
		left, right = audio_spatial_measure(audio, 4800, 0)
		testing.expectf(t, abs(left - 0.5/math.SQRT_TWO) < 0.01 && abs(right - left) < 1e-4, "non-spatial voices play unchanged (L %.4f R %.4f)", left, right)
	}

	@(test)
	audio_positional_events_use_feet :: proc(t: ^testing.T) {
		game: shared.Game
		game.presentation_enabled = true
		defer delete(game.presentation_events)
		player := shared.Player{game = &game, uid = 7, position = {1, 2, 3}, height = 11}
		shared.player_emit_presentation(&player, .STEP)
		testing.expect(t, len(game.presentation_events) == 1 && game.presentation_events[0].position == shared.Vec3{1, 2, 3},
			"Krunker plays player sounds from the player's x, y, z")
	}
}
