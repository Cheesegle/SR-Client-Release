package main

import "core:fmt"
import "core:os"
import "core:strings"
import krunker "../krunker"

test_krunker_diagnostics :: proc() -> bool {
	fixtures := []string{
		"https://example.invalid/seek-game?accessToken=FAKE-ACCESS&validationToken=FAKE-VALIDATION&game=FRA:test",
		"wss://example.invalid/ws?at=FAKE-ACCESS&clientKey=FAKE-CLIENT&gameId=FRA:test",
		`{"error":"expired", "nested":{"accessToken":"FAKE-ACCESS", "clientId":"FAKE-CLIENT", "validationToken":"FAKE-VALIDATION"}}`,
		"Authorization: Bearer FAKE-ACCESS\r\nSet-Cookie: session=FAKE-CLIENT; Secure; HttpOnly\r\nserver: test",
		`{"TOKEN":"FAKE-ACCESS", "cookie":"FAKE-CLIENT", "password":"FAKE-VALIDATION"}`,
		`{"token":"escaped\"FAKE-ACCESS", "game":"FRA:test"}`,
		"unlabelled JWT eyJhbGciOiJub25lIn0.eyJleHAiOjB9.signature",
	}
	for fixture in fixtures {
		safe := krunker.network_log_safe(fixture)
		secrets := []string{"FAKE-ACCESS", "FAKE-VALIDATION", "FAKE-CLIENT", "eyJhbGciOiJub25lIn0"}
		for secret in secrets {
			if strings.index(safe, secret) >= 0 { fmt.eprintln("Network redaction leaked a fixture credential"); delete(safe); return false }
		}
		delete(safe)
	}
	krunker.network_log_secret("fixture-secret-echo")
	safe := krunker.network_log_safe("server echoed fixture-secret-echo\n\x1b[31m failure")
	if strings.index(safe, "fixture-secret-echo") >= 0 || strings.index(safe, "\n") >= 0 || strings.index(safe, "\x1b") >= 0 { fmt.eprintln("Network free-text redaction/control escaping failed"); delete(safe); return false }
	delete(safe)
	safe = krunker.network_log_safe("error=fixture-secret-echo and more text", 8)
	if strings.index(safe, "fixture") >= 0 || strings.index(safe, "truncated") < 0 { fmt.eprintln("Network diagnostic truncation failed"); delete(safe); return false }
	delete(safe)
	safe = krunker.network_log_safe("game=FRA:test HTTP=403 error=invite expired")
	defer delete(safe)
	if safe != "game=FRA:test HTTP=403 error=invite expired" { fmt.eprintln("Network redaction removed useful diagnostics"); return false }
	everything := krunker.network_log_everything
	krunker.network_log_everything = true
	file_ok := test_network_log_file() && test_network_log_rotation()
	krunker.network_log_everything = everything
	if !file_ok { return false }
	if !test_network_log_errors_only() { return false }
	fmt.println("Krunker network diagnostic redaction tests OK")
	return true
}

// The log file stays open between lines and is closed on shutdown; a later
// run (close, then log again) must still append rather than truncate.
test_network_log_file :: proc() -> bool {
	dir := fmt.tprintf("%sbin/network-log-test", project_root())
	path := fmt.tprintf("%s/krunker-network.log", dir)
	os.remove(path)
	krunker.network_log_close()
	saved := krunker.network_log_path
	krunker.network_log_path = path
	defer {
		krunker.network_log_close()
		krunker.network_log_path = saved
		os.remove(path)
		os.remove(dir)
	}
	krunker.network_log("test", "first line")
	handle := krunker.network_log_file
	krunker.network_log("test", "second line")
	if handle == nil || krunker.network_log_file != handle {
		fmt.eprintln("Network log must keep one file handle open between lines")
		return false
	}
	krunker.network_log_close()
	if krunker.network_log_file != nil {
		fmt.eprintln("Network log close must release the file handle")
		return false
	}
	krunker.network_log("test", "third line")
	krunker.network_log_close()
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	text := string(data)
	first, second, third := strings.index(text, "[test] first line"), strings.index(text, "[test] second line"), strings.index(text, "[test] third line")
	if err != nil || strings.count(text, "\n") != 3 || first < 0 || second < first || third < second {
		fmt.eprintf("Network log must append every line across close/reopen (err=%v): %q\n", err, text)
		return false
	}
	fmt.println("Krunker network log file tests OK")
	return true
}

// A log bigger than the limit moves to .old.log at the first write of a run,
// so the logs never grow without bound across games and versions.
test_network_log_rotation :: proc() -> bool {
	dir := fmt.tprintf("%sbin/network-log-rotate-test", project_root())
	path := fmt.tprintf("%s/krunker-network.log", dir)
	old := fmt.tprintf("%s/krunker-network.old.log", dir)
	os.make_directory_all(dir)
	krunker.network_log_close()
	saved := krunker.network_log_path
	krunker.network_log_path = path
	defer {
		krunker.network_log_close()
		krunker.network_log_path = saved
		os.remove(path)
		os.remove(old)
		os.remove(dir)
	}
	big := make([]byte, krunker.NETWORK_LOG_MAX_BYTES + 10, context.temp_allocator)
	if os.write_entire_file(path, big) != nil { fmt.eprintln("rotation test: could not write the big log"); return false }
	krunker.network_log_rotated = false
	krunker.network_log("test", "fresh line")
	krunker.network_log_close()
	old_info, old_err := os.stat(old, context.temp_allocator)
	new_info, new_err := os.stat(path, context.temp_allocator)
	if old_err != nil || old_info.size != i64(len(big)) || new_err != nil || new_info.size > 512 {
		fmt.eprintf("Network log over the limit must move to .old.log and start fresh (old=%v %v new=%v %v)\n", old_err, old_info.size, new_err, new_info.size)
		return false
	}
	// A second run under the limit keeps appending to the same file.
	krunker.network_log_rotated = false
	krunker.network_log("test", "second run")
	krunker.network_log_close()
	again, _ := os.stat(path, context.temp_allocator)
	if again.size <= new_info.size { fmt.eprintln("Network log under the limit must keep appending"); return false }
	return true
}

// Normal builds: routine lines stay in memory and are never written; a problem
// writes itself plus the lines that led up to it.
test_network_log_errors_only :: proc() -> bool {
	dir := fmt.tprintf("%sbin/network-log-errors-test", project_root())
	path := fmt.tprintf("%s/krunker-network.log", dir)
	os.make_directory_all(dir)
	os.remove(path)
	krunker.network_log_close()
	saved, everything := krunker.network_log_path, krunker.network_log_everything
	krunker.network_log_path, krunker.network_log_everything = path, false
	defer {
		krunker.network_log_close()
		krunker.network_log_path, krunker.network_log_everything = saved, everything
		os.remove(path)
		os.remove(dir)
	}
	krunker.network_log("seek-game", "HTTP=200 curl=E_OK (0: No error) detail=")
	krunker.network_log("lobby-config", "limitClasses=false type=x")
	krunker.network_log_close()
	if _, err := os.stat(path, context.temp_allocator); err == nil {
		fmt.eprintln("Normal builds must not write routine network log lines")
		return false
	}
	krunker.network_log("join", "context line before the problem")
	krunker.network_log("seek-game", "HTTP=403 curl=E_OK (0: No error) detail=")
	krunker.network_log("join", "routine line after the problem")
	krunker.network_log_close()
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	text := string(data)
	if err != nil || !strings.contains(text, "HTTP=403") || !strings.contains(text, "context line before the problem") || !strings.contains(text, "limitClasses") || strings.contains(text, "routine line after the problem") {
		fmt.eprintf("A problem must be written with the lines before it, and nothing routine after it: %q\n", text)
		return false
	}
	if krunker.network_log_is_problem("websocket", "HTTP=101 curl=E_OK (0: No error) detail=") || krunker.network_log_is_problem("seek-game", "HTTP=200 curl=E_OK (0: No error) detail=") || !krunker.network_log_is_problem("seek-game", "HTTP=0 curl=E_COULDNT_CONNECT detail=") || !krunker.network_log_is_problem("seek-game", "HTTP=503 curl=E_OK detail=") {
		fmt.eprintln("HTTP 101/200 are fine, 0 and 5xx are problems")
		return false
	}
	if krunker.network_log_is_problem("world-player", "LOCAL READY sid=1 class=0 team=1") || !krunker.network_log_is_problem("world-player", "ERROR player allocation failed") {
		fmt.eprintln("A normal spawn must not count as a problem; a world-player ERROR must")
		return false
	}
	if !krunker.network_log_is_problem("spawn", "entry rejected; server_args=[]") || !krunker.network_log_is_problem("ws-recv", "ERROR curl=x") || krunker.network_log_is_problem("game-list", "response body bytes=47147 limit_exceeded=false") {
		fmt.eprintln("network_log_is_problem misclassified a line")
		return false
	}
	return true
}
