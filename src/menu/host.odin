package menu

import "core:fmt"
import clay "../third_party/clay"

// Host game: Krunker's Comp Server Setup (Select, Game Settings, Advanced,
// Server, Start Game) in SR Client's settings colours. Game Settings and
// Server are shown but locked, as they are for Krunker's comp setup. The
// values here are sent to Krunker exactly as its page sends them.
//
// Performance: drawn only while the host page is open; nothing per frame in
// a match.

Host_Tab :: enum { SELECT, GAME_SETTINGS, ADVANCED, SERVER }
HOST_TAB_LABELS := [Host_Tab]string{.SELECT = "Select", .GAME_SETTINGS = "Game Settings", .ADVANCED = "Advanced", .SERVER = "Server"}

Host_Map :: struct { id: i32, name: string }
// Krunker's comp map pool, in the order its Select tab lists it.
HOST_MAPS := [?]Host_Map{
	{0, "Burg"}, {2, "Sandstorm"}, {4, "Undergrowth"}, {5, "Shipment"}, {11, "Industry"}, {12, "Lumber"},
	{14, "Site"}, {17, "Bureau"}, {23, "Atomic"}, {36, "Lush"}, {39, "Eterno Simulator"}, {42, "Frontier"},
}
HOST_MAP_COUNT :: len(HOST_MAPS)

// Krunker's class order (classLim0..classLim15).
HOST_CLASS_NAMES := [16]string{"Triggerman", "Hunter", "Run N Gun", "Spray N Pray", "Vince", "Detective", "Marksman", "Rocketeer", "Agent", "Runner", "Deagler", "Bowman", "Commando", "Trooper", "Survivor", "Infiltrator"}
HOST_CLASS_LIMITS_DEFAULT := [16]i32{1, 1, 1, 1, 1, 1, 1, 0, 1, 0, 0, 0, 1, 1, 0, 1}
HOST_TEAM_SIZES := [4]string{"1v1", "2v2", "3v3", "4v4"}

// Number fields (Host_Value): key, label, minimum, maximum, step, default.
Host_Value :: enum { GAME_TIME, ROUNDS, INTERMISSION, OBJECTIVE_TIME, HITBOX_PAD, HURTBOX_SCALE, SPEC_SLOTS }
Host_Value_Info :: struct { key, label: string, minimum, maximum, step, default: f32 }
HOST_VALUES := [Host_Value]Host_Value_Info{
	.GAME_TIME      = {"gameTime", "Game Time (min)", 0, 60, 1, 4},
	.ROUNDS         = {"gamRounds", "Rounds", 1, 10, 1, 3},
	.INTERMISSION   = {"intermTmr", "Intermission Timer (s)", 5, 120, 1, 30},
	.OBJECTIVE_TIME = {"objtvTime", "Objective Time Mlt", 0.1, 10, 0.1, 1},
	.HITBOX_PAD     = {"hitBoxPad", "Hitbox Padding", -2, 2, 0.1, 0.1},
	.HURTBOX_SCALE  = {"hurtboxScale", "Hurtbox Scale", 1, 2, 0.1, 1},
	.SPEC_SLOTS     = {"specSlots", "Spectator Slots", 0, 4, 1, 2},
}

Host_Toggle :: enum { ALLOW_SPECTATE, TRANSFER_HOST, NO_COSMETICS, TEST_COMP, NO_DRAWS, BEST_OF_ROUNDS, HEAD_CLIP_FIX, RAMP_FIX, LIMIT_CLASSES }
Host_Toggle_Info :: struct { key, label: string }
HOST_TOGGLES := [Host_Toggle]Host_Toggle_Info{
	.ALLOW_SPECTATE = {"allowSpect", "Allow Spectating"},
	.TRANSFER_HOST  = {"transferHostOnLeave", "Transfer Host on Leave"},
	.NO_COSMETICS   = {"noCosm", "Disable Cosmetics"},
	.TEST_COMP      = {"tstCmp", "Test Competitive"},
	.NO_DRAWS       = {"noDraws", "No Draws"},
	.BEST_OF_ROUNDS = {"bstOfR", "Best of Rounds"},
	.HEAD_CLIP_FIX  = {"headClipFix", "Head Clip Fix"},
	.RAMP_FIX       = {"rampFix", "Ramp Fix"},
	.LIMIT_CLASSES  = {"limitClasses", "Limit Classes"},
}

Host_Text :: enum { TEAM1, TEAM2, WEBHOOK }
HOST_TEXT_LABELS := [Host_Text]string{.TEAM1 = "Team 1 Name", .TEAM2 = "Team 2 Name", .WEBHOOK = "Discord Webhook"}
HOST_TEXT_MAX :: 200

Host_Settings :: struct {
	maps:        bit_set[0..<HOST_MAP_COUNT], // indexes into HOST_MAPS
	values:      [Host_Value]f32,
	toggles:     bit_set[Host_Toggle],
	team_size:   i32, // tmSize: 0 = 1v1 ... 3 = 4v4
	class_limit: [16]i32,
	text:        [Host_Text][HOST_TEXT_MAX]u8,
	text_length: [Host_Text]int,
}

host_settings_default :: proc() -> (settings: Host_Settings) {
	settings.maps = {0}
	for info, value in HOST_VALUES { settings.values[value] = info.default }
	settings.toggles = ~bit_set[Host_Toggle]{}
	settings.team_size = 3
	settings.class_limit = HOST_CLASS_LIMITS_DEFAULT
	host_text_set(&settings, .TEAM1, "Alpha")
	host_text_set(&settings, .TEAM2, "Bravo")
	return
}

host_text :: proc(settings: ^Host_Settings, field: Host_Text) -> string { return string(settings.text[field][:settings.text_length[field]]) }
host_text_set :: proc(settings: ^Host_Settings, field: Host_Text, value: string) {
	settings.text_length[field] = 0
	for c in transmute([]u8)value {
		if c < 32 || c >= 127 || settings.text_length[field] >= HOST_TEXT_MAX { continue }
		settings.text[field][settings.text_length[field]] = c
		settings.text_length[field] += 1
	}
}
// Clamped and snapped to the field's step, as Krunker's inputs do.
host_value_set :: proc(settings: ^Host_Settings, value: Host_Value, number: f32) {
	if number != number { return } // NaN
	info := HOST_VALUES[value]
	snapped := f32(int((number - info.minimum) / info.step + 0.5)) * info.step + info.minimum
	if number < info.minimum { snapped = info.minimum }
	settings.values[value] = clamp(snapped, info.minimum, info.maximum)
}

host_text_id :: proc(field: Host_Text) -> clay.ElementId { return clay.ID("HostText", u32(field)) }

host_text_focused :: proc(state: ^State) -> (Host_Text, bool) {
	if state.page != .HOST { return {}, false }
	for field in Host_Text { if state.focus == host_text_id(field).id { return field, true } }
	return {}, false
}

// Typing in a focused text field (team names, webhook).
host_text_input :: proc(state: ^State, input: Input) {
	field, ok := host_text_focused(state)
	if !ok { return }
	length := &state.host.text_length[field]
	if input.clear_text { length^ = 0 }
	if input.backspace && !state.previous.backspace && length^ > 0 { length^ -= 1 }
	limit := field == .WEBHOOK ? HOST_TEXT_MAX : 24
	for c in input.text {
		if c >= 32 && c < 127 && c != '`' && length^ < limit {
			state.host.text[field][length^] = u8(c); length^ += 1
		}
	}
}

host_typing :: proc(state: ^State) -> bool { _, ok := host_text_focused(state); return ok }

host_open :: proc(state: ^State) {
	if state.page == .HOME { state.return_focus = state.focus }
	state.page, state.host_tab, state.pressed = .HOST, .SELECT, 0
	state.focus = clay.ID("HostTab", u32(Host_Tab.SELECT)).id
}

// Menu-side host actions; Start Game goes to the client.
host_activate :: proc(state: ^State, control: Control) -> (Action, bool) {
	action := control.action
	#partial switch action.kind {
	case .HOST_TAB:
		tab := Host_Tab(clamp(action.index, 0, len(Host_Tab)-1))
		if tab == .GAME_SETTINGS || tab == .SERVER { return {}, true } // Locked for comp, as in Krunker.
		state.host_tab, state.pressed = tab, 0
		data := clay.GetScrollContainerData(clay.ID("SettingsPanel"))
		if data.found { data.scrollPosition^ = {} }
		return {}, true
	case .HOST_MAP:
		index := int(clamp(action.index, 0, HOST_MAP_COUNT-1))
		// Krunker's Select toggles maps; at least one stays selected.
		if index in state.host.maps { if card(state.host.maps) > 1 { state.host.maps -= {index} } }
		else { state.host.maps += {index} }
		state.pressed = 0
		return {}, true
	case .HOST_VALUE:
		if action.index >= 0 && action.index < i32(len(Host_Value)) { host_value_set(&state.host, Host_Value(action.index), action.value) }
		return {}, true
	case .HOST_TOGGLE:
		if action.index >= 0 && action.index < i32(len(Host_Toggle)) { state.host.toggles ~= {Host_Toggle(action.index)} }
		state.pressed = 0
		return {}, true
	case .HOST_TEAM_SIZE:
		state.host.team_size, state.pressed = clamp(action.index, 0, 3), 0
		return {}, true
	case .HOST_CLASS_LIMIT:
		if action.index >= 0 && action.index < 16 && action.value == action.value { state.host.class_limit[action.index] = i32(clamp(action.value + 0.5, 0, 20)) }
		return {}, true
	case .HOST_TEXT:
		state.pressed = 0
		return {}, true // Clicking the field focuses it; typing is handled in interact.
	case .HOST_CLOSE:
		state.page, state.pressed, state.focus = .HOME, 0, state.return_focus
		state.number_edit = .NONE
		return {}, true
	case .HOST_START:
		state.pressed = 0
		return action, true
	}
	return {}, false
}

host_slider_value :: proc(state: ^State, action: Action) -> (f32, bool) {
	#partial switch action.kind {
	case .HOST_VALUE: if action.index >= 0 && action.index < i32(len(Host_Value)) { return state.host.values[Host_Value(action.index)], true }
	case .HOST_CLASS_LIMIT: if action.index >= 0 && action.index < 16 { return f32(state.host.class_limit[action.index]), true }
	}
	return 0, false
}

host_window :: proc(state: ^State, view: View) {
	s := state.scale
	// A page of the menu (between its header and footer), not a popup.
	if clay.UI(clay.ID("HostPage"))({
		layout = {sizing = {width = clay.SizingGrow({0, 1360*s}), height = clay.SizingGrow()}, layoutDirection = .TopToBottom},
		backgroundColor = SETTINGS_BG, cornerRadius = clay.CornerRadiusAll(12*s),
		border = {color = {131, 127, 140, 255}, width = clay.BorderOutside(1)},
	}) {
		// Header: the comp banner, the title, and Krunker's four tabs.
		if clay.UI(clay.ID("HostHeader"))({layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(96*s)}, padding = {right = u16(24*s)}, childGap = u16(12*s), childAlignment = {y = .Center}}, backgroundColor = SETTINGS_DARK, border = {color = SETTINGS_LINE, width = {bottom = 1}}}) {
			banner := clay.ID("HostBanner")
			if clay.UI(banner)({layout = {sizing = {width = clay.SizingFixed(320*s), height = clay.SizingGrow()}, padding = {left = u16(24*s)}, childAlignment = {y = .Center}}}) {
				if view.host_banner != nil {
					if clay.UI()({layout = {sizing = {width = clay.SizingFixed(320*s), height = clay.SizingFixed(95*s)}}, image = {imageData = view.host_banner}, floating = {attachTo = .ElementWithId, parentId = banner.id, zIndex = 11, pointerCaptureMode = .Passthrough, attachment = {element = .LeftTop, parent = .LeftTop}}}) {}
				}
				if clay.UI()({layout = {padding = {left = u16(10*s), right = u16(10*s), top = u16(4*s), bottom = u16(4*s)}}, backgroundColor = {0, 0, 0, 140}, floating = {attachTo = .ElementWithId, parentId = banner.id, zIndex = 12, pointerCaptureMode = .Passthrough, attachment = {element = .LeftCenter, parent = .LeftCenter}, offset = {24*s, 0}}}) { text("COMPETITIVE", 26, s) }
			}
			for tab in Host_Tab {
				locked := tab == .GAME_SETTINGS || tab == .SERVER
				if clay.UI()({layout = {sizing = {width = clay.SizingFixed(184*s)}}}) {
					settings_button(state, HOST_TAB_LABELS[tab], "HostTab", {kind = .HOST_TAB, index = i32(tab)}, selected = tab == state.host_tab, enabled = !locked)
				}
			}
			spacer()
		}
		if clay.UI(clay.ID("SettingsPanel"))({
			layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingGrow()}, layoutDirection = .TopToBottom, padding = clay.PaddingAll(u16(32*s))},
			clip = {vertical = true, childOffset = clay.GetScrollOffset()},
		}) {
			switch state.host_tab {
			case .SELECT, .GAME_SETTINGS, .SERVER: host_select(state, view)
			case .ADVANCED: host_advanced(state, view)
			}
		}
		settings_scrollbar(state)
		if clay.UI(clay.ID("HostFooter"))({
			layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(88*s)}, padding = {left = u16(24*s), right = u16(24*s)}, childGap = u16(24*s), childAlignment = {y = .Center}},
			backgroundColor = SETTINGS_DARK, border = {color = SETTINGS_LINE, width = {top = 1}},
		}) {
			if clay.UI()({layout = {sizing = {width = clay.SizingFixed(184*s)}}}) { settings_button(state, "Cancel", "HostCancel", {kind = .HOST_CLOSE}) }
			spacer()
			text(host_summary(state, view), 18, s, SETTINGS_MUTED)
			spacer()
			if clay.UI()({layout = {sizing = {width = clay.SizingFixed(184*s)}}}) { settings_button(state, "Start Game", "HostStart", {kind = .HOST_START}, selected = true, enabled = view.host_can_start) }
		}
	}
}

host_summary :: proc(state: ^State, view: View) -> string {
	names := ""
	count := 0
	for host_map, index in HOST_MAPS {
		if index not_in state.host.maps { continue }
		names = count == 0 ? host_map.name : fmt.tprintf("%s, %s", names, host_map.name)
		count += 1
	}
	// The region is Settings > General > Default Region, as in Krunker.
	return fmt.tprintf("Comp %s  ·  %s  ·  %s", HOST_TEAM_SIZES[clamp(state.host.team_size, 0, 3)], names, default_region(view.hud).name)
}

// Select: Krunker's comp map tiles, four to a row.
host_select :: proc(state: ^State, view: View) {
	s := state.scale
	settings_section_label("Maps", s)
	COLUMNS :: 4
	for row in 0 ..< (HOST_MAP_COUNT + COLUMNS - 1) / COLUMNS {
		if clay.UI()({layout = {sizing = {width = clay.SizingGrow()}, childGap = u16(16*s), padding = {bottom = u16(16*s)}}}) {
			for column in 0 ..< COLUMNS {
				index := row*COLUMNS + column
				if index >= HOST_MAP_COUNT { break }
				host_map_tile(state, view, index)
			}
		}
	}
}

host_map_tile :: proc(state: ^State, view: View, index: int) {
	s := state.scale
	id := clay.ID("HostMap", u32(index))
	register(state, {id = id, action = {kind = .HOST_MAP, index = i32(index)}, enabled = true})
	selected := index in state.host.maps
	border := selected ? SETTINGS_ORANGE : state.focus == id.id ? WHITE : SETTINGS_LINE
	if clay.PointerOver(id) && !selected { border = {137, 133, 146, 255} }
	if clay.UI(id)({
		layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(196*s)}, layoutDirection = .TopToBottom},
		backgroundColor = SETTINGS_DARK, cornerRadius = clay.CornerRadiusAll(4*s),
		border = {color = border, width = clay.BorderOutside(selected || state.focus == id.id ? 3 : 1)},
	}) {
		image := view.host_maps[index]
		if clay.UI()({layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingGrow()}}, backgroundColor = {57, 54, 64, 255}}) {
			if image != nil { if clay.UI()({layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingGrow()}}, image = {imageData = image}}) {} }
		}
		if clay.UI()({layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(44*s)}, padding = {left = u16(14*s)}, childAlignment = {y = .Center}}, backgroundColor = selected ? SETTINGS_ORANGE : SETTINGS_DARK}) {
			text(HOST_MAPS[index].name, 20, s)
		}
	}
}

host_toggle_row :: proc(state: ^State, toggle: Host_Toggle) {
	settings_toggle_row(state, HOST_TOGGLES[toggle].label, fmt.tprintf("HostToggle%d", int(toggle)), toggle in state.host.toggles, {kind = .HOST_TOGGLE, index = i32(toggle)})
}

host_value_row :: proc(state: ^State, value: Host_Value) {
	info := HOST_VALUES[value]
	settings_slider(state, info.label, fmt.tprintf("HostValue%d", int(value)), state.host.values[value], info.minimum, info.maximum, {kind = .HOST_VALUE, index = i32(value)}, step = info.step)
}

host_text_row :: proc(state: ^State, field: Host_Text) {
	s := state.scale
	if clay.UI()(settings_row(state)) {
		settings_label(HOST_TEXT_LABELS[field], s)
		id := host_text_id(field)
		register(state, {id = id, action = {kind = .HOST_TEXT, index = i32(field)}, enabled = true})
		focused := state.focus == id.id
		value := host_text(&state.host, field)
		if clay.UI(id)({
			layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(44*s)}, padding = {left = u16(12*s), right = u16(12*s)}, childAlignment = {y = .Center}},
			backgroundColor = clay.Color{231, 229, 235, 255}, cornerRadius = clay.CornerRadiusAll(4*s),
			border = {color = focused ? SETTINGS_ORANGE : SETTINGS_LINE, width = clay.BorderOutside(focused ? 2 : 0)},
			clip = {horizontal = true},
		}) {
			shown := focused ? fmt.tprintf("%s|", value) : len(value) == 0 && field == .WEBHOOK ? "Optional" : value
			text(shown, 20, s, len(value) == 0 && !focused ? SETTINGS_MUTED : SETTINGS_DARK)
		}
	}
}

// Advanced: every option Krunker's comp setup shows, in its order.
host_advanced :: proc(state: ^State, view: View) {
	s := state.scale
	settings_section_label("Server", s)
	host_value_row(state, .GAME_TIME)
	host_value_row(state, .ROUNDS)
	host_value_row(state, .INTERMISSION)
	settings_section_label("Mode", s)
	host_value_row(state, .OBJECTIVE_TIME)
	host_value_row(state, .HITBOX_PAD)
	host_value_row(state, .HURTBOX_SCALE)
	host_text_row(state, .TEAM1)
	host_text_row(state, .TEAM2)
	settings_section_label("Other", s)
	host_toggle_row(state, .ALLOW_SPECTATE)
	settings_section_label("Hosting", s)
	host_toggle_row(state, .TRANSFER_HOST)
	host_value_row(state, .SPEC_SLOTS)
	if clay.UI()(settings_row(state)) {
		settings_label("Team Size", s)
		spacer()
		for size, index in HOST_TEAM_SIZES {
			if clay.UI()({layout = {sizing = {width = clay.SizingFixed(112*s)}}}) {
				settings_button(state, size, "HostTeamSize", {kind = .HOST_TEAM_SIZE, index = i32(index)}, selected = state.host.team_size == i32(index))
			}
		}
	}
	host_toggle_row(state, .NO_COSMETICS)
	host_toggle_row(state, .TEST_COMP)
	host_toggle_row(state, .NO_DRAWS)
	host_toggle_row(state, .BEST_OF_ROUNDS)
	host_toggle_row(state, .HEAD_CLIP_FIX)
	host_toggle_row(state, .RAMP_FIX)
	host_text_row(state, .WEBHOOK)
	settings_section_label("Class Limits", s)
	host_toggle_row(state, .LIMIT_CLASSES)
	if .LIMIT_CLASSES in state.host.toggles {
		for name, index in HOST_CLASS_NAMES {
			settings_slider(state, name, fmt.tprintf("HostClass%d", index), f32(state.host.class_limit[index]), 0, 20, {kind = .HOST_CLASS_LIMIT, index = i32(index)}, step = 1)
		}
	}
}
