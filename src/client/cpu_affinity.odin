package main

import "core:fmt"
import "core:strings"

// CPU pinning (cpu_affinity_windows.odin applies it). The game thread (the
// main thread: simulation and render recording) gets one physical core of its
// own. That core is never core 0, which holds logical processor 0 of group 0
// and, with it, most of Windows' interrupt and DPC work. The Krunker network
// thread and the raw mouse thread each get the next best core (cpu_plan_cores).
// Every other thread (HTTP jobs, curl's resolver, audio, the Vulkan present
// thread, the crash watchdog, driver threads) is kept off those cores.
// Selection is pure and platform independent so it can be tested with made-up
// topologies.

CPU_MAX_SMT :: 8 // Logical processors per physical core this code tracks.

// One logical processor, as the OS reports it (Windows CPU Sets).
Cpu_Logical :: struct {
	id:         u32, // CPU Set id
	group:      u16, // Processor group
	index:      u8,  // Group-relative logical processor index
	core:       u8,  // Group-relative physical core index
	efficiency: u8,  // Higher is faster (P-cores on hybrid CPUs); 0 when uniform
	realtime:   bool, // Reserved for real-time use: never pick it
}

Cpu_Core :: struct {
	group:      u16,
	core:       u8,
	efficiency: u8,
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
// class, then the lowest group and index. Fails when no such core exists or
// when nothing would be left for the other threads.
cpu_pick_game_core :: proc(cores: []Cpu_Core) -> (index: int, ok: bool) {
	index = -1
	for core, i in cores {
		if !cpu_core_eligible(core) { continue }
		if index < 0 || cpu_core_better(core, cores[index]) { index = i }
	}
	return index, index >= 0 && len(cores) >= 2
}

// A core a latency-critical thread may own: not core 0 (interrupts and DPCs),
// not reserved for real-time work.
cpu_core_eligible :: proc(core: Cpu_Core) -> bool {
	return !core.is_core0 && !core.realtime && core.mask != 0
}

// Faster efficiency class first, then the lowest group and index.
cpu_core_better :: proc(a, b: Cpu_Core) -> bool {
	if a.efficiency != b.efficiency { return a.efficiency > b.efficiency }
	return a.group < b.group || a.group == b.group && a.core < b.core
}

// Threads with a core of their own, besides the game thread.
Cpu_Role :: enum u8 {
	Helper,  // HTTP jobs, mods, crash watchdog, Vulkan workers: anywhere but the dedicated cores
	Network, // the Krunker WebSocket thread
	Input,   // the raw mouse input thread
}

// Which core each thread gets (indices into the core list; -1: none of its
// own, the thread runs on the helper cores).
//
// The game thread takes the best eligible core, the network thread the next,
// the mouse thread the one after that. With fewer eligible cores the network
// and mouse threads share one, or fall back to the helper cores. Helpers stay
// off the network and mouse cores only while at least two cores remain for
// them: the GPU driver's own threads follow the helper set, and squeezing them
// onto core 0 alone would cost more frame time than the sharing saves (the
// network and mouse threads sleep until data arrives and run at a higher
// priority, so they preempt a helper at once).
Cpu_Plan :: struct {
	game:              int,
	network:           int,
	input:             int,
	helpers_exclusive: bool, // helpers are kept off the network and mouse cores too
}

cpu_plan_cores :: proc(cores: []Cpu_Core) -> (plan: Cpu_Plan, ok: bool) {
	plan = {game = -1, network = -1, input = -1}
	game, game_ok := cpu_pick_game_core(cores)
	if !game_ok { return plan, false }
	plan.game = game
	// The remaining eligible cores, best first.
	ranked := make([dynamic]int, context.temp_allocator)
	for core, i in cores {
		if i == game || !cpu_core_eligible(core) { continue }
		at := len(ranked)
		for at > 0 && cpu_core_better(core, cores[ranked[at - 1]]) { at -= 1 }
		inject_at(&ranked, at, i)
	}
	if len(ranked) >= 1 { plan.network = ranked[0] }
	plan.input = len(ranked) >= 2 ? ranked[1] : plan.network
	helpers := 0
	for _, i in cores {
		if i != plan.game && i != plan.network && i != plan.input { helpers += 1 }
	}
	plan.helpers_exclusive = plan.network >= 0 && helpers >= 2
	return plan, true
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
	return strings.to_string(b)
}

cpu_cores_hybrid :: proc(cores: []Cpu_Core) -> bool {
	for core in cores { if core.efficiency != cores[0].efficiency { return true } }
	return false
}
