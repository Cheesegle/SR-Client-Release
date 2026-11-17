package krunker

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

NETWORK_LOG_PATH :: "logs/krunker-network.log"
network_log_attempt: u64
network_log_started: time.Time
network_log_secrets: [dynamic]string
network_log_file_warning: bool
// Tests may point this elsewhere; call network_log_close first so the next
// line opens the new path.
network_log_path := NETWORK_LOG_PATH
// Kept open across lines; network_log_close releases it on shutdown.
network_log_file: ^os.File
// SR Client: echoing every network line to the console is slow on Windows and
// happens on the game thread. Opt in with SR_CONSOLE_LOG=1.
network_log_console_checked: bool
network_log_console: bool

network_log_secret :: proc(secret: string) {
	if len(secret) == 0 do return
	for existing in network_log_secrets { if existing == secret do return }
	append(&network_log_secrets, strings.clone(secret))
}

network_log_sensitive_key :: proc(key: string) -> bool {
	keys := []string{"accessToken", "validationToken", "captchaToken", "clientKey", "clientId", "clientUID", "at", "bpt", "token", "authorization", "cookie", "set-cookie", "password", "access_token", "refresh_token"}
	for candidate in keys {
		if strings.equal_fold(key, candidate) do return true
	}
	return false
}

network_log_word :: proc(b: byte) -> bool {
	return b >= 'a' && b <= 'z' || b >= 'A' && b <= 'Z' || b >= '0' && b <= '9' || b == '_' || b == '-'
}

// Redact BEFORE truncating, including secrets echoed outside a JSON/query field.
// The returned string is owned by the caller.
network_log_safe :: proc(input: string, limit: int = 16384) -> string {
	value := strings.clone(input)
	defer delete(value)
	for secret in network_log_secrets {
		replaced, allocated := strings.replace_all(value, secret, "[REDACTED]")
		if allocated { delete(value); value = replaced }
	}
	out: [dynamic]byte
	defer delete(out)
	i := 0
	for i < len(value) {
		start := i
		if network_log_word(value[i]) {
			for i < len(value) && network_log_word(value[i]) { i += 1 }
			key := value[start:i]
			j := i
			if j < len(value) && (value[j] == '"' || value[j] == '\'') { j += 1 }
			for j < len(value) && (value[j] == ' ' || value[j] == '\t') { j += 1 }
			if network_log_sensitive_key(key) && j < len(value) && (value[j] == ':' || value[j] == '=') {
				j += 1
				for j < len(value) && (value[j] == ' ' || value[j] == '\t') { j += 1 }
				quote: byte
				if j < len(value) && (value[j] == '"' || value[j] == '\'') { quote = value[j]; j += 1 }
				append(&out, value[start:j])
				append(&out, "[REDACTED]")
				line_value := strings.equal_fold(key, "authorization") || strings.equal_fold(key, "cookie") || strings.equal_fold(key, "set-cookie")
				for j < len(value) {
					b := value[j]
					if quote != 0 {
						if b == '\\' && j+1 < len(value) { j += 2; continue }
						if b == quote do break
					} else {
						if b == '\r' || b == '\n' do break
						if !line_value && (b == '&' || b == '#' || b == ' ' || b == '\t' || b == ',' || b == '}' || b == ']' || b == '"' || b == '\'') do break
					}
					j += 1
				}
				i = j
				continue
			}
			// JWTs can appear in free text without a field name.
			if strings.has_prefix(key, "eyJ") && len(key) > 12 {
				for i < len(value) && (network_log_word(value[i]) || value[i] == '.' || value[i] == '=') { i += 1 }
				append(&out, "[REDACTED JWT]")
			} else { append(&out, key) }
			continue
		}
		if value[i] < 32 || value[i] == 127 { append(&out, ' ') } else { append(&out, value[i]) }
		i += 1
	}
	if len(out) > limit { return fmt.aprintf("%s ... [truncated; sanitized bytes=%d]", string(out[:limit]), len(out)) }
	return strings.clone(string(out[:]))
}

network_log :: proc(stage, message: string) {
	safe := network_log_safe(message)
	defer delete(safe)
	stamp, _ := time.time_to_rfc3339(time.now(), include_nanos = false, allocator = context.temp_allocator)
	elapsed := network_log_attempt == 0 ? 0.0 : time.duration_milliseconds(time.since(network_log_started))
	line := fmt.tprintf("[Krunker][%s][attempt=%d +%.1fms][%s] %s\n", stamp, network_log_attempt, elapsed, stage, safe)
	if !network_log_console_checked {
		network_log_console_checked = true
		flag, found := os.lookup_env_alloc("SR_CONSOLE_LOG", context.temp_allocator)
		network_log_console = found && flag == "1"
	}
	if network_log_console do fmt.print(line)
	if network_log_file == nil {
		os.make_directory_all(os.dir(network_log_path))
		file, err := os.open(network_log_path, {.Write, .Append, .Create})
		if err == nil { network_log_file = file }
	}
	if network_log_file != nil {
		_, write_err := os.write_string(network_log_file, line)
		if write_err == nil do return
		// Reopen on the next line, as before when every line reopened the file.
		network_log_close()
	}
	if !network_log_console do fmt.print(line)
	if !network_log_file_warning { fmt.eprintln("[Krunker] Could not write logs/krunker-network.log; diagnostics continue on console."); network_log_file_warning = true }
}

network_log_close :: proc() {
	if network_log_file != nil { os.close(network_log_file) }
	network_log_file = nil
}

network_log_clear_secrets :: proc() {
	for secret in network_log_secrets { delete(secret) }
	delete(network_log_secrets)
	network_log_secrets = nil
}

network_log_begin :: proc() {
	network_log_clear_secrets()
	network_log_attempt += 1
	network_log_started = time.now()
	cwd, _ := os.get_working_directory(context.temp_allocator)
	network_log("join", fmt.tprintf("BEGIN exe=%s handoff=v2 cwd=%s log=%s/%s", os.args[0], cwd, cwd, NETWORK_LOG_PATH))
}
