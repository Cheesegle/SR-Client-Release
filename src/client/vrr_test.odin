package main

import "core:fmt"
import "core:testing"
import glfw "vendor:glfw"

when ODIN_TEST {
	@(test)
	vrr_cap_is_3_to_5_fps_below_refresh :: proc(t: ^testing.T) {
		cases := [?][2]f64{{60, 57}, {75, 72}, {100, 97}, {120, 116}, {144, 139}, {165, 160}, {240, 235}, {360, 355}}
		for c in cases {
			got := vrr_cap_fps(c[0], vrr_margin_initial(c[0]))
			testing.expectf(t, got == c[1], "%.0f Hz must cap at %.0f FPS, got %.1f", c[0], c[1], got)
		}
		// Fractional modes keep their exact rate.
		testing.expect(t, abs(vrr_cap_fps(143.981, vrr_margin_initial(143.981)) - 138.981) < 1e-9)
		testing.expect(t, vrr_margin_max(144) == 5 && vrr_margin_max(240) == 8 && vrr_margin_max(360) == 11)
	}

	@(test)
	vrr_cap_follows_mode_vsync_and_detection :: proc(t: ^testing.T) {
		none := Vrr_Info{refresh_hz = 144}
		edid := Vrr_Info{refresh_hz = 144, capable = true}
		driver_off := Vrr_Info{refresh_hz = 144, capable = true, driver = true}
		driver_on := Vrr_Info{refresh_hz = 144, capable = true, driver = true, enabled = true}
		testing.expect(t, !vrr_cap_active(.AUTO, true, none) && vrr_cap_active(.AUTO, true, edid), "Auto caps only where VRR was detected")
		testing.expect(t, !vrr_cap_active(.AUTO, true, driver_off) && vrr_cap_active(.AUTO, true, driver_on), "the driver's on/off wins over capability")
		testing.expect(t, vrr_cap_active(.ALWAYS, true, none) && !vrr_cap_active(.OFF, true, driver_on), "Always caps anywhere, Off never")
		testing.expect(t, !vrr_cap_active(.ALWAYS, false, driver_on), "no cap without V-Sync")
		testing.expect(t, !vrr_cap_active(.ALWAYS, true, {}), "no cap without a known refresh rate")
	}

	@(test)
	vrr_margin_widens_while_frames_wait :: proc(t: ^testing.T) {
		adapt: Vrr_Adapt
		vrr_adapt_reset(&adapt, 240)
		testing.expect(t, adapt.margin == 5)
		// Frames that never wait keep the cap.
		for _ in 0 ..< VRR_ADAPT_FRAMES * 3 { vrr_adapt_frame(&adapt, 0.05) }
		testing.expect(t, adapt.margin == 5, "a cap that holds must not move")
		// 10% of frames waiting a whole frame: one FPS per window, up to 3% (8 at 240 Hz).
		grew := 0
		for window in 0 ..< 10 {
			for i in 0 ..< VRR_ADAPT_FRAMES { if vrr_adapt_frame(&adapt, i % 10 == 0 ? 4.0 : 0.05) { grew += 1 } }
		}
		testing.expectf(t, adapt.margin == 8 && grew == 3, "the margin must grow to 8 and stop (margin %d, grew %d)", adapt.margin, grew)
	}

	// Base block with a range limits descriptor (48-144 Hz) and a name, plus a
	// CTA-861 extension with AMD's FreeSync block (48-144 Hz).
	vrr_test_edid :: proc() -> [256]u8 {
		e: [256]u8
		copy(e[:], []u8{0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00})
		// Descriptor 2 (offset 72): monitor range limits.
		copy(e[72:], []u8{0, 0, 0, 0xFD, 0, 48, 144, 30, 160, 60})
		// Descriptor 3 (offset 90): monitor name.
		copy(e[90:], []u8{0, 0, 0, 0xFC, 0})
		copy(e[95:], "XG27AQ\n     ")
		e[126] = 1
		ext := e[128:]
		ext[0], ext[1], ext[2] = 0x02, 0x03, 4 + 1 + 8 // detailed timings start after the one data block
		// Vendor-specific block (tag 3), 8 bytes: OUI 1A 00 00, version 1,
		// caps, min 48, max 144, reserved.
		copy(ext[4:], []u8{3 << 5 | 8, 0x1A, 0x00, 0x00, 0x01, 0x00, 48, 144, 0x00})
		return e
	}

	@(test)
	vrr_edid_finds_freesync_and_range :: proc(t: ^testing.T) {
		e := vrr_test_edid()
		info := edid_parse(e[:])
		testing.expect(t, info.valid && info.freesync, "the FreeSync block must be found")
		testing.expectf(t, info.freesync_min_hz == 48 && info.freesync_max_hz == 144, "FreeSync range 48-144, got %v-%v", info.freesync_min_hz, info.freesync_max_hz)
		testing.expectf(t, info.range_min_hz == 48 && info.range_max_hz == 144, "range limits 48-144, got %v-%v", info.range_min_hz, info.range_max_hz)
		testing.expectf(t, info.name == "XG27AQ", "monitor name, got %q", info.name)
		// Without the extension: range only, no FreeSync.
		e[126] = 0
		plain := edid_parse(e[:])
		testing.expect(t, plain.valid && !plain.freesync, "range limits alone are not VRR")
		testing.expect(t, !edid_parse(e[:64]).valid, "a short EDID is invalid")
		e[0] = 1
		testing.expect(t, !edid_parse(e[:]).valid, "a wrong header is invalid")
	}

	// Prints what detection finds on this machine's monitors (no expectations
	// beyond a refresh rate: hardware differs).
	@(test)
	vrr_detect_reports_this_machine :: proc(t: ^testing.T) {
		if !glfw.Init() { return }
		defer glfw.Terminate()
		for monitor in glfw.GetMonitors() {
			info := vrr_detect(monitor)
			fmt.printfln("[vrr] %s: %s (%s)", glfw.GetMonitorName(monitor), vrr_status_text(info, .AUTO, true, vrr_margin_initial(info.refresh_hz)), info.detail)
			testing.expect(t, info.refresh_hz > 0, "a connected monitor has a refresh rate")
		}
	}
}
