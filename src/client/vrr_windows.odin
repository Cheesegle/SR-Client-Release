package main

import "core:strings"
import win "core:sys/windows"
import glfw "vendor:glfw"

// VRR detection on Windows (see vrr.odin).
//
// - Refresh rate: the exact rational rate of the monitor's current mode from
//   the display configuration (GLFW rounds it to whole hertz).
// - Capability: the monitor's EDID (from the registry key the display
//   configuration names) carries AMD's FreeSync block, as G-SYNC Compatible
//   and Adaptive-Sync monitors do.
// - NVIDIA: the driver says whether VRR is possible and enabled for the
//   display (nvapi64.dll, loaded only if present). G-SYNC monitors with a
//   module need this, as their EDID may not advertise it.

foreign import user32 "system:User32.lib"

@(private = "file")
DISPLAYCONFIG_RATIONAL :: struct { numerator, denominator: u32 }
@(private = "file")
DISPLAYCONFIG_PATH_SOURCE_INFO :: struct {
	adapter_id:     win.LUID,
	id:             u32,
	mode_info_idx:  u32,
	status_flags:   u32,
}
@(private = "file")
DISPLAYCONFIG_PATH_TARGET_INFO :: struct {
	adapter_id:        win.LUID,
	id:                u32,
	mode_info_idx:     u32,
	output_technology: i32,
	rotation:          i32,
	scaling:           i32,
	refresh_rate:      DISPLAYCONFIG_RATIONAL,
	scan_line_order:   i32,
	target_available:  win.BOOL,
	status_flags:      u32,
}
@(private = "file")
DISPLAYCONFIG_PATH_INFO :: struct {
	source: DISPLAYCONFIG_PATH_SOURCE_INFO,
	target: DISPLAYCONFIG_PATH_TARGET_INFO,
	flags:  u32,
}
@(private = "file")
DISPLAYCONFIG_MODE_INFO :: struct #align(8) {
	info_type:  i32,
	id:         u32,
	adapter_id: win.LUID,
	mode:       [48]u8, // target, source or desktop image mode (unused)
}
@(private = "file")
DISPLAYCONFIG_DEVICE_INFO_HEADER :: struct {
	type:       i32,
	size:       u32,
	adapter_id: win.LUID,
	id:         u32,
}
@(private = "file")
DISPLAYCONFIG_SOURCE_DEVICE_NAME :: struct {
	header:              DISPLAYCONFIG_DEVICE_INFO_HEADER,
	view_gdi_device_name: [32]u16,
}
@(private = "file")
DISPLAYCONFIG_TARGET_DEVICE_NAME :: struct {
	header:              DISPLAYCONFIG_DEVICE_INFO_HEADER,
	flags:               u32,
	output_technology:   i32,
	edid_manufacture_id: u16,
	edid_product_code_id: u16,
	connector_instance:  u32,
	monitor_friendly_device_name: [64]u16,
	monitor_device_path: [128]u16,
}
#assert(size_of(DISPLAYCONFIG_PATH_INFO) == 72)
#assert(size_of(DISPLAYCONFIG_MODE_INFO) == 64)
#assert(size_of(DISPLAYCONFIG_SOURCE_DEVICE_NAME) == 84)
#assert(size_of(DISPLAYCONFIG_TARGET_DEVICE_NAME) == 420)

@(private = "file")
QDC_ONLY_ACTIVE_PATHS :: 0x2
@(private = "file")
DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME :: 1
@(private = "file")
DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME :: 2

@(default_calling_convention = "system", private = "file")
foreign user32 {
	GetDisplayConfigBufferSizes :: proc(flags: u32, num_path: ^u32, num_mode: ^u32) -> i32 ---
	QueryDisplayConfig :: proc(flags: u32, num_path: ^u32, paths: [^]DISPLAYCONFIG_PATH_INFO, num_mode: ^u32, modes: [^]DISPLAYCONFIG_MODE_INFO, topology: rawptr) -> i32 ---
	DisplayConfigGetDeviceInfo :: proc(packet: ^DISPLAYCONFIG_DEVICE_INFO_HEADER) -> i32 ---
}

// NVAPI: functions come from nvapi_QueryInterface by id (nvapi_interface.h).
@(private = "file")
NVAPI_INITIALIZE_ID :: 0x0150E828
@(private = "file")
NVAPI_GET_DISPLAY_ID_BY_NAME_ID :: 0xAE457190
@(private = "file")
NVAPI_GET_VRR_INFO_ID :: 0xDF8FDA57
@(private = "file")
NV_GET_VRR_INFO :: struct {
	version:  u32,
	bits:     u32, // enabled, possible, requested, indicator enabled, display in VRR mode
	reserved: [4]u32,
}

@(private = "file")
g_nvapi: struct {
	tried:   bool,
	ok:      bool,
	display_id_by_name: proc "c" (name: cstring, id: ^u32) -> i32,
	vrr_info: proc "c" (display_id: u32, info: ^NV_GET_VRR_INFO) -> i32,
}

@(private = "file")
nvapi_load :: proc() -> bool {
	if g_nvapi.tried { return g_nvapi.ok }
	g_nvapi.tried = true
	module := win.LoadLibraryW(win.L("nvapi64.dll"))
	if module == nil { return false }
	query := cast(proc "c" (id: u32) -> rawptr)win.GetProcAddress(module, "nvapi_QueryInterface")
	if query == nil { return false }
	initialize := cast(proc "c" () -> i32)query(NVAPI_INITIALIZE_ID)
	g_nvapi.display_id_by_name = cast(proc "c" (name: cstring, id: ^u32) -> i32)query(NVAPI_GET_DISPLAY_ID_BY_NAME_ID)
	g_nvapi.vrr_info = cast(proc "c" (display_id: u32, info: ^NV_GET_VRR_INFO) -> i32)query(NVAPI_GET_VRR_INFO_ID)
	if initialize == nil || g_nvapi.display_id_by_name == nil || g_nvapi.vrr_info == nil { return false }
	g_nvapi.ok = initialize() == 0
	return g_nvapi.ok
}

// The EDID of a monitor from its device path
// (\\?\DISPLAY#<model>#<instance>#{guid}).
@(private = "file")
edid_from_device_path :: proc(path: string, allocator := context.temp_allocator) -> []u8 {
	trimmed := strings.trim_prefix(path, `\\?\`)
	parts := strings.split(trimmed, "#", context.temp_allocator)
	if len(parts) < 3 { return nil }
	key := strings.concatenate({`SYSTEM\CurrentControlSet\Enum\`, parts[0], `\`, parts[1], `\`, parts[2], `\Device Parameters`}, context.temp_allocator)
	buffer := make([]u8, 1024, allocator)
	size := win.DWORD(len(buffer))
	RRF_RT_REG_BINARY :: 0x00000008
	if win.RegGetValueW(win.HKEY_LOCAL_MACHINE, win.utf8_to_wstring(key), win.L("EDID"), RRF_RT_REG_BINARY, nil, raw_data(buffer), &size) != 0 { return nil }
	return buffer[:size]
}

@(private = "file")
utf16_string :: proc(text: []u16, allocator := context.temp_allocator) -> string {
	n := 0
	for n < len(text) && text[n] != 0 { n += 1 }
	s, _ := win.utf16_to_utf8(text[:n], allocator)
	return s
}

// What is known about `monitor` (the window's). Strings are temp-allocated.
vrr_detect :: proc(monitor: glfw.MonitorHandle) -> (info: Vrr_Info) {
	if monitor == nil { return }
	if mode := glfw.GetVideoMode(monitor); mode != nil { info.refresh_hz = f64(mode.refresh_rate) }
	gdi_name := string(glfw.GetWin32Monitor(monitor)) // \\.\DISPLAY1
	num_path, num_mode: u32
	if GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &num_path, &num_mode) != 0 || num_path == 0 { return }
	paths := make([]DISPLAYCONFIG_PATH_INFO, num_path, context.temp_allocator)
	modes := make([]DISPLAYCONFIG_MODE_INFO, num_mode, context.temp_allocator)
	if QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &num_path, raw_data(paths), &num_mode, raw_data(modes), nil) != 0 { return }
	for &path in paths[:num_path] {
		source := DISPLAYCONFIG_SOURCE_DEVICE_NAME{header = {type = DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME, size = size_of(DISPLAYCONFIG_SOURCE_DEVICE_NAME), adapter_id = path.source.adapter_id, id = path.source.id}}
		if DisplayConfigGetDeviceInfo(&source.header) != 0 { continue }
		if !strings.equal_fold(utf16_string(source.view_gdi_device_name[:]), gdi_name) { continue }
		rate := path.target.refresh_rate
		if rate.denominator > 0 && rate.numerator > 0 { info.refresh_hz = f64(rate.numerator) / f64(rate.denominator) }
		target := DISPLAYCONFIG_TARGET_DEVICE_NAME{header = {type = DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME, size = size_of(DISPLAYCONFIG_TARGET_DEVICE_NAME), adapter_id = path.target.adapter_id, id = path.target.id}}
		if DisplayConfigGetDeviceInfo(&target.header) == 0 {
			info.name = utf16_string(target.monitor_friendly_device_name[:])
			if edid := edid_from_device_path(utf16_string(target.monitor_device_path[:])); edid != nil {
				parsed := edid_parse(edid)
				if len(info.name) == 0 { info.name = parsed.name }
				if parsed.freesync {
					info.capable, info.source = true, "EDID (FreeSync / Adaptive-Sync)"
					info.min_hz, info.max_hz = parsed.freesync_min_hz, parsed.freesync_max_hz
				}
				if info.max_hz <= 0 && parsed.range_max_hz > parsed.range_min_hz { info.min_hz, info.max_hz = parsed.range_min_hz, parsed.range_max_hz }
			}
		}
		break
	}
	if !nvapi_load() {
		info.detail = "no NVIDIA driver"
		return
	}
	display_id: u32
	name := strings.clone_to_cstring(gdi_name, context.temp_allocator)
	if g_nvapi.display_id_by_name(name, &display_id) != 0 {
		info.detail = "display not driven by the NVIDIA GPU"
		return
	}
	vrr := NV_GET_VRR_INFO{version = size_of(NV_GET_VRR_INFO) | (1 << 16)}
	if g_nvapi.vrr_info(display_id, &vrr) != 0 {
		info.detail = "NVIDIA driver has no VRR information"
		return
	}
	info.driver = true
	info.enabled = vrr.bits & 0x1 != 0
	info.capable = info.capable || vrr.bits & 0x2 != 0
	info.source = "NVIDIA driver"
	return
}
