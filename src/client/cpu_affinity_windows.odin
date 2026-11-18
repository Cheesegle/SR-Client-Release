package main

import "core:fmt"
import win "core:sys/windows"

// Windows side of CPU pinning (see cpu_affinity.odin).
//
// - The main thread gets hard group affinity and its selected CPU Sets on the
//   game core only, so it never runs on core 0 or anywhere else.
// - The process default CPU Sets are every core but the game core. Threads
//   without their own CPU Sets follow them, including ones this code never
//   sees created: curl's DNS resolver, audio, GLFW and driver threads.
// - Threads SR Client starts itself (HTTP jobs, raw mouse input, crash watchdog)
//   also take hard affinity off the game core (cpu_pin_current_thread_off_game_core).

foreign import kernel32 "system:Kernel32.lib"

// Declared here: the Odin release SR builds with has none of these yet.
@(private = "file")
KAFFINITY :: uintptr
@(private = "file")
GROUP_AFFINITY :: struct {
	Mask:     KAFFINITY,
	Group:    u16,
	Reserved: [3]u16,
}
@(private = "file")
CPU_SET_INFORMATION_TYPE :: enum i32 { CpuSetInformation = 0 }
@(private = "file")
SYSTEM_CPU_SET :: struct {
	Id:                    u32,
	Group:                 u16,
	LogicalProcessorIndex: u8,
	CoreIndex:             u8,
	LastLevelCacheIndex:   u8,
	NumaNodeIndex:         u8,
	EfficiencyClass:       u8,
	AllFlags:              u8, // Parked, Allocated, AllocatedToTargetProcess, RealTime (bit 3)
	Reserved:              u32,
	AllocationTag:         u64,
}
@(private = "file")
SYSTEM_CPU_SET_INFORMATION :: struct {
	Size:   u32,
	Type:   CPU_SET_INFORMATION_TYPE,
	CpuSet: SYSTEM_CPU_SET,
}

@(default_calling_convention = "system", private = "file")
foreign kernel32 {
	SetThreadGroupAffinity :: proc(hThread: win.HANDLE, GroupAffinity: ^GROUP_AFFINITY, PreviousGroupAffinity: ^GROUP_AFFINITY) -> win.BOOL ---
	GetThreadGroupAffinity :: proc(hThread: win.HANDLE, GroupAffinity: ^GROUP_AFFINITY) -> win.BOOL ---
	GetSystemCpuSetInformation :: proc(Information: ^SYSTEM_CPU_SET_INFORMATION, BufferLength: win.ULONG, ReturnedLength: ^win.ULONG, Process: win.HANDLE, Flags: win.ULONG) -> win.BOOL ---
	SetThreadSelectedCpuSets :: proc(Thread: win.HANDLE, CpuSetIds: ^win.ULONG, CpuSetIdCount: win.ULONG) -> win.BOOL ---
	SetProcessDefaultCpuSets :: proc(Process: win.HANDLE, CpuSetIds: ^win.ULONG, CpuSetIdCount: win.ULONG) -> win.BOOL ---
}

CPU_MAX_GROUPS :: 32

Cpu_Pinning :: struct {
	active:      bool,
	game:        Cpu_Core,
	// Dedicated cores (has_*: false when the thread shares the helper cores).
	network:     Cpu_Core,
	input:       Cpu_Core,
	has_network: bool,
	has_input:   bool,
	// Logical processors each group offers helper threads: everything but the
	// game core, and the network and mouse cores when helpers_exclusive.
	other_masks: [CPU_MAX_GROUPS]u64,
}

g_cpu_pinning: Cpu_Pinning

// Every logical processor the OS reports, from GetSystemCpuSetInformation.
cpu_logical_query :: proc(allocator := context.allocator) -> [dynamic]Cpu_Logical {
	result := make([dynamic]Cpu_Logical, allocator)
	needed: win.ULONG
	GetSystemCpuSetInformation(nil, 0, &needed, nil, 0)
	if needed == 0 { return result }
	// The records hold a DWORD64, so the buffer must be 8-byte aligned (a
	// []u8 from an arena is not, and the call then fails).
	words := make([]u64, (int(needed) + 7) / 8, context.temp_allocator)
	buffer := ([^]u8)(raw_data(words))
	if !GetSystemCpuSetInformation(cast(^SYSTEM_CPU_SET_INFORMATION)buffer, needed, &needed, nil, 0) { return result }
	offset := 0
	for offset + size_of(win.DWORD) * 2 <= int(needed) {
		info := cast(^SYSTEM_CPU_SET_INFORMATION)&buffer[offset]
		if info.Size == 0 { break }
		if info.Type == .CpuSetInformation {
			set := info.CpuSet
			append(&result, Cpu_Logical{
				id = u32(set.Id), group = u16(set.Group), index = u8(set.LogicalProcessorIndex),
				core = u8(set.CoreIndex), efficiency = u8(set.EfficiencyClass), realtime = set.AllFlags & 0x8 != 0,
			})
		}
		offset += int(info.Size)
	}
	return result
}

// Pins the calling thread (the game thread), reserves the network and mouse
// cores, and moves everything else onto the remaining cores. Returns a line
// for the log.
cpu_pinning_apply :: proc() -> string {
	logical := cpu_logical_query(context.temp_allocator)
	cores := cpu_cores_from_logical(logical[:], context.temp_allocator)
	plan, ok := cpu_plan_cores(cores[:])
	if !ok { return fmt.tprintf("CPU pinning skipped: %d physical cores, none besides core 0 to give the game", len(cores)) }
	game := cores[plan.game]

	pinning := Cpu_Pinning{game = game}
	if plan.network >= 0 { pinning.network, pinning.has_network = cores[plan.network], true }
	if plan.input >= 0 { pinning.input, pinning.has_input = cores[plan.input], true }
	helpers := make([dynamic]u32, context.temp_allocator)
	for &core, i in cores {
		if i == plan.game || int(core.group) >= CPU_MAX_GROUPS { continue }
		if plan.helpers_exclusive && (i == plan.network || i == plan.input) { continue }
		pinning.other_masks[core.group] |= core.mask
		append(&helpers, ..core.ids[:core.id_count])
	}

	thread := win.GetCurrentThread()
	affinity := GROUP_AFFINITY{Mask = KAFFINITY(game.mask), Group = game.group}
	if !SetThreadGroupAffinity(thread, &affinity, nil) {
		return fmt.tprintf("CPU pinning failed: game thread affinity (error %d)", win.GetLastError())
	}
	game_ids := game.ids
	SetThreadSelectedCpuSets(thread, &game_ids[0], win.ULONG(game.id_count))
	defaults_ok := len(helpers) > 0 && bool(SetProcessDefaultCpuSets(win.GetCurrentProcess(), &helpers[0], win.ULONG(len(helpers))))
	pinning.active = true
	g_cpu_pinning = pinning
	hybrid := cpu_cores_hybrid(cores[:])
	network_text := pinning.has_network ? cpu_core_describe(pinning.network, hybrid) : "the helper cores"
	input_text := pinning.has_input ? cpu_core_describe(pinning.input, hybrid) : "the helper cores"
	if pinning.has_network && pinning.has_input && plan.network == plan.input { input_text = "shared with networking" }
	return fmt.tprintf("game thread on %s; network thread on %s; mouse thread on %s; helpers on %s%s",
		cpu_core_describe(game, hybrid), network_text, input_text,
		plan.helpers_exclusive ? "the remaining cores" : "every core but the game core",
		defaults_ok ? "" : fmt.tprintf(" (process default CPU sets failed, error %d)", win.GetLastError()))
}

// Keeps the calling thread off the game core (hard affinity, within its
// current processor group). A no-op when pinning is off.
cpu_pin_current_thread_off_game_core :: proc() {
	cpu_pin_current_thread(.Helper)
}

// Pins the calling thread for its role: the network and mouse threads to
// their own core (hard affinity and CPU Sets, which override the process
// default that keeps helpers away from them), helpers to the helper cores.
// A role without a core of its own runs on the helper cores.
cpu_pin_current_thread :: proc(role: Cpu_Role) {
	if !g_cpu_pinning.active { return }
	thread := win.GetCurrentThread()
	core: Cpu_Core
	dedicated := false
	switch role {
	case .Network: core, dedicated = g_cpu_pinning.network, g_cpu_pinning.has_network
	case .Input:   core, dedicated = g_cpu_pinning.input, g_cpu_pinning.has_input
	case .Helper:
	}
	if dedicated {
		affinity := GROUP_AFFINITY{Mask = KAFFINITY(core.mask), Group = core.group}
		if SetThreadGroupAffinity(thread, &affinity, nil) {
			ids := core.ids
			SetThreadSelectedCpuSets(thread, &ids[0], win.ULONG(core.id_count))
			return
		}
	}
	current: GROUP_AFFINITY
	if !GetThreadGroupAffinity(thread, &current) || int(current.Group) >= CPU_MAX_GROUPS { return }
	mask := g_cpu_pinning.other_masks[current.Group]
	if mask == 0 { return }
	affinity := GROUP_AFFINITY{Mask = KAFFINITY(mask), Group = current.Group}
	SetThreadGroupAffinity(thread, &affinity, nil)
}

// For threads that sleep until an event and must run the moment it arrives
// (network, mouse, present): time-critical priority preempts anything else on
// their core. They block almost all the time, so they never starve others.
cpu_raise_current_thread_priority :: proc() {
	win.SetThreadPriority(win.GetCurrentThread(), win.THREAD_PRIORITY_TIME_CRITICAL)
}

// The calling thread's group affinity (tests and diagnostics).
cpu_current_thread_affinity :: proc() -> (group: u16, mask: u64, ok: bool) {
	current: GROUP_AFFINITY
	if !GetThreadGroupAffinity(win.GetCurrentThread(), &current) { return }
	return current.Group, u64(current.Mask), true
}

// Undoes the process-wide part (tests). The pinned thread keeps its affinity.
cpu_pinning_reset :: proc() {
	SetProcessDefaultCpuSets(win.GetCurrentProcess(), nil, 0)
	g_cpu_pinning = {}
}
