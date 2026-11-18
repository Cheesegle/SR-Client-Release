#+build windows
package main

import win "core:sys/windows"

foreign import host_link_kernel32 "system:Kernel32.lib"

@(default_calling_convention = "system", private = "file")
foreign host_link_kernel32 {
	CreateMutexW :: proc(attributes: rawptr, initial_owner: win.BOOL, name: win.LPCWSTR) -> win.HANDLE ---
}

@(private = "file") g_running_mutex: win.HANDLE

// Every SR Client holds a named mutex for its lifetime; a launch that finds it
// already there knows another SR Client is running.
host_link_other_instance_running :: proc() -> bool {
	if g_running_mutex != nil { return false } // this process already holds it
	handle := CreateMutexW(nil, false, win.L("Local\\SR-Client-Running"))
	already := handle != nil && win.GetLastError() == win.ERROR_ALREADY_EXISTS
	g_running_mutex = handle
	return already
}
