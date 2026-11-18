package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import glfw "vendor:glfw"
import menuui "../menu"
import kproto "../krunker"

// Tournament auto-host link: srclient://game?action=host-comp&... with the
// same parameters as Glorp's glorp://game?action=host-comp link, so a site
// only swaps the scheme. Opening it hosts Krunker's comp game exactly as the
// Host page's Start Game does (host_game.odin), with these filled in:
//   mapId       map name ("Sandstorm") or Krunker map id ("2")
//   teamSize    1v1 .. 4v4
//   team1Name, team2Name
//   webhook     Krunker's comp webhook (sent as the Host page's webhook)
//   compRosterT1 / team1Players, compRosterT2 / team2Players, spectators /
//   compRosterSpecs: Krunker's Team Rosters, comma-separated names
// comp=true is accepted (Host is always comp); unknown parameters are ignored.
// The installer registers the scheme (installer/sr-client.iss). A link opened
// while SR Client already runs is handed to that window (host_link_forward).
//
// Performance: one file check per second while connected or in menus; nothing
// else.

HOST_LINK_SCHEME :: "srclient://"
HOST_LINK_FILE_NAME :: "host-link.txt" // in %LOCALAPPDATA%\SR-Client
HOST_LINK_POLL :: time.Second

g_host_link_pending: string // a parsed-ok link waiting for the client to be ready
g_host_link_last_poll: time.Time

host_link_is :: proc(arg: string) -> bool {
	return len(arg) >= len(HOST_LINK_SCHEME) && strings.equal_fold(arg[:len(HOST_LINK_SCHEME)], HOST_LINK_SCHEME)
}

// URL decoding as a browser's URLSearchParams: '+' is a space, %XX a byte.
host_link_decode :: proc(value: string, allocator := context.temp_allocator) -> string {
	out := strings.builder_make(allocator)
	for i := 0; i < len(value); i += 1 {
		c := value[i]
		if c == '+' { strings.write_byte(&out, ' '); continue }
		if c == '%' && i + 2 < len(value) {
			if byte_value, ok := strconv.parse_u64_of_base(value[i + 1:i + 3], 16); ok {
				strings.write_byte(&out, u8(byte_value)); i += 2; continue
			}
		}
		strings.write_byte(&out, c)
	}
	return strings.to_string(out)
}

// Applies a link to host settings. The settings keep everything the link does
// not set (the host's saved Game Settings and Advanced values).
host_link_parse :: proc(link: string, settings: ^menuui.Host_Settings) -> (ok: bool, problem: string) {
	if !host_link_is(link) { return false, "not an srclient:// link" }
	rest := link[len(HOST_LINK_SCHEME):]
	path, _, query := strings.partition(rest, "?")
	path = strings.trim_right(path, "/")
	if !strings.equal_fold(path, "game") { return false, fmt.tprintf("unknown link target %q", path) }
	params := make(map[string]string, 16, context.temp_allocator)
	for pair in strings.split(query, "&", context.temp_allocator) {
		if len(pair) == 0 { continue }
		key, _, value := strings.partition(pair, "=")
		params[host_link_decode(key)] = host_link_decode(value)
	}
	action := params["action"] or_else ""
	if action != "host-comp" { return false, fmt.tprintf("unsupported action %q (only host-comp)", action) }
	if map_value, has := params["mapId"]; has {
		found := -1
		wanted := strings.trim_space(map_value)
		if id, is_number := strconv.parse_int(wanted); is_number {
			for host_map, index in menuui.HOST_MAPS { if int(host_map.id) == id { found = index } }
		} else {
			compact := strings.to_lower(strings.join(strings.fields(wanted, context.temp_allocator), "", context.temp_allocator), context.temp_allocator)
			for host_map, index in menuui.HOST_MAPS {
				name := strings.to_lower(strings.join(strings.fields(host_map.name, context.temp_allocator), "", context.temp_allocator), context.temp_allocator)
				if name == compact { found = index }
			}
		}
		if found < 0 { return false, fmt.tprintf("map %q is not in Krunker's comp map pool", map_value) }
		settings.maps = {found}
	}
	if size, has := params["teamSize"]; has {
		size = strings.to_lower(strings.trim_space(size))
		players := -1
		if len(size) == 3 && size[1] == 'v' && size[0] == size[2] && size[0] >= '1' && size[0] <= '4' { players = int(size[0] - '0') }
		else if n, is_number := strconv.parse_int(size); is_number && n >= 1 && n <= 4 { players = n }
		if players < 0 { return false, fmt.tprintf("team size %q is not 1v1 to 4v4", size) }
		settings.team_size = i32(players - 1)
	}
	// "" when set, else what is wrong.
	text :: proc(settings: ^menuui.Host_Settings, field: menuui.Host_Text, value: string, limit: int) -> string {
		if len(value) > limit { return fmt.tprintf("%s is longer than %d characters", menuui.HOST_TEXT_LABELS[field], limit) }
		menuui.host_text_set(settings, field, value)
		return ""
	}
	if name, has := params["team1Name"]; has { if bad := text(settings, .TEAM1, name, 24); len(bad) > 0 { return false, bad } }
	if name, has := params["team2Name"]; has { if bad := text(settings, .TEAM2, name, 24); len(bad) > 0 { return false, bad } }
	if hook, has := params["webhook"]; has { if bad := text(settings, .WEBHOOK, hook, menuui.HOST_TEXT_MAX); len(bad) > 0 { return false, bad } }
	// Rosters start empty, as Krunker's page does; the link's names replace them.
	for field in ([]menuui.Host_Text{.ROSTER1, .ROSTER2, .SPECTATORS}) { settings.text_length[field] = 0 }
	roster :: proc(params: map[string]string, a, b: string) -> (string, bool) {
		if value, has := params[a]; has && len(strings.trim_space(value)) > 0 { return value, true }
		if value, has := params[b]; has { return value, true }
		return "", false
	}
	if names, has := roster(params, "compRosterT1", "team1Players"); has { if bad := text(settings, .ROSTER1, names, menuui.HOST_TEXT_MAX); len(bad) > 0 { return false, bad } }
	if names, has := roster(params, "compRosterT2", "team2Players"); has { if bad := text(settings, .ROSTER2, names, menuui.HOST_TEXT_MAX); len(bad) > 0 { return false, bad } }
	if names, has := roster(params, "spectators", "compRosterSpecs"); has { if bad := text(settings, .SPECTATORS, names, menuui.HOST_TEXT_MAX); len(bad) > 0 { return false, bad } }
	return true, ""
}

// A link from the command line or another SR Client launch: checked now,
// hosted once the client can host (host_link_tick).
host_link_queue :: proc(client: ^Client, link: string) {
	check := client.menu.host
	ok, problem := host_link_parse(link, &check)
	kproto.network_log("host-link", ok ? "received a host-comp link" : fmt.tprintf("rejected link: %s", problem))
	if !ok { krunker_ws_set_status(client, fmt.tprintf("Could not use the host link: %s.", problem)); return }
	delete(g_host_link_pending)
	g_host_link_pending = strings.clone(link)
	if client.window != nil {
		glfw.RestoreWindow(client.window)
		glfw.FocusWindow(client.window)
	}
}

// Every frame: picks up links handed over by another launch (once a second)
// and starts a queued one as soon as Start Game would work.
host_link_tick :: proc(client: ^Client) {
	if time.since(g_host_link_last_poll) >= HOST_LINK_POLL {
		g_host_link_last_poll = time.now()
		if link, found := host_link_take_forwarded(); found { host_link_queue(client, link) }
	}
	if len(g_host_link_pending) == 0 { return }
	if host_game_active() || client.join_queued > 0 || client.access.status == .PENDING || game_files_checking() { return }
	settings := client.menu.host
	if ok, problem := host_link_parse(g_host_link_pending, &settings); !ok {
		krunker_ws_set_status(client, fmt.tprintf("Could not use the host link: %s.", problem))
	} else {
		client.menu.host = settings
		host_game_start(client)
	}
	delete(g_host_link_pending)
	g_host_link_pending = ""
}

// %LOCALAPPDATA%\SR-Client\host-link.txt: how a second launch hands its link
// to the running window.
host_link_file_path :: proc(allocator := context.temp_allocator) -> (string, bool) {
	local, found := os.lookup_env_alloc("LOCALAPPDATA", allocator)
	if !found || len(local) == 0 { return "", false }
	dir := strings.concatenate({local, "/SR-Client"}, allocator)
	_ = os.make_directory(dir)
	return strings.concatenate({dir, "/", HOST_LINK_FILE_NAME}, allocator), true
}

host_link_take_forwarded :: proc() -> (string, bool) {
	path, ok := host_link_file_path()
	if !ok || !os.exists(path) { return "", false }
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	_ = os.remove(path)
	if err != nil { return "", false }
	link := strings.trim_space(string(data))
	return link, host_link_is(link)
}

// Before the window opens: when another SR Client is already running, hand
// it the link and report true so this launch exits.
host_link_forward :: proc(link: string) -> bool {
	if !host_link_other_instance_running() { return false }
	path, ok := host_link_file_path()
	if !ok { return false }
	return os.write_entire_file(path, transmute([]byte)link) == nil
}
