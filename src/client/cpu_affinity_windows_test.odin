#+build windows
package main

import "core:testing"
import "core:thread"
import "core:time"
import win "core:sys/windows"

when ODIN_TEST {
	foreign import kernel32_test "system:Kernel32.lib"

	@(private = "file")
	PROCESSOR_NUMBER :: struct {
		Group:    u16,
		Number:   u8,
		Reserved: u8,
	}

	@(default_calling_convention = "system", private = "file")
	foreign kernel32_test {
		GetCurrentProcessorNumberEx :: proc(ProcNumber: ^PROCESSOR_NUMBER) ---
	}

	@(private = "file")
	Pin_Probe :: struct {
		t:                 ^testing.T,
		applied:           bool,
		game:              Cpu_Core,
		game_group:        u16,
		game_mask:         u64,
		game_ran_off_core: int, // Samples of the pinned thread outside its core
		child_mask:        u64,
		child_on_game:     int, // Samples of an unpinned child on the game core
		helper_mask:       u64,
		helper_group:      u16,
		samples:           int,
	}

	@(private = "file")
	on_game_core :: proc(game: Cpu_Core) -> bool {
		number: PROCESSOR_NUMBER
		GetCurrentProcessorNumberEx(&number)
		return number.Group == game.group && game.mask & (u64(1) << number.Number) != 0
	}

	@(private = "file")
	spin_sample :: proc(probe: ^Pin_Probe, count: ^int, want_on_game: bool) {
		deadline := time.tick_now()
		for time.tick_since(deadline) < 150 * time.Millisecond {
			if on_game_core(probe.game) != want_on_game { count^ += 1 }
			probe.samples += 1
		}
	}

	// A thread the pinned thread starts without any pinning call of its own
	// (what curl's resolver threads are): it must not inherit the game core.
	@(private = "file")
	child_main :: proc(data: rawptr) {
		probe := cast(^Pin_Probe)data
		_, probe.child_mask, _ = cpu_current_thread_affinity()
		spin_sample(probe, &probe.child_on_game, false)
	}

	@(private = "file")
	helper_main :: proc(data: rawptr) {
		probe := cast(^Pin_Probe)data
		cpu_pin_current_thread_off_game_core()
		probe.helper_group, probe.helper_mask, _ = cpu_current_thread_affinity()
	}

	@(private = "file")
	game_main :: proc(data: rawptr) {
		probe := cast(^Pin_Probe)data
		cpu_pinning_apply()
		probe.applied = g_cpu_pinning.active
		if !probe.applied { return }
		probe.game = g_cpu_pinning.game
		probe.game_group, probe.game_mask, _ = cpu_current_thread_affinity()
		child := thread.create_and_start_with_data(probe, child_main)
		spin_sample(probe, &probe.game_ran_off_core, true)
		thread.join(child)
		thread.destroy(child)
		helper := thread.create_and_start_with_data(probe, helper_main)
		thread.join(helper)
		thread.destroy(helper)
	}

	@(test)
	cpu_pinning_keeps_game_core_exclusive :: proc(t: ^testing.T) {
		// An odd-sized allocation first: the query must not depend on the
		// temp arena happening to hand out 8-byte aligned memory.
		_ = make([]u8, 3, context.temp_allocator)
		logical := cpu_logical_query(context.temp_allocator)
		system: win.SYSTEM_INFO
		win.GetSystemInfo(&system)
		testing.expectf(t, len(logical) >= int(system.dwNumberOfProcessors), "the CPU Set query must see every logical processor: %d of %d", len(logical), system.dwNumberOfProcessors)
		cores := cpu_cores_from_logical(logical[:], context.temp_allocator)
		if len(cores) < 2 {
			testing.expect(t, system.dwNumberOfProcessors <= 2, "only a one-core machine may skip pinning")
			return
		}
		probe := Pin_Probe{t = t}
		game := thread.create_and_start_with_data(&probe, game_main)
		thread.join(game)
		thread.destroy(game)
		defer cpu_pinning_reset()
		if !testing.expect(t, probe.applied, "pinning applies on a multi-core machine") { return }

		testing.expect(t, !probe.game.is_core0, "the game core is never core 0")
		testing.expect(t, probe.game_group == probe.game.group && probe.game_mask == probe.game.mask, "the game thread's hard affinity is exactly its core")
		testing.expect(t, !(probe.game_group == 0 && probe.game_mask & 1 != 0), "the game thread can never run on logical processor 0")
		testing.expectf(t, probe.game_ran_off_core == 0, "the game thread ran off its core %d times", probe.game_ran_off_core)

		testing.expectf(t, probe.child_mask & ~probe.game.mask != 0, "a thread the game thread starts must not inherit its core (mask %x)", probe.child_mask)
		testing.expectf(t, probe.child_on_game == 0, "an unpinned child ran on the game core %d times", probe.child_on_game)

		testing.expect(t, probe.helper_mask != 0 && (probe.helper_group != probe.game.group || probe.helper_mask & probe.game.mask == 0), "a helper thread is kept off the game core")
	}
}
