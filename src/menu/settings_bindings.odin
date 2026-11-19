package menu

import clay "../third_party/clay"

settings_bindings :: proc(state: ^State) {
	s := state.scale
	settings_note(state, state.binding_reserved ? "Backtick is reserved for map rotation. Choose another key." : "Select a slot, then press a key or mouse button. Escape cancels. X, right-click or Delete unbinds a slot.")
	if !settings_searching(state) {
		if clay.UI()({layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(36*s)}, childGap = u16(24*s)}}) {
			if clay.UI()({layout = {sizing = {width = clay.SizingFixed(304*s)}}}) {}
			for label in ([]string{"Primary", "Alternate"}) {
				if clay.UI()({layout = {sizing = {width = clay.SizingGrow()}, childAlignment = {x = .Center}}}) { text(label, 16, s, SETTINGS_MUTED) }
			}
		}
	}
	// Display inspect with weapons and the leaderboard under Interface, as in
	// Krunker's controls list, while preserving saved enum values. The debug
	// overlay toggle sits beside the leaderboard.
	for action in ([len(Binding_Action)]Binding_Action{.FORWARD, .BACKWARD, .LEFT, .RIGHT, .JUMP, .CROUCH, .AIM, .FIRE, .RELOAD, .INSPECT, .PRIMARY, .SECONDARY, .MELEE, .LEADERBOARD, .CHAT, .DEBUG_OVERLAY, .MENU, .FULLSCREEN}) {
		if action == .FORWARD { settings_section(state, "Move") }
		if action == .AIM { settings_section(state, "Weapon") }
		if action == .LEADERBOARD { settings_section(state, "Interface") }
		if action == .MENU { settings_section(state, "System") }
		if !binding_visible(action) { continue }
		if !settings_search_show(state, BINDING_NAMES[action]) { continue }
		if clay.UI(clay.ID("BindingRow", u32(action)))({layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(60*s)}, childGap = u16(24*s), childAlignment = {y = .Center}}}) {
			settings_label(BINDING_NAMES[action], s)
			for slot in 0..<2 {
				index := i32(action)*2+i32(slot)
				code := state.settings_draft.bindings[action][slot]
				capturing := state.binding_capture == index+1
				if clay.UI()({layout = {sizing = {width = clay.SizingGrow()}, childGap = u16(6*s), childAlignment = {y = .Center}}}) {
					settings_button(state, capturing ? "Press a key..." : binding_label(code), "Binding", {kind = .BIND_KEY, index = index}, selected = capturing || slot == 0 && code != 0)
					settings_unbind_button(state, index, code != 0)
				}
			}
		}
	}
	settings_note(state, "Escape always remains available for opening and closing menus.")
}

// Krunker's Key binds rows carry a red "Unbind" icon (unbindCont, which
// stores -1 and shows "UNBOUND") beside each slot. Unbound slots keep the
// button in place, disabled, so both columns stay aligned.
settings_unbind_button :: proc(state: ^State, index: i32, enabled: bool) {
	s := state.scale
	id := clay.ID("Unbind", u32(index))
	register(state, {id = id, action = {kind = .UNBIND_KEY, index = index}, enabled = enabled})
	color := clay.Color{57, 54, 64, 255}
	if enabled && clay.PointerOver(id) { color = {190, 48, 48, 255} }
	if enabled && state.pressed == id.id { color = {150, 36, 36, 255} }
	if clay.UI(id)({
		layout = {sizing = {width = clay.SizingFixed(44*s), height = clay.SizingFixed(48*s)}, childAlignment = {x = .Center, y = .Center}},
		backgroundColor = color, cornerRadius = clay.CornerRadiusAll(3*s),
		border = {color = state.focus == id.id ? WHITE : SETTINGS_LINE, width = clay.BorderOutside(state.focus == id.id ? 2 : 1)},
	}) { text("X", 21, s, enabled ? clay.Color{255, 120, 120, 255} : SETTINGS_LINE) }
}

settings_dropdown_field :: proc(state: ^State, label, name: string, dropdown: Settings_Dropdown, enabled: bool = true) {
	s := state.scale
	id := clay.ID(name)
	register(state, {id = id, action = {kind = .SETTINGS_DROPDOWN, index = i32(dropdown)}, enabled = enabled})
	if clay.UI(id)({
		layout = {sizing = {width = clay.SizingFixed(360*s), height = clay.SizingFixed(48*s)}, padding = {left = u16(16*s)}, childAlignment = {y = .Center}},
		backgroundColor = {231, 229, 235, 255}, cornerRadius = clay.CornerRadiusAll(4*s),
		border = {color = state.focus == id.id ? WHITE : SETTINGS_LINE, width = clay.BorderOutside(state.focus == id.id ? 2 : 1)},
	}) {
		text(label, 20, s, enabled ? SETTINGS_DARK : SETTINGS_MUTED)
		spacer()
		if clay.UI()({layout = {sizing = {width = clay.SizingFixed(44*s), height = clay.SizingGrow()}, childAlignment = {x = .Center, y = .Center}}, backgroundColor = enabled ? SETTINGS_ORANGE : SETTINGS_LINE}) { text("v", 20, s) }
	}
}

settings_dropdown_menu :: proc(state: ^State, view: View) {
	if state.settings_dropdown == .NONE { return }
	s := state.scale
	mode_labels := [3]string{"Windowed", "Borderless", "Fullscreen"}
	filter_labels := [2]string{"Sharp", "Smooth"}
	anisotropy_labels := [5]string{"Off", "2x", "4x", "8x", "16x"}
	crosshair_labels := [2]string{"Precision", "Image"}
	shadow_quality_labels := [2]string{SHADOW_QUALITY_LABELS[.KRUNKER], SHADOW_QUALITY_LABELS[.SHARP]}
	lighting_labels := [4]string{LIGHTING_LABELS[.LOW], LIGHTING_LABELS[.NORMAL], LIGHTING_LABELS[.HIGH], LIGHTING_LABELS[.PHYSICAL]}
	labels: []string
	anchor: string
	action: Action_Kind
	switch state.settings_dropdown {
	case .NONE: return
	case .DISPLAY_MODE: labels, anchor, action = mode_labels[:], "DisplayMode", .DISPLAY_MODE
	case .MONITOR: labels, anchor, action = view.monitor_names, "Monitor", .MONITOR
	case .RESOLUTION: labels, anchor, action = settings_resolution_options(state, view), "Resolution", .RESOLUTION_SELECT
	case .TEXTURE_FILTER: labels, anchor, action = filter_labels[:], "TextureFiltering", .TEXTURE_FILTER
	case .LIGHTING: labels, anchor, action = lighting_labels[:], "Lighting", .LIGHTING
	case .SHADOW_QUALITY: labels, anchor, action = shadow_quality_labels[:], "ShadowQuality", .SHADOW_QUALITY
	case .CROSSHAIR_TYPE: labels, anchor, action = crosshair_labels[:], "CrosshairType", .CROSSHAIR_TYPE
	case .ANISOTROPY:
		count := 1
		for level in ([4]f32{2, 4, 8, 16}) { if level <= view.max_anisotropy { count += 1 } }
		labels, anchor, action = anisotropy_labels[:count], "Anisotropy", .ANISOTROPY
	case .MENU_FPS_LIMIT: labels, anchor, action = MENU_FPS_LIMIT_LABELS[:], "MenuFpsLimit", .MENU_FPS_LIMIT
	case .GAME_FPS_LIMIT: labels, anchor, action = GAME_FPS_LIMIT_LABELS[:], "GameFpsLimit", .GAME_FPS_LIMIT
	case .VRR_CAP: labels, anchor, action = VRR_CAP_LABELS[:], "VrrCap", .VRR_CAP
	case .INPUT_RATE: labels, anchor, action = INPUT_RATE_LABELS[:], "InputRate", .INPUT_RATE
	case .NET_MODE: labels, anchor, action = NET_MODE_LABELS[:], "NetMode", .NET_MODE
	case .MSAA:
		count := 1
		for level in MSAA_LEVELS[1:] { if level <= view.max_msaa { count += 1 } }
		labels, anchor, action = MSAA_LABELS[:count], "Msaa", .MSAA
	case .DEFAULT_REGION: labels, anchor, action = KRUNKER_REGION_LABELS[:], "DefaultRegion", .DEFAULT_REGION
	}
	// While open, Tab and arrow keys navigate the popup, not controls behind it.
	state.control_count = 0
	height := f32(min(5, len(labels)))*48*s+16*s
	anchor_box := clay.GetElementData(clay.ID(anchor)).boundingBox
	overlay_box := clay.GetElementData(clay.ID("Overlay")).boundingBox
	above := anchor_box.y+anchor_box.height+height > overlay_box.y+overlay_box.height-88*s
	if clay.UI(clay.ID("SettingsOptions"))({
		layout = {sizing = {width = clay.SizingFixed(360*s), height = clay.SizingFixed(height)}, layoutDirection = .TopToBottom, padding = clay.PaddingAll(u16(8*s))},
		backgroundColor = SETTINGS_DARK, border = {color = SETTINGS_LINE, width = clay.BorderOutside(1)},
		clip = {vertical = true, childOffset = clay.GetScrollOffset()},
		floating = {attachTo = .ElementWithId, parentId = clay.ID(anchor).id, zIndex = 12, attachment = {element = above ? .RightBottom : .RightTop, parent = above ? .RightTop : .RightBottom}},
	}) {
		for label, i in labels {
			id := clay.ID("SettingsOption", u32(i))
			enabled := true
			register(state, {id = id, action = {kind = action, index = i32(i)}, enabled = enabled})
			if clay.UI(id)({layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(48*s)}, padding = {left = u16(12*s), right = u16(12*s)}, childAlignment = {y = .Center}}, backgroundColor = enabled && (state.focus == id.id || clay.PointerOver(id)) ? SETTINGS_ORANGE : SETTINGS_DARK}) { text(shorten(label, 30), 20, s, enabled ? WHITE : SETTINGS_MUTED) }
		}
	}
}
