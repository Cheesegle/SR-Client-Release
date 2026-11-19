#+build windows
package main

import "core:fmt"
import win "core:sys/windows"

// The Desktop folder (also when it is redirected, e.g. to OneDrive).
tester_export_desktop_path :: proc() -> string {
	path: win.LPWSTR
	folder := win.FOLDERID_Desktop
	if win.SHGetKnownFolderPath(&folder, 0, nil, &path) != 0 || path == nil { return "" }
	defer win.CoTaskMemFree(path)
	desktop, err := win.wstring_to_utf8(win.wstring(path), -1, context.temp_allocator)
	if err != nil || len(desktop) == 0 { return "" }
	return fmt.tprintf("%s\\%s", desktop, TESTER_EXPORT_DESKTOP_NAME)
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
