#+build windows
package main

import "core:fmt"
import win "core:sys/windows"

// The Downloads folder (also when it is moved, e.g. to another drive).
tester_export_downloads_path :: proc(name: string) -> string {
	path: win.LPWSTR
	folder := win.FOLDERID_Downloads
	if win.SHGetKnownFolderPath(&folder, 0, nil, &path) != 0 || path == nil { return "" }
	defer win.CoTaskMemFree(path)
	downloads, err := win.wstring_to_utf8(win.wstring(path), -1, context.temp_allocator)
	if err != nil || len(downloads) == 0 { return "" }
	return fmt.tprintf("%s\\%s", downloads, name)
}

// Local date and time for the export file name: 2026-11-19_18-48-05.
tester_export_local_stamp :: proc() -> string {
	t: win.SYSTEMTIME
	GetLocalTime(&t)
	return fmt.tprintf("%04d-%02d-%02d_%02d-%02d-%02d", t.year, t.month, t.day, t.hour, t.minute, t.second)
}

foreign import tester_kernel32 "system:Kernel32.lib"
@(default_calling_convention = "system")
foreign tester_kernel32 {
	GetLocalTime :: proc(lpSystemTime: ^win.SYSTEMTIME) ---
}

// Opens Explorer with the file selected.
tester_export_show_in_folder :: proc(path: string) {
	params := win.utf8_to_wstring(fmt.tprintf("/select,\"%s\"", path), context.temp_allocator)
	win.ShellExecuteW(nil, win.L("open"), win.L("explorer.exe"), params, nil, win.SW_SHOWNORMAL)
}

// HKLM\HARDWARE\DESCRIPTION\System\CentralProcessor\0 ProcessorNameString.
cpu_model_name_windows :: proc() -> string {
	buffer: [256]u16
	size := win.DWORD(size_of(buffer))
	status := win.RegGetValueW(win.HKEY_LOCAL_MACHINE, win.L("HARDWARE\\DESCRIPTION\\System\\CentralProcessor\\0"), win.L("ProcessorNameString"), win.RRF_RT_REG_SZ, nil, &buffer[0], &size)
	if status != 0 { return "Unknown CPU" }
	name, err := win.wstring_to_utf8(win.wstring(&buffer[0]), -1, context.temp_allocator)
	if err != nil || len(name) == 0 { return "Unknown CPU" }
	return name
}

// "Windows 10.0 build 26100, 32 GB RAM" for the tester export.
tester_export_system_text :: proc() -> string {
	version := win.OSVERSIONINFOEXW{dwOSVersionInfoSize = size_of(win.OSVERSIONINFOEXW)}
	win.RtlGetVersion(&version)
	memory := win.MEMORYSTATUSEX{dwLength = size_of(win.MEMORYSTATUSEX)}
	ram_gb := win.GlobalMemoryStatusEx(&memory) ? f64(memory.ullTotalPhys) / (1024 * 1024 * 1024) : 0
	return fmt.tprintf("Windows %d.%d build %d, %.0f GB RAM", version.dwMajorVersion, version.dwMinorVersion, version.dwBuildNumber, ram_gb)
}
