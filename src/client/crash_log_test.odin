#+build windows
package main

import "core:os"
import "core:strings"
import "core:testing"

when ODIN_TEST {
	// The crash-report writer, called directly: it must write and flush a
	// readable report with the exception, faulting module and recent phases,
	// without crashing, allocating from a broken heap, or overrunning its buffer.
	@(test)
	crash_log_writer_reports_exception_module_and_phases :: proc(t: ^testing.T) {
		old_diag := g_diag
		defer g_diag = old_diag
		g_diag = {}
		g_diag.gl_renderer_len = copy(g_diag.gl_renderer[:], "Test Renderer")
		g_diag.gl_vendor_len = copy(g_diag.gl_vendor[:], "Test Vendor")
		// More phases than the ring holds: only the newest PHASE_RING_SIZE remain.
		for i in 0 ..< PHASE_RING_SIZE + 5 {
			phase_frame_begin()
			phase_mark(.MENU_VIEW)
			phase_mark(i % 2 == 0 ? .SETTINGS_TAB_MAIN : .SETTINGS_TAB_VISUALS)
			phase_mark(.RENDER_SCENE)
		}
		gl_debug_record(0x8246, 0x824C, 1282, 0x9146, "GL_INVALID_OPERATION in glDrawElements(test)") // API, ERROR, HIGH
		stack := [2]uintptr{0x1234, 0x5678}
		info := Crash_Info{title = "crash report (unhandled exception)", code = 0xC0000005, address = 0x7FF612345678,
			access = "read", access_address = 0x10, stack = stack[:]}
		info.code_name = crash_exception_name(info.code)
		module_buffer: [260]u8
		when ODIN_OS == .Windows {
			// An address inside this executable resolves to it.
			info.address = uintptr(rawptr(crash_log_writer_reports_exception_module_and_phases))
			info.module_path, info.module_base = crash_module_of(info.address, &module_buffer)
			testing.expect(t, strings.has_suffix(strings.to_lower(info.module_path, context.temp_allocator), ".exe"), info.module_path)
			testing.expect(t, info.module_base != 0 && info.module_base <= info.address)
		}

		os.make_directory("bin")
		path := "bin/crash-log-test.log"
		os.remove(path)
		if !testing.expect(t, crash_log_write(path, info), "the report must be written") do return
		data, err := os.read_entire_file(path, context.allocator)
		if !testing.expect(t, err == nil, "the report must be readable") do return
		defer delete(data)
		report := string(data)
		for expected in ([]string{"SR Client crash report", "GL_RENDERER: Test Renderer", "Exception: 0xC0000005 EXCEPTION_ACCESS_VIOLATION",
			"Access violation: read of address 0x10", "Stack (innermost first):", "0x1234", "settings: build Main tab",
			"settings: build Visuals tab", "render scene", "GL_INVALID_OPERATION in glDrawElements(test)", "1 errors"}) {
			testing.expectf(t, strings.contains(report, expected), "report is missing %q:\n%s", expected, report)
		}
		when ODIN_OS == .Windows {
			testing.expectf(t, strings.contains(report, info.module_path), "report is missing the module %q", info.module_path)
		}
		testing.expectf(t, strings.count(report, "  frame ") == PHASE_RING_SIZE, "report lists the last %d phases:\n%s", PHASE_RING_SIZE, report)

		// A full buffer truncates the report instead of overrunning it.
		small: [96]u8
		truncated := crash_report_format(small[:], info)
		testing.expect(t, len(truncated) > 0 && len(truncated) <= len(small))
		testing.expect(t, strings.has_prefix(truncated, "SR Client crash report"))
	}

	// Distinct GL messages are logged once; repeats are counted.
	@(test)
	gl_debug_record_deduplicates :: proc(t: ^testing.T) {
		old_diag := g_diag
		defer g_diag = old_diag
		g_diag = {}
		testing.expect(t, gl_debug_record(0x8246, 0x824C, 1, 0x9146, "same error"))
		testing.expect(t, !gl_debug_record(0x8246, 0x824C, 1, 0x9146, "same error"))
		testing.expect(t, gl_debug_record(0x8246, 0x824C, 1, 0x9146, "another error"))
		testing.expect(t, gl_debug_record(0x8246, 0x8251, 2, 0x826B, "notification")) // OTHER, NOTIFICATION
		testing.expect(t, g_diag.gl_errors == 3 && g_diag.gl_other == 1 && g_diag.gl_seen_count == 3)
		testing.expect(t, strings.contains(string(g_diag.gl_last_message[:g_diag.gl_last_message_len]), "another error"), "notifications are not quoted in reports")
	}
}
