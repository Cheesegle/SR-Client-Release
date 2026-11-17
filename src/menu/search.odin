package menu

import "core:fmt"
import clay "../third_party/clay"

// Krunker's settings header has a 220px "Search" field (settSearch). Its
// searchMatches is a case-insensitive substring test on the setting name or its
// category header, across every tab, with results under their category headers.
// SR Client keeps that presentation but matches fuzzily: every substring still
// matches, and so do abbreviations such as "shp" for "Show Ping".
SEARCH_MAX :: 64
SEARCH_LABEL_MAX :: 128

@(private="file")
search_lower :: proc(c: u8) -> u8 { return c >= 'A' && c <= 'Z' ? c+32 : c }

@(private="file")
search_alnum :: proc(c: u8) -> bool { return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' }

@(private="file")
search_word_start :: proc(label: string, i: int) -> bool {
	if i == 0 { return true }
	previous, current := label[i-1], label[i]
	return !search_alnum(previous) || previous >= 'a' && previous <= 'z' && current >= 'A' && current <= 'Z'
}

// Best-alignment subsequence score. Each matched character scores 1, plus 2 at
// a word start and 2 when it continues the previous match; a skipped gap costs
// 1 and matching the label's first character adds 1. Spaces in the query are
// ignored so "show ping" and "showping" behave alike.
fuzzy_score :: proc(query, label: string) -> (score: int, ok: bool) {
	NONE :: min(int)/4
	q: [SEARCH_MAX]u8
	n := 0
	for i in 0..<len(query) {
		if query[i] == ' ' || n >= len(q) { continue }
		q[n] = search_lower(query[i]); n += 1
	}
	if n == 0 { return 0, true }
	m := min(len(label), SEARCH_LABEL_MAX)
	if n > m { return 0, false }
	previous, current: [SEARCH_LABEL_MAX]int
	for i in 0..<n {
		best_before := NONE // Best previous-row score ending at or before j-2.
		for j in 0..<m {
			if i > 0 && j >= 2 { best_before = max(best_before, previous[j-2]) }
			current[j] = NONE
			if search_lower(label[j]) != q[i] { continue }
			base := 1 + (search_word_start(label, j) ? 2 : 0)
			if i == 0 {
				current[j] = base + (j == 0 ? 1 : 0)
				continue
			}
			link := NONE
			if j >= 1 && previous[j-1] > NONE { link = previous[j-1] + 2 }
			if best_before > NONE { link = max(link, best_before - 1) }
			if link > NONE { current[j] = base + link }
		}
		previous = current
	}
	score = NONE
	for j in 0..<m { score = max(score, previous[j]) }
	return score, score > NONE
}

// Weak scattered matches are rejected: a match must average about two points
// per query character. Any contiguous substring always clears this bar.
fuzzy_match :: proc(query, label: string) -> bool {
	n := 0
	for i in 0..<len(query) { if query[i] != ' ' { n += 1 } }
	score, ok := fuzzy_score(query, label)
	return ok && score >= 2*n-1
}

// Words that mean the same thing in setting labels, so "disable cats" finds
// "Hide cats" and "enable ping" finds "Show Ping". Labels keep their wording.
@(private="file")
SEARCH_SYNONYMS := [][]string{
	{"hide", "disable", "remove"},
	{"show", "enable", "display"},
}

@(private="file")
search_word_equal :: proc(a, b: string) -> bool {
	if len(a) != len(b) { return false }
	for i in 0..<len(a) { if search_lower(a[i]) != search_lower(b[i]) { return false } }
	return true
}

// fuzzy_match on the label, or on the label with one synonym word swapped for
// another in its group (whole words only).
search_label_match :: proc(query, label: string) -> bool {
	if fuzzy_match(query, label) { return true }
	start := 0
	for start < len(label) {
		for start < len(label) && !search_alnum(label[start]) { start += 1 }
		end := start
		for end < len(label) && search_alnum(label[end]) { end += 1 }
		word := label[start:end]
		for group in SEARCH_SYNONYMS {
			in_group := false
			for w in group { if search_word_equal(w, word) { in_group = true; break } }
			if !in_group { continue }
			for w in group {
				if search_word_equal(w, word) { continue }
				if fuzzy_match(query, fmt.tprintf("%s%s%s", label[:start], w, label[end:])) { return true }
			}
		}
		start = end
	}
	return false
}

settings_search_query :: proc(state: ^State) -> string { return string(state.search_buffer[:state.search_length]) }

settings_searching :: proc(state: ^State) -> bool {
	for c in state.search_buffer[:state.search_length] { if c != ' ' { return true } }
	return false
}

settings_search_focused :: proc(state: ^State) -> bool {
	return (state.page == .SETTINGS || state.page == .CONTROLS) && state.focus == clay.ID("SettingsSearch").id
}

// The tab whose rows are being laid out: the selected tab, or each tab in turn
// while search results are shown.
settings_current_tab :: proc(state: ^State) -> Settings_Tab {
	return settings_searching(state) ? state.search_tab : state.settings_tab
}

settings_search_scroll_top :: proc() {
	data := clay.GetScrollContainerData(clay.ID("SettingsPanel"))
	if data.found { data.scrollPosition^ = {} }
}

settings_search_clear :: proc(state: ^State) {
	if state.search_length > 0 { settings_search_scroll_top() }
	state.search_length = 0
}

// Row helpers call this before drawing. Outside search it always returns true.
// In search mode, tab and section headings are deferred until their first
// visible row, so empty groups never appear.
settings_search_show :: proc(state: ^State, label: string) -> bool {
	if !settings_searching(state) { return true }
	query := settings_search_query(state)
	// "crosshair size" finds Size under Crosshair, as well as the label alone.
	if !state.search_section_match && !search_label_match(query, label) && (len(state.search_section) == 0 || !search_label_match(query, fmt.tprintf("%s %s", state.search_section, label))) { return false }
	s := state.scale
	if state.search_tab_pending {
		state.search_tab_pending = false
		if clay.UI()({layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(56*s)}, padding = {top = u16(12*s)}, childAlignment = {y = .Center}}, border = {color = SETTINGS_LINE, width = {bottom = 1}}}) {
			text(SETTINGS_TABS[state.search_tab], 24, s)
		}
	}
	if state.search_section_pending {
		state.search_section_pending = false
		settings_section_label(state.search_section, s)
	}
	state.search_found = true
	return true
}

// Lays out every tab, keeping only matching rows, under tab and section headings.
settings_search_results :: proc(state: ^State, view: View) {
	state.search_found = false
	query := settings_search_query(state)
	for tab in Settings_Tab {
		state.search_tab, state.search_tab_pending = tab, true
		state.search_tab_match = fuzzy_match(query, SETTINGS_TABS[tab])
		state.search_section, state.search_section_pending, state.search_section_match = "", false, state.search_tab_match
		settings_tab_content(state, view, tab)
	}
	if !state.search_found {
		if clay.UI(clay.ID("SettingsSearchEmpty"))({layout = {sizing = {width = clay.SizingGrow()}, padding = {top = u16(20*state.scale), bottom = u16(16*state.scale)}}}) {
			text("No settings found", 18, state.scale, SETTINGS_MUTED)
		}
	}
}

settings_search_field :: proc(state: ^State) {
	s := state.scale
	id := clay.ID("SettingsSearch")
	register(state, {id = id, action = {kind = .SETTINGS_SEARCH}, enabled = true})
	focused := state.focus == id.id
	if clay.UI(id)({
		layout = {sizing = {width = clay.SizingFixed(220*s), height = clay.SizingFixed(48*s)}, padding = {left = u16(12*s), right = u16(12*s)}, childAlignment = {y = .Center}},
		backgroundColor = {231, 229, 235, 255}, cornerRadius = clay.CornerRadiusAll(4*s),
		border = {color = focused ? WHITE : SETTINGS_LINE, width = clay.BorderOutside(focused ? 2 : 1)},
		clip = {horizontal = true},
	}) {
		value := settings_search_query(state)
		if len(value) == 0 && !focused {
			text("Search", 20, s, SETTINGS_MUTED)
		} else {
			// Keep the end of a long query, where the caret is, in view.
			LIMIT :: 14
			if len(value) > LIMIT { value = value[len(value)-LIMIT:] }
			text(focused ? fmt.tprintf("%s|", value) : value, 20, s, SETTINGS_DARK)
		}
	}
}

// Text typed while the search field has focus. Like the invite field, this is
// handled entirely in the menu, so typed letters never reach key bindings.
settings_search_input :: proc(state: ^State, input: Input) {
	length := state.search_length
	changed := false
	if input.clear_text && length > 0 { length, changed = 0, true }
	if input.backspace && !state.previous.backspace && length > 0 { length -= 1; changed = true }
	for i in 0..<len(input.text) {
		c := input.text[i]
		if c < 32 || c >= 127 || c == '`' || length >= len(state.search_buffer) { continue }
		state.search_buffer[length] = c
		length += 1
		changed = true
	}
	if changed {
		state.search_length = length
		settings_search_scroll_top()
	}
}
