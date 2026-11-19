package main

import menuui "../menu"
import shared "../shared"

client_crosshair_values :: proc(client: ^Client) -> menuui.Crosshair_Settings {
	settings := client.crosshair_settings
	if client.menu.settings_active && client.menu.page == .SETTINGS { settings = client.menu.settings_draft.crosshair }
	return menuui.crosshair_settings_validate(settings)
}

client_crosshair_opacity :: proc(client: ^Client, settings: menuui.Crosshair_Settings) -> f32 {
	player := client.me
	if player == nil || !player.active || player.weapon == nil { return 0 }
	aim := player.aim_val
	if client.krunker.connected { aim = krunker_client_render_sample(client).aim }
	opacity := 1-clamp(aim, 0, 1)
	if player.inspecting || player.reload_timer_ms > 0 { opacity = 0 }
	if player_uses_third_person_camera(player) && !player.weapon.scope { opacity = 1 }
	return menuui.crosshair_opacity(settings, opacity)
}

crosshair_render :: proc(ui: ^UI, settings: menuui.Crosshair_Settings, cx, cy, scale, opacity: f32) {
	if opacity <= 0 || scale <= 0 { return }
	// Image crosshair; Precision is drawn while the image loads or if it fails.
	if settings.kind == .IMAGE {
		if texture := crosshair_image_texture(settings.image_url); texture != 0 {
			w, h := settings.values[.IMAGE_WIDTH]*scale, settings.values[.IMAGE_HEIGHT]*scale
			ui_draw_image(ui, texture, cx-w*0.5, cy-h*0.5, w, h, {1, 1, 1, opacity})
			return
		}
	}
	color := shared.hex_to_vec(i32(settings.color))
	shadow := shared.hex_to_vec(i32(settings.shadow_color))
	color.a, shadow.a = opacity, opacity
	boxes, count := menuui.crosshair_geometry(settings)
	for box, i in boxes[:count] {
		x, y := cx+box.x*scale, cy+box.y*scale
		w, h := box.width*scale, box.height*scale
		ui_fill_rect(ui, color, x, y, w, h)
		// Canvas strokes straddle the arm edge; the official dot has no shadow.
		if i == 0 && settings.toggles[.DOT] { continue }
		s := settings.values[.SHADOW]*scale
		if s <= 0 { continue }
		x -= s*0.5; y -= s*0.5; w += s; h += s
		xs, ys := min(s,w*0.5), min(s,h*0.5)
		ui_fill_rect(ui, shadow, x, y, w, ys)
		ui_fill_rect(ui, shadow, x, y+h-ys, w, ys)
		if h>2*ys {
			ui_fill_rect(ui, shadow, x, y+ys, xs, h-2*ys)
			ui_fill_rect(ui, shadow, x+w-xs, y+ys, xs, h-2*ys)
		}
	}
}
