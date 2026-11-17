package main

import menuui "../menu"
import shared "../shared"

// Self shadow (a SR Client addition, not in Krunker): your own body casts a
// shadow while you play in first person.
//
// The local player only has a viewmodel (render_you meshes in fps_scene). For
// the shadow we build a second, third-person rig for the same player, exactly
// as a remote player is built (player_generate_meshes with render_you false),
// and keep it out of every scene: it is only drawn into the small player
// shadow map. Each frame it is posed like a remote player at your real
// position, look direction and walk cycle, except that crouch follows your
// continuous crouch value. The viewmodel never casts (fps_scene is not drawn
// into any shadow map) and never samples the player map, so your own body
// cannot darken your arms or gun.

Self_Shadow :: struct {
	player:    ^shared.Player,
	viewmodel: rawptr, // player.mesh the rig was built next to.
	loadout:   int,
	body:      ^Player_Mesh,
	scene:     ^Scene, // Private list of the rig's meshes; never rendered.
	builds:    int,
}

g_self_shadow: Self_Shadow
// player_rig_crouch: use the continuous crouch value for this rig.
g_rig_continuous_crouch: bool

self_shadow_release :: proc() {
	if g_self_shadow.body != nil {
		tmp: shared.Player
		tmp.mesh = g_self_shadow.body
		player_meshes_fini(&tmp)
	}
	if g_self_shadow.scene != nil { scene_fini(g_self_shadow.scene) }
	builds := g_self_shadow.builds
	g_self_shadow = {builds = builds}
}

@(private = "file")
self_shadow_build :: proc(player: ^shared.Player) {
	self_shadow_release()
	saved_mesh, saved_render_you := player.mesh, player.render_you
	player.mesh = nil
	player_generate_meshes(player, false)
	body := cast(^Player_Mesh)player.mesh
	player.mesh, player.render_you = saved_mesh, saved_render_you
	if body == nil { return }
	g_self_shadow.player = player
	g_self_shadow.viewmodel = saved_mesh
	g_self_shadow.loadout = int(player.loadout_size)
	g_self_shadow.body = body
	g_self_shadow.scene = scene_init()
	// Marks every part as a player caster and collects it in a list that is
	// only read by the shadow pass.
	scene_add_player_mesh(g_self_shadow.scene, body, int(player.loadout_size))
	g_self_shadow.builds += 1
}

// Returns the meshes to draw into the player shadow map this frame, or nil.
// Off, with Shadows off, or with no local player, it frees the rig.
self_shadow_update :: proc(client: ^Client, quality: menuui.Quality_Settings) -> []^Mesh {
	me := client.me
	enabled := quality.self_shadow && quality.shadows && quality.lighting != i32(menuui.Lighting_Quality.LOW)
	if !enabled || me == nil || !me.active || me.mesh == nil || client.game.map_inst == nil || client.game.map_inst.config.model == .SPRITE {
		if g_self_shadow.body != nil { self_shadow_release() }
		return nil
	}
	if g_self_shadow.player != me || g_self_shadow.viewmodel != me.mesh || g_self_shadow.loadout != int(me.loadout_size) {
		self_shadow_build(me)
		if g_self_shadow.body == nil { return nil }
	}
	self_shadow_pose(me, g_self_shadow.body)
	return g_self_shadow.scene.meshes[:]
}

// Poses `body` like a remote player at `player`'s state. player_update_meshes
// also eases two cosmetic fields on the player; restore them so the
// viewmodel's own update sees them unchanged.
self_shadow_pose :: proc(player: ^shared.Player, body: ^Player_Mesh) {
	saved_mesh, saved_render_you := player.mesh, player.render_you
	saved_land, saved_jump := player.land_bob_yr, player.jump_rotate_mlt
	player.mesh, player.render_you = body, false
	g_rig_continuous_crouch = true
	player_update_meshes(player, false)
	g_rig_continuous_crouch = false
	player.mesh, player.render_you = saved_mesh, saved_render_you
	player.land_bob_yr, player.jump_rotate_mlt = saved_land, saved_jump
}
