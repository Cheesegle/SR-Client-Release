package main

import "core:testing"

when ODIN_TEST {
	@(test)
	net_thread_answers_only_pings :: proc(t: ^testing.T) {
		pi := []byte{0x91, 0xA2, 'p', 'i', 0x00, 0x01}
		testing.expect_value(t, krunker_net_ping_count(pi), 1)
		two := []byte{0x91, 0xA2, 'p', 'i', 0x91, 0xA2, 'p', 'i', 0x00, 0x01}
		testing.expect_value(t, krunker_net_ping_count(two), 2)
		po := []byte{0x91, 0xA2, 'p', 'o', 0x00, 0x01}
		testing.expect_value(t, krunker_net_ping_count(po), 0)
		mixed := []byte{0x92, 0xA1, 'k', 0x05, 0x91, 0xA2, 'p', 'i', 0x00, 0x01}
		testing.expect_value(t, krunker_net_ping_count(mixed), 1)
		testing.expect_value(t, krunker_net_ping_count([]byte{0xA2, 'p', 'i'}), 0)
		big := make([]byte, 200, context.temp_allocator)
		big[0] = 0x91
		testing.expect_value(t, krunker_net_ping_count(big), 0)
	}

	@(test)
	net_thread_ping_handoff_counts_down :: proc(t: ^testing.T) {
		saved := g_net_thread
		defer g_net_thread = saved
		g_net_thread = {}
		testing.expect(t, !krunker_net_thread_took_ping(), "no thread: the game thread answers")
		g_net_thread.running = true
		g_net_thread.po_answered = 2
		testing.expect(t, krunker_net_thread_took_ping())
		testing.expect(t, krunker_net_thread_took_ping())
		testing.expect(t, !krunker_net_thread_took_ping(), "each answered pi is skipped once")
		g_net_thread = {}
	}
}
