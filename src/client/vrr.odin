package main

import "core:fmt"
import "core:math"
import "core:strings"

// Variable refresh rate (G-SYNC, FreeSync, Adaptive-Sync).
//
// With V-Sync on, a VRR display refreshes when a frame arrives, as long as
// the frame rate stays inside its range. At the top of the range V-Sync
// takes over and frames queue behind vblank (a refresh of latency each). So
// while VRR is active, frames are capped a little below the refresh rate:
// 3 to 5 FPS (3% of it, at least 3 and at most 5). If the display still
// makes frames wait (the cap is too close for this system's frame-time
// jitter), the margin grows one FPS at a time, up to the larger of 5 FPS and
// 3% (vrr_adapt_frame).
//
// Settings > Video > VRR cap: Auto caps only where VRR was detected on the
// window's monitor (vrr_windows.odin), Always caps whenever V-Sync is on
// (for setups detection cannot see), Off never.

Vrr_Mode :: enum i32 { AUTO, ALWAYS, OFF }
VRR_MODE_LABELS := [Vrr_Mode]string{.AUTO = "Auto", .ALWAYS = "Always", .OFF = "Off"}

// What is known about the window's monitor.
Vrr_Info :: struct {
	refresh_hz: f64,  // the current mode's exact refresh rate; 0 = unknown
	capable:    bool, // the display (and, where the driver says so, the system) supports VRR
	enabled:    bool, // the driver reports VRR on for this display (NVIDIA only)
	driver:     bool, // `enabled` comes from the driver; otherwise only capability is known
	min_hz, max_hz: f64, // the display's VRR range, when known
	source:     string, // "NVIDIA driver", "EDID (FreeSync)", "" (static)
	detail:     string, // why the driver gave no answer, for diagnostics (static)
	name:       string, // the monitor's name, for the status line
}

// The starting cap margin: 3% of the refresh rate, at least 3 and at most 5.
vrr_margin_initial :: proc(refresh_hz: f64) -> i32 {
	return i32(clamp(math.ceil(refresh_hz * 0.03), 3, 5))
}

// How far vrr_adapt_frame may widen it.
vrr_margin_max :: proc(refresh_hz: f64) -> i32 {
	return max(5, i32(math.ceil(refresh_hz * 0.03)))
}

// The capped frame rate for a refresh rate and margin.
vrr_cap_fps :: proc(refresh_hz: f64, margin: i32) -> f64 {
	return max(refresh_hz - f64(margin), 1)
}

// Whether frames should be held below the refresh rate.
vrr_cap_active :: proc(mode: Vrr_Mode, vsync: bool, info: Vrr_Info) -> bool {
	if !vsync || info.refresh_hz <= 0 { return false }
	switch mode {
	case .OFF: return false
	case .ALWAYS: return true
	case .AUTO:
		// The driver's answer wins; without one, the display's capability.
		return info.driver ? info.enabled : info.capable
	}
	return false
}

// Grows the margin when V-Sync still holds frames back: over each window of
// VRR_ADAPT_FRAMES frames, if more than 5% waited for the display for over a
// quarter of a frame, the cap drops one FPS.
VRR_ADAPT_FRAMES :: 240

Vrr_Adapt :: struct {
	margin:  i32,
	refresh: f64, // the refresh rate `margin` belongs to
	frames:  int,
	blocked: int,
	widened: int, // times the margin grew (diagnostics)
}

vrr_adapt_reset :: proc(adapt: ^Vrr_Adapt, refresh_hz: f64) {
	adapt^ = {margin = vrr_margin_initial(refresh_hz), refresh = refresh_hz}
}

// wait_ms: how long the frame waited for the display. Returns true when the
// margin grew.
vrr_adapt_frame :: proc(adapt: ^Vrr_Adapt, wait_ms: f64) -> bool {
	if adapt.refresh <= 0 { return false }
	interval_ms := 1000 / vrr_cap_fps(adapt.refresh, adapt.margin)
	adapt.frames += 1
	if wait_ms > interval_ms * 0.25 { adapt.blocked += 1 }
	if adapt.frames < VRR_ADAPT_FRAMES { return false }
	grow := adapt.blocked * 20 > adapt.frames && adapt.margin < vrr_margin_max(adapt.refresh)
	if grow { adapt.margin += 1; adapt.widened += 1 }
	adapt.frames, adapt.blocked = 0, 0
	return grow
}

// The Settings line describing detection and the cap.
vrr_status_text :: proc(info: Vrr_Info, mode: Vrr_Mode, vsync: bool, margin: i32, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	if info.refresh_hz <= 0 { return "Refresh rate unknown: no cap." }
	if len(info.name) > 0 { fmt.sbprintf(&b, "%s, ", info.name) }
	fmt.sbprintf(&b, "%.2f Hz. ", info.refresh_hz)
	switch {
	case info.driver: fmt.sbprintf(&b, "VRR %s (%s)", info.enabled ? "on" : (info.capable ? "supported but off" : "not supported"), info.source)
	case info.capable: fmt.sbprintf(&b, "VRR supported (%s)", info.source)
	case: strings.write_string(&b, "No VRR detected")
	}
	if info.min_hz > 0 && info.max_hz > info.min_hz { fmt.sbprintf(&b, ", %.0f-%.0f Hz", info.min_hz, info.max_hz) }
	strings.write_string(&b, ". ")
	if vrr_cap_active(mode, vsync, info) {
		fmt.sbprintf(&b, "Frames capped at %.1f FPS.", vrr_cap_fps(info.refresh_hz, margin))
	} else if !vsync {
		strings.write_string(&b, "V-Sync is off: no cap.")
	} else {
		strings.write_string(&b, "No cap.")
	}
	return strings.to_string(b)
}

// ---------------------------------------------------------------------------
// EDID: the display's own description of itself (base block + CTA-861
// extensions). VRR shows up as AMD's FreeSync vendor block, which G-SYNC
// Compatible and Adaptive-Sync monitors carry as well.

Edid_Info :: struct {
	valid:    bool,
	name:     string, // monitor name descriptor (0xFC), trimmed; points into a temp copy
	freesync: bool,   // AMD vendor-specific data block (OUI 00-00-1A)
	freesync_min_hz, freesync_max_hz: f64,
	range_min_hz, range_max_hz: f64, // display range limits descriptor (0xFD)
}

edid_parse :: proc(data: []u8, allocator := context.temp_allocator) -> (info: Edid_Info) {
	header := [8]u8{0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00}
	if len(data) < 128 { return }
	for b, i in header { if data[i] != b { return } }
	info.valid = true
	for d in 0 ..< 4 {
		desc := data[54 + d*18:][:18]
		if desc[0] != 0 || desc[1] != 0 || desc[2] != 0 { continue } // a detailed timing
		switch desc[3] {
		case 0xFC:
			text := string(desc[5:18])
			if end := strings.index_byte(text, 0x0A); end >= 0 { text = text[:end] }
			info.name = strings.clone(strings.trim_space(text), allocator)
		case 0xFD:
			// EDID 1.4: bits 0-1 of byte 4 add 255 to the max / min vertical rate.
			offsets := desc[4]
			min_v, max_v := f64(desc[5]), f64(desc[6])
			if offsets & 0x03 == 0x03 { min_v += 255 }
			if offsets & 0x02 != 0 { max_v += 255 }
			info.range_min_hz, info.range_max_hz = min_v, max_v
		}
	}
	extensions := int(data[126])
	for e in 1 ..= extensions {
		if (e + 1) * 128 > len(data) { break }
		block := data[e*128:][:128]
		if block[0] != 0x02 { continue } // CTA-861 only
		end := int(block[2])
		if end < 4 || end > 127 { end = 127 }
		for i := 4; i < end; {
			tag, size := block[i] >> 5, int(block[i] & 0x1F)
			payload_end := i + 1 + size
			if payload_end > end { break }
			payload := block[i+1:payload_end]
			// Vendor-specific: 3-byte OUI, little-endian.
			if tag == 3 && size >= 3 && payload[0] == 0x1A && payload[1] == 0x00 && payload[2] == 0x00 {
				info.freesync = true
				// version, feature caps, min and max refresh (Hz).
				if size >= 7 && payload[5] > 0 && payload[6] > payload[5] {
					info.freesync_min_hz, info.freesync_max_hz = f64(payload[5]), f64(payload[6])
				}
			}
			i = payload_end
		}
	}
	return
}
