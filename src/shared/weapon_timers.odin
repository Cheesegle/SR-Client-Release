package shared

import "core:math"

// Krunker's procInputs (the same code on its client and its server) keeps the
// weapon timers in milliseconds as JS numbers (f64) and steps them by the
// command's whole-ms duration:
//   this.reloadTimer>0&&(this.reloadTimer-=u, ... this.reloadTimer<=0 ...)
//   this.swapTime>0&&(this.swapTime-=u,this.swapTime<0&&(this.swapTime=0))
//   this.reloads[ot]>0&&(this.reloads[ot]-=u,this.reloads[ot]<0&&(this.reloads[ot]=0))
//   this.reloads[this.loadoutIndex]<=0&&this.swapTime<=0&&this.reloadTimer<=0
// SR keeps the same f64 ms values, so a shot becomes possible on exactly the
// command where Krunker's server allows it, including non-default fire-rate
// and reload-speed multipliers (no rounding threshold).

// The weapon registry stores Krunker's ms values (rate 450, reload 900,
// swapTime 200) as f32 seconds; recover the exact decimal ms (0.45 -> 450).
weapon_seconds_to_ms :: proc(seconds: f32) -> f64 {
	return math.round(f64(seconds) * 1e6) / 1e3
}

// A gameplay multiplier (fiRat, reSpd) as the decimal JS holds.
weapon_timer_multiplier :: proc(multiplier: f32) -> f64 {
	return math.round(f64(multiplier) * 1e6) / 1e6
}

// A command's duration in ms (Krunker's u). Live Krunker durations are whole
// ms; offline durations round to a microsecond on client and server alike.
input_delta_ms :: proc(delta: f32) -> f64 {
	return math.round(f64(delta) * 1e6) / 1e3
}

// Krunker: t>0&&(t-=u,t<0&&(t=0)).
weapon_timer_tick :: proc(timer: ^f64, ms: f64) {
	if timer^ > 0 {
		timer^ -= ms
		if timer^ < 0 { timer^ = 0 }
	}
}

// reloads[loadoutIndex]=(burst?burstR:rate)*(config.fiRat||1)
player_fire_cooldown_ms :: proc(player: ^Player, burst: bool = false) -> f64 {
	rate := burst ? player.weapon.burst_rate : player.weapon.rate
	return weapon_seconds_to_ms(rate) * weapon_timer_multiplier(player.game.config.fire_rate)
}

// reloadTimer=weapon.reload*(config.reSpd||1)
player_reload_duration_ms :: proc(player: ^Player) -> f64 {
	return weapon_seconds_to_ms(player.weapon.reload_time) * weapon_timer_multiplier(player.game.config.reload_speed)
}

// Reload progress 0..1 for presentation (view model, HUD bar); 0 when idle.
player_reload_progress :: proc(player: ^Player) -> f32 {
	if player.reload_timer_ms <= 0 || player.weapon == nil || player.game == nil { return 0 }
	total := player_reload_duration_ms(player)
	if total <= 0 { return 0 }
	return f32(clamp(1 - player.reload_timer_ms / total, 0, 1))
}
