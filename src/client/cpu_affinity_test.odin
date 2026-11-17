package main

import "core:testing"

when ODIN_TEST {
	@(private = "file")
	topology :: proc(cores: []struct{ efficiency: u8, smt: int, realtime: bool }) -> [dynamic]Cpu_Logical {
		logical := make([dynamic]Cpu_Logical, context.temp_allocator)
		index := 0
		for core, c in cores {
			for _ in 0 ..< core.smt {
				append(&logical, Cpu_Logical{id = u32(256 + index), index = u8(index), core = u8(c), efficiency = core.efficiency, realtime = core.realtime})
				index += 1
			}
		}
		return logical
	}

	@(test)
	cpu_game_core_is_never_core0 :: proc(t: ^testing.T) {
		// Uniform 4 cores x 2 threads: core 1 (logical 2 and 3), both siblings.
		cores := cpu_cores_from_logical(topology({{0, 2, false}, {0, 2, false}, {0, 2, false}, {0, 2, false}})[:], context.temp_allocator)
		testing.expect_value(t, len(cores), 4)
		pick, ok := cpu_pick_game_core(cores[:])
		testing.expect(t, ok && pick == 1, "uniform CPU: the first core after core 0")
		testing.expect_value(t, cores[pick].mask, u64(0b1100))
		testing.expect_value(t, cores[pick].id_count, 2)
		testing.expect(t, cores[0].is_core0 && !cores[pick].is_core0)

		// Hybrid, E-cores listed first: the first P-core.
		cores = cpu_cores_from_logical(topology({{0, 1, false}, {0, 1, false}, {1, 2, false}, {1, 2, false}})[:], context.temp_allocator)
		pick, ok = cpu_pick_game_core(cores[:])
		testing.expect(t, ok && pick == 2, "hybrid CPU: a P-core")

		// Hybrid, P-cores first: core 0 is a P-core but stays excluded.
		cores = cpu_cores_from_logical(topology({{1, 2, false}, {1, 2, false}, {0, 1, false}, {0, 1, false}})[:], context.temp_allocator)
		pick, ok = cpu_pick_game_core(cores[:])
		testing.expect(t, ok && pick == 1, "hybrid CPU: the next P-core, not core 0")

		// The only P-core is core 0: an E-core, never core 0.
		cores = cpu_cores_from_logical(topology({{1, 2, false}, {0, 1, false}, {0, 1, false}})[:], context.temp_allocator)
		pick, ok = cpu_pick_game_core(cores[:])
		testing.expect(t, ok && pick == 1 && !cores[pick].is_core0, "a lone P-core on core 0 is still skipped")

		// Real-time reserved cores are skipped.
		cores = cpu_cores_from_logical(topology({{0, 2, false}, {0, 2, true}, {0, 2, false}})[:], context.temp_allocator)
		pick, ok = cpu_pick_game_core(cores[:])
		testing.expect(t, ok && pick == 2, "real-time core skipped")

		// One physical core: nothing to pin.
		cores = cpu_cores_from_logical(topology({{0, 2, false}})[:], context.temp_allocator)
		_, ok = cpu_pick_game_core(cores[:])
		testing.expect(t, !ok, "a single core cannot be split")
	}
}
