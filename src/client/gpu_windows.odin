package main

import win "core:sys/windows"

// Laptops with two GPUs: these two exported values make the NVIDIA (Optimus)
// and AMD (PowerXpress) drivers run SR Client on the dedicated GPU instead of
// the integrated one. Desktops with one GPU are unaffected.
@(export, link_name = "NvOptimusEnablement")
NvOptimusEnablement: u32 = 1
@(export, link_name = "AmdPowerXpressRequestHighPerformance")
AmdPowerXpressRequestHighPerformance: i32 = 1

@(private = "file")
PROCESS_POWER_THROTTLING_CURRENT_VERSION :: 1
@(private = "file")
PROCESS_POWER_THROTTLING_EXECUTION_SPEED :: 0x1
@(private = "file")
PROCESS_POWER_THROTTLING_IGNORE_TIMER_RESOLUTION :: 0x4
@(private = "file")
PROCESS_INFORMATION_CLASS_POWER_THROTTLING :: 4 // ProcessPowerThrottling

@(private = "file")
Process_Power_Throttling_State :: struct {
	version:      u32,
	control_mask: u32,
	state_mask:   u32,
}

foreign import kernel32 "system:Kernel32.lib"
@(default_calling_convention = "system", private = "file")
foreign kernel32 {
	SetProcessInformation :: proc(process: win.HANDLE, info_class: i32, info: rawptr, size: u32) -> win.BOOL ---
}

// Asks Windows not to slow SR Client down (EcoQoS / timer throttling) when
// it runs on battery or is briefly in the background. One call at start-up;
// it changes nothing on older Windows versions, where the call just fails.
client_disable_power_throttling :: proc() {
	state := Process_Power_Throttling_State {
		version      = PROCESS_POWER_THROTTLING_CURRENT_VERSION,
		control_mask = PROCESS_POWER_THROTTLING_EXECUTION_SPEED | PROCESS_POWER_THROTTLING_IGNORE_TIMER_RESOLUTION,
		state_mask   = 0, // 0 under a controlled bit = never throttle it
	}
	SetProcessInformation(win.GetCurrentProcess(), PROCESS_INFORMATION_CLASS_POWER_THROTTLING, &state, size_of(state))
}
