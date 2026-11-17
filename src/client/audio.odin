package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import ma "vendor:miniaudio"
import shared "../shared"

Audio_Channel :: enum { EFFECTS, FOOTSTEPS, UI }
MAX_AUDIO_VOICES :: 64

Audio_Sample :: struct { sound: ma.sound, ready: bool }
Audio_Voice :: struct {
	sound: ma.sound,
	node: Spatial_Node,
	sample: ^Audio_Sample,
	channel: Audio_Channel,
	gain: f32,
	priority: int,
	serial: u64,
	// Spatial voices keep their world position; the listener moves under them.
	spatial, stereo_source: bool,
	position: shared.Vec3,
	ref_distance: f32,
}
Audio_System :: struct {
	engine: ma.engine,
	samples: map[string]^Audio_Sample,
	voices: [MAX_AUDIO_VOICES]Audio_Voice,
	settings: Audio_Settings,
	listener: Audio_Listener,
	nodes_ready: bool,
	serial, hit_revision, kill_revision: u64,
	variation: u32,
	damage_cooldown: f32, // Krunker plays takedmg at most once per 500 ms.
	hrtf_loaded: bool,
}

audio_weapon_path :: proc(weapon: ^shared.Weapon) -> string {
	if weapon == nil { return "" }
	name := len(weapon.sound) > 0 ? weapon.sound : weapon.src
	if weapon.melee && len(weapon.sound) == 0 { name = "swsh_def_0" }
	if name == "weapon-7" { name = "weapon_7" }
	if len(name) == 0 { return "" }
	if strings.contains(name, ".") { return fmt.tprintf("%s%s", shared.assets_path(), name) }
	return fmt.tprintf("%ssound/%s.mp3", shared.assets_path(), name)
}

audio_load_sample :: proc(audio: ^Audio_System, path: string) -> ^Audio_Sample {
	if len(path) == 0 { return nil }
	if sample, found := audio.samples[path]; found { return sample }
	sample := new(Audio_Sample)
	audio.samples[strings.clone(path)] = sample
	cpath := strings.clone_to_cstring(shared.mod_resolve(path))
	defer delete(cpath)
	result := ma.sound_init_from_file(&audio.engine, cpath, {.DECODE}, nil, nil, &sample.sound)
	sample.ready = result == .SUCCESS
	shared.asset_trace(path, sample.ready)
	if !sample.ready { fmt.eprintf("[Audio] Cannot load %s (%v); this effect will be silent.\n", path, result) }
	return sample
}

audio_create :: proc(weapons: []^shared.Weapon, settings: Audio_Settings, no_device: bool = false) -> ^Audio_System {
	audio := new(Audio_System)
	config := ma.engine_config_init()
	config.channels, config.sampleRate = 2, 48000
	config.noDevice = b32(no_device)
	result := ma.engine_init(&config, &audio.engine)
	if result != .SUCCESS {
		fmt.eprintf("[Audio] Output unavailable (%v); continuing without sound.\n", result)
		free(audio)
		return nil
	}
	audio.samples = make(map[string]^Audio_Sample)
	audio.hrtf_loaded = hrtf_load()
	if !audio.hrtf_loaded { fmt.eprintln("[Audio] HRTF table unavailable; positional effects use equal-power panning.") }
	audio.nodes_ready = true
	for &voice in audio.voices {
		if !spatial_node_init(&audio.engine, &voice.node) { audio.nodes_ready = false }
	}
	if !audio.nodes_ready { fmt.eprintln("[Audio] Spatial mixer unavailable; positional effects are disabled.") }
	audio.listener = {forward = {0, 0, -1}}
	// Short effects decode before gameplay, never on the first trigger pull.
	manifest_path := shared.concat(shared.assets_path(), "config/sound-assets.txt")
	defer delete(manifest_path)
	manifest, err := os.read_entire_file_from_path(manifest_path, context.allocator)
	shared.asset_trace(manifest_path, err == nil)
	if err == nil {
		contents := string(manifest)
		for raw_line in strings.split_lines_iterator(&contents) {
			line := strings.trim_space(raw_line)
			if len(line) == 0 || strings.has_prefix(line, "#") { continue }
			audio_load_sample(audio, fmt.tprintf("%s%s", shared.assets_path(), line))
		}
		delete(manifest)
	} else { fmt.eprintln("[Audio] Sound manifest missing; effects will load on demand.") }
	for weapon in weapons { if weapon != nil { audio_load_sample(audio, audio_weapon_path(weapon)) } }
	audio_set_settings(audio, settings)
	fmt.printf("[Audio] Spatial mixer ready: %d cached effects, %d voices.\n", len(audio.samples), MAX_AUDIO_VOICES)
	return audio
}

audio_stop_all :: proc(audio: ^Audio_System) {
	if audio == nil { return }
	for &voice in audio.voices { if voice.sample != nil { ma.sound_stop(&voice.sound) } }
}

audio_destroy :: proc(audio: ^Audio_System) {
	if audio == nil { return }
	for &voice in audio.voices { if voice.sample != nil { ma.sound_uninit(&voice.sound) } }
	for &voice in audio.voices { spatial_node_uninit(&voice.node) }
	for path, sample in audio.samples {
		if sample.ready { ma.sound_uninit(&sample.sound) }
		free(sample)
		delete(path)
	}
	delete(audio.samples)
	ma.engine_uninit(&audio.engine)
	if audio.hrtf_loaded { hrtf_unload() }
	free(audio)
}

audio_channel_gain :: proc(settings: Audio_Settings, channel: Audio_Channel) -> f32 {
	switch channel {
	case .EFFECTS: return settings.effects
	case .FOOTSTEPS: return settings.footsteps
	case .UI: return settings.ui
	}
	return 0
}

audio_set_settings :: proc(audio: ^Audio_System, settings: Audio_Settings) {
	if audio == nil { return }
	audio.settings = settings
	ma.engine_set_volume(&audio.engine, settings.master)
	for &voice in audio.voices {
		if voice.sample != nil { ma.sound_set_volume(&voice.sound, voice.gain * audio_channel_gain(settings, voice.channel)) }
	}
}

// Krunker drives Howler's listener with Howler.pos(eye) and
// Howler.orientation(sin(yaw+PI), pitch, cos(yaw+PI)) with the default +Y up.
// The pitch is used directly as the Y component (not sin/cos), exactly as Krunker does.
audio_set_listener :: proc(audio: ^Audio_System, position: shared.Vec3, yaw, pitch: f32) {
	if audio == nil { return }
	audio.listener = {position = position, forward = {math.sin(yaw + math.PI), pitch, math.cos(yaw + math.PI)}}
	audio_update_spatial_voices(audio)
}

audio_update_listener :: proc(audio: ^Audio_System, camera: ^Camera) {
	if camera == nil { return }
	audio_set_listener(audio, camera.position, camera.rotation.y, camera.rotation.x)
}

// Recompute direction and distance gain for every playing positional voice.
audio_update_spatial_voices :: proc(audio: ^Audio_System) {
	if !audio.nodes_ready { return }
	for &voice in audio.voices {
		if voice.sample == nil || !voice.spatial || !bool(ma.sound_is_playing(&voice.sound)) { continue }
		spatial_node_publish(&voice.node, audio_spatial_params(audio.listener, voice.position, voice.ref_distance, voice.stereo_source), false)
	}
}

audio_spatial_params :: proc(listener: Audio_Listener, position: shared.Vec3, ref_distance: f32, stereo_source: bool) -> Spatial_Params {
	azimuth, elevation := audio_azimuth_elevation(listener, position)
	delta := position - listener.position
	distance := math.sqrt(delta.x*delta.x + delta.y*delta.y + delta.z*delta.z)
	return {
		spatial = true, stereo_source = stereo_source,
		gain = KRUNKER_3D_VOLUME * audio_inverse_distance_gain(distance, ref_distance, KRUNKER_ROLLOFF),
		azimuth = azimuth, elevation = elevation,
	}
}

// The mixer runs in miniaudio's C thread. Its only Odin code is Spatial_Node,
// which reads per-voice parameters through a sequence lock and never touches
// gameplay memory. Voices share decoded samples and have bounded cost.
audio_play :: proc(audio: ^Audio_System, path: string, channel: Audio_Channel = .EFFECTS,
	gain: f32 = 1, position: shared.Vec3 = {}, spatial: bool = false, range: f32 = KRUNKER_MAX_DISTANCE, priority: int = 2,
	ref_distance: f32 = KRUNKER_REF_DISTANCE, rate: f32 = 1) -> bool {
	if audio == nil || audio.settings.master <= 0 || audio_channel_gain(audio.settings, channel) <= 0 { return false }
	if spatial && !audio.nodes_ready { return false }
	if spatial {
		delta := position - audio.listener.position
		if delta.x*delta.x + delta.y*delta.y + delta.z*delta.z > range*range { return false }
	}
	sample := audio_load_sample(audio, path)
	if sample == nil || !sample.ready { return false }
	chosen := -1
	for &voice, i in audio.voices {
		if voice.sample == nil || !bool(ma.sound_is_playing(&voice.sound)) { chosen = i; break }
		if chosen < 0 || voice.priority < audio.voices[chosen].priority ||
			voice.priority == audio.voices[chosen].priority && voice.serial < audio.voices[chosen].serial { chosen = i }
	}
	voice := &audio.voices[chosen]
	if voice.sample != nil && bool(ma.sound_is_playing(&voice.sound)) && voice.priority > priority { return false }
	if voice.sample != sample {
		if voice.sample != nil { ma.sound_uninit(&voice.sound); voice.sample = nil }
		// miniaudio's own spatializer is bypassed: every voice feeds its Spatial_Node,
		// which applies Krunker's panner model (or passes non-spatial audio through).
		if ma.sound_init_copy(&audio.engine, &sample.sound, {.NO_SPATIALIZATION, .NO_DEFAULT_ATTACHMENT}, nil, &voice.sound) != .SUCCESS { return false }
		target := audio.nodes_ready ? cast(^ma.node)&voice.node : ma.engine_get_endpoint(&audio.engine)
		if ma.node_attach_output_bus(cast(^ma.node)&voice.sound, 0, target, 0) != .SUCCESS {
			ma.sound_uninit(&voice.sound)
			return false
		}
		voice.sample = sample
	} else { ma.sound_stop(&voice.sound) }
	ma.sound_seek_to_pcm_frame(&voice.sound, 0)
	voice.channel, voice.gain, voice.priority = channel, gain, priority
	voice.spatial, voice.position, voice.ref_distance = spatial, position, ref_distance
	voice.stereo_source = audio_sample_is_stereo(sample)
	audio.serial += 1
	voice.serial = audio.serial
	ma.sound_set_volume(&voice.sound, gain * audio_channel_gain(audio.settings, channel))
	// Howler's rate(): playback speed, which also shifts the pitch.
	ma.sound_set_pitch(&voice.sound, rate > 0 ? rate : 1)
	// A reused voice must not inherit the previous sound's direction or filter
	// state; the reset flag makes the mixer snap instead of ramping from it.
	if audio.nodes_ready {
		params := spatial ? audio_spatial_params(audio.listener, position, ref_distance, voice.stereo_source) : Spatial_Params{}
		spatial_node_publish(&voice.node, params, true)
	}
	return ma.sound_start(&voice.sound) == .SUCCESS
}

audio_sample_is_stereo :: proc(sample: ^Audio_Sample) -> bool {
	format: ma.format
	channels, rate: u32
	if ma.sound_get_data_format(&sample.sound, &format, &channels, &rate, nil, 0) != .SUCCESS { return true }
	return channels >= 2
}

audio_play_effect :: proc(audio: ^Audio_System, name: string, channel: Audio_Channel = .EFFECTS,
	gain: f32 = 1, position: shared.Vec3 = {}, spatial: bool = false, range: f32 = KRUNKER_MAX_DISTANCE, priority: int = 2, rate: f32 = 1) -> bool {
	return audio_play(audio, fmt.tprintf("%ssound/%s.mp3", shared.assets_path(), name), channel, gain, position, spatial, range, priority, rate = rate)
}
