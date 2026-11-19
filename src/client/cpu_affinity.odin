package main

import "core:fmt"
import "core:strings"

// CPU pinning (cpu_affinity_windows.odin applies it). The game thread (the
// main thread: simulation, rendering and network polling) gets one physical
// core of its own. That core is never core 0, which holds logical processor 0
// of group 0 and, with it, most of Windows' interrupt and DPC work. Every other
// thread (HTTP jobs, curl's resolver, audio, raw mouse input, the crash
// watchdog, driver threads) is kept off the game core. Selection is pure and
// platform independent so it can be tested with made-up topologies.

// The pinning result line, kept for the tester export.
g_cpu_pinning_text: string
g_cpu_physical_cores: int // 0 when unknown

CPU_MAX_SMT :: 8 // Logical processors per physical core this code tracks.

// One logical processor, as the OS reports it (Windows CPU Sets).
Cpu_Logical :: struct {
	id:         u32, // CPU Set id
	group:      u16, // Processor group
	index:      u8,  // Group-relative logical processor index
	core:       u8,  // Group-relative physical core index
	efficiency: u8,  // Higher is faster (P-cores on hybrid CPUs); 0 when uniform
	realtime:   bool, // Reserved for real-time use: never pick it
	l3_kb:      u32, // Size of the L3 cache this processor uses; 0 when unknown
}

Cpu_Core :: struct {
	group:      u16,
	core:       u8,
	efficiency: u8,
	l3_kb:      u32, // Largest L3 any of its logical processors uses
	mask:       u64, // Group-relative logical processor bits
	ids:        [CPU_MAX_SMT]u32,
	id_count:   int,
	is_core0:   bool, // Holds logical processor 0 of group 0
	realtime:   bool,
}

// Groups logical processors into physical cores, in reported order.
cpu_cores_from_logical :: proc(logical: []Cpu_Logical, allocator := context.allocator) -> [dynamic]Cpu_Core {
	cores := make([dynamic]Cpu_Core, allocator)
	for lp in logical {
		if lp.index >= 64 { continue }
		found := -1
		for &core, i in cores {
			if core.group == lp.group && core.core == lp.core { found = i; break }
		}
		if found < 0 {
			append(&cores, Cpu_Core{group = lp.group, core = lp.core, efficiency = lp.efficiency})
			found = len(cores) - 1
		}
		core := &cores[found]
		core.mask |= u64(1) << lp.index
		core.efficiency = max(core.efficiency, lp.efficiency)
		core.l3_kb = max(core.l3_kb, lp.l3_kb)
		if core.id_count < CPU_MAX_SMT {
			core.ids[core.id_count] = lp.id
			core.id_count += 1
		}
		if lp.group == 0 && lp.index == 0 { core.is_core0 = true }
		if lp.realtime { core.realtime = true }
	}
	return cores
}

// The game thread's core: not core 0, not real-time, the fastest efficiency
// class, then the biggest L3 cache (on Ryzen X3D chips with two dies only one
// die has the extra 3D V-Cache, e.g. 7950X3D/9950X3D: 96 MB vs 32 MB), then
// the lowest group and index. CPUs with one L3 size are unaffected. Fails when no such core exists or
// when nothing would be left for the other threads.
cpu_pick_game_core :: proc(cores: []Cpu_Core) -> (index: int, ok: bool) {
	index = -1
	for core, i in cores {
		if core.is_core0 || core.realtime || core.mask == 0 { continue }
		if index < 0 { index = i; continue }
		best := cores[index]
		if core.efficiency != best.efficiency {
			if core.efficiency > best.efficiency { index = i }
			continue
		}
		if core.l3_kb != best.l3_kb {
			if core.l3_kb > best.l3_kb { index = i }
			continue
		}
		if core.group < best.group || core.group == best.group && core.core < best.core { index = i }
	}
	return index, index >= 0 && len(cores) >= 2
}

cpu_core_describe :: proc(core: Cpu_Core, hybrid: bool) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "core %d", core.core)
	if core.group != 0 { fmt.sbprintf(&b, " (group %d)", core.group) }
	strings.write_string(&b, ", logical")
	for bit in 0 ..< 64 {
		if core.mask & (u64(1) << u64(bit)) != 0 { fmt.sbprintf(&b, " %d", bit) }
	}
	if hybrid { fmt.sbprintf(&b, ", efficiency class %d", core.efficiency) }
	if core.l3_kb > 0 { fmt.sbprintf(&b, ", L3 %d MB", core.l3_kb / 1024) }
	return strings.to_string(b)
}

cpu_cores_hybrid :: proc(cores: []Cpu_Core) -> bool {
	for core in cores { if core.efficiency != cores[0].efficiency { return true } }
	return false
}
