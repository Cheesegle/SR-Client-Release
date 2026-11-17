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
	if !test_network_log_file() { return false }
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
