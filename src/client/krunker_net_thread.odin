package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import glfw "vendor:glfw"
import curl "vendor:curl"
import kproto "../krunker"

// The Krunker network thread. It owns the WebSocket from the moment it
// connects: every read and every write happens here, never on the game
// thread, so a long frame (map load, shader compile, a GPU wait) can neither
// delay a packet nor be stalled by one.
//
// - It runs on a core of its own (cpu_affinity.odin) at time-critical
//   priority and sleeps on the socket (krunker_net_wait_*.odin): a message is
//   read the moment it arrives and stamped with that arrival time, which
//   snapshot interpolation and shot timing use.
// - Latency probes are answered here, on arrival: SOCKET_PING (pi) with PING
//   (po), and each local snapshot (l) with PONG (v). Answered from the game
//   loop, as before, every reply waited for the next frame, and the server
//   measured that wait as network latency.
// - The game thread queues outgoing packets (krunker_ws_raw_send) and wakes
//   the thread, which sends them at once. Packets carry Krunker's rolling
//   counter in their last two bytes; with replies sent from two places, only
//   the sender can know the order, so the thread rewrites the counter of each
//   packet as it goes out (wire_counter).
// - Complete messages go to an inbox the game thread drains each frame
//   (krunker_ws_poll_threaded). Decoding them and applying them to the game
//   state stay on the game thread, so game state has a single owner.
//
// If the thread cannot start, the game thread reads and writes the socket
// itself (krunker_ws_poll).

// Every buffer that one thread creates and the other frees (payloads,
// packets, error texts) uses the process heap explicitly, never
// context.allocator: the two threads' contexts may differ (the test runner
// gives the game thread a tracking allocator).
@(private = "file")
net_heap :: proc() -> runtime.Allocator { return runtime.heap_allocator() }

Krunker_Net_Inbound :: struct {
	payload: []byte,
	received_at: f64,
}

Krunker_Net_Outbound :: struct {
	packet: []byte, // complete packet; its trailer is rewritten when sent
	opcode: string, // a literal: counter rules (cptR) and logs
}

Krunker_Net_Thread :: struct {
	thread: ^thread.Thread,
	running: bool, // owner: game thread
	stop: bool,    // atomic
	waiter: Net_Waiter,
	// Under lock: the game thread's side of the exchange.
	lock: sync.Mutex,
	inbox: [dynamic]Krunker_Net_Inbound,
	outbox: [dynamic]Krunker_Net_Outbound,
	// The first failure the thread saw; reported by the game thread. Written
	// before `failed` is set under the lock; the thread then exits.
	failed: bool,
	closed: bool,
	close_code: int,
	close_reason: string,
	error_code: curl.code,
	error_detail: string,
	assembly_error: string,
	send_error: string,
	// Network thread only.
	sending: [dynamic]Krunker_Net_Outbound,
	wire_counter: u8,
	recv_chunks: int,
	replies: int,
}

g_net_thread: Krunker_Net_Thread

// Every send from the game thread comes here. With the network thread
// running, the packet is queued for it and counts as sent; a failed thread
// reports the failure instead. Without it, the socket is written directly.
krunker_ws_raw_send :: proc(state: ^Krunker_WS_State, packet: []byte, sent: ^c.size_t, opcode: string) -> curl.code {
	if len(packet) == 0 { return .E_OK }
	net := &g_net_thread
	if !net.running {
		return curl.ws_send(state.handle, rawptr(&packet[0]), c.size_t(len(packet)), sent, 0, curl.WS_BINARY)
	}
	sync.mutex_lock(&net.lock)
	failed := net.failed
	if !failed { append(&net.outbox, Krunker_Net_Outbound{packet = clone_bytes(packet), opcode = opcode}) }
	sync.mutex_unlock(&net.lock)
	if failed { sent^ = 0; return .E_SEND_ERROR }
	net_waiter_wake(&net.waiter)
	sent^ = c.size_t(len(packet))
	return .E_OK
}

@(private = "file")
clone_bytes :: proc(data: []byte) -> []byte {
	copied := make([]byte, len(data), net_heap())
	copy(copied, data)
	return copied
}

krunker_net_thread_start :: proc(state: ^Krunker_WS_State) {
	net := &g_net_thread
	if net.running || state.handle == nil { return }
	net^ = {}
	net.wire_counter = state.ah_num
	net_waiter_init(&net.waiter, state.handle)
	net.thread = thread.create_and_start_with_poly_data(state, krunker_net_thread_run, priority = .High, name = "krunker network")
	if net.thread == nil {
		net_waiter_fini(&net.waiter)
		kproto.network_log("net-thread", "could not start; the game thread reads and writes the socket")
		return
	}
	net.running = true
	state.net_auto_replies = true
	kproto.network_log("net-thread", fmt.tprintf("started; waits on the socket=%v", net_waiter_has_socket(&net.waiter)))
}

krunker_net_thread_stop :: proc() {
	net := &g_net_thread
	if !net.running { return }
	sync.atomic_store(&net.stop, true)
	net_waiter_wake(&net.waiter)
	thread.join(net.thread)
	thread.destroy(net.thread)
	net_waiter_fini(&net.waiter)
	for item in net.inbox { delete(item.payload, net_heap()) }
	for item in net.outbox { delete(item.packet, net_heap()) }
	for item in net.sending { delete(item.packet, net_heap()) }
	delete(net.inbox)
	delete(net.outbox)
	delete(net.sending)
	delete(net.close_reason, net_heap())
	delete(net.error_detail, net_heap())
	delete(net.assembly_error, net_heap())
	delete(net.send_error, net_heap())
	net^ = {}
}

@(private = "file")
krunker_net_thread_run :: proc(state: ^Krunker_WS_State) {
	cpu_pin_current_thread(.Network)
	cpu_raise_current_thread_priority()
	net := &g_net_thread
	for !sync.atomic_load(&net.stop) {
		// What the game thread queued since the last pass.
		sync.mutex_lock(&net.lock)
		if len(net.outbox) > 0 {
			append(&net.sending, ..net.outbox[:])
			clear(&net.outbox)
		}
		sync.mutex_unlock(&net.lock)

		ok, more := krunker_net_thread_receive(state, net)
		// Replies queued by the receive, and the game thread's packets.
		ok = ok && krunker_net_thread_send(state, net)
		free_all(context.temp_allocator)
		if !ok { break }
		if !more { net_waiter_wait(&net.waiter) }
	}
}

// Reads until the socket has nothing more. ok is false on a failure (stored
// for the game thread) or a close; more is true when it stopped with data left.
@(private = "file")
krunker_net_thread_receive :: proc(state: ^Krunker_WS_State, net: ^Krunker_Net_Thread) -> (ok, more: bool) {
	buffer: [16384]byte
	for _ in 0 ..< 1024 {
		received: c.size_t
		meta: ^curl.ws_frame
		code := curl.ws_recv(state.handle, rawptr(&buffer[0]), c.size_t(len(buffer)), &received, &meta)
		if code == .E_AGAIN { return true, false }
		arrived := glfw.GetTime() // thread-safe
		if code != .E_OK {
			detail := strings.clone(string(cast(cstring)&state.error_buffer[0]), net_heap())
			sync.mutex_lock(&net.lock)
			net.error_code, net.error_detail, net.failed = code, detail, true
			sync.mutex_unlock(&net.lock)
			return false, false
		}
		net.recv_chunks += 1
		if meta != nil && (meta.flags & curl.WS_CLOSE) == curl.WS_CLOSE {
			sync.mutex_lock(&net.lock)
			net.close_code = received >= 2 ? int(buffer[0])*256 + int(buffer[1]) : -1
			if received > 2 { net.close_reason = strings.clone(string(buffer[2:int(received)]), net_heap()) }
			net.closed, net.failed = true, true
			sync.mutex_unlock(&net.lock)
			return false, false
		}
		if received == 0 { return true, false }
		if meta == nil { krunker_net_thread_fail_assembly(net, "WebSocket receive omitted frame metadata."); return false, false }
		if (meta.flags & (curl.WS_PING | curl.WS_PONG)) != {} { continue }
		if (meta.flags & curl.WS_TEXT) != {} { continue }
		payload, complete, assembly_error := kproto.krunker_ws_message_feed(&state.message, buffer[:int(received)], i64(meta.offset), i64(meta.bytesleft), (meta.flags & curl.WS_CONT) != {})
		if len(assembly_error) > 0 { krunker_net_thread_fail_assembly(net, assembly_error); return false, false }
		if !complete { continue }
		krunker_net_thread_queue_replies(net, payload)
		inbound := Krunker_Net_Inbound{payload = clone_bytes(payload), received_at = arrived}
		sync.mutex_lock(&net.lock)
		append(&net.inbox, inbound)
		sync.mutex_unlock(&net.lock)
	}
	return true, true // more is waiting; the next pass continues after sending
}

@(private = "file")
krunker_net_thread_fail_assembly :: proc(net: ^Krunker_Net_Thread, text: string) {
	copied := strings.clone(text, net_heap())
	sync.mutex_lock(&net.lock)
	net.assembly_error, net.failed = copied, true
	sync.mutex_unlock(&net.lock)
}

// Answers the latency probes in a message as soon as it arrives, ahead of
// anything else waiting to be sent: one po per pi, one v per l (including
// l(0)), as the browser does. The decode is only for finding opcodes; the
// game thread decodes the message again to apply it.
@(private = "file")
krunker_net_thread_queue_replies :: proc(net: ^Krunker_Net_Thread, payload: []byte) {
	messages, _, error_text := kproto.krunker_msgpack_decode_packet_with_allocator(payload, context.temp_allocator)
	if len(error_text) != 0 { return } // the game thread logs the decode error
	at := 0
	for value in messages {
		packet, ok := value.([]kproto.Krunker_Msgpack_Value)
		if !ok || len(packet) == 0 { continue }
		opcode, is_text := packet[0].(string)
		if !is_text { continue }
		reply := ""
		switch opcode {
		case "pi": reply = "po"
		case "l":  reply = "v"
		case: continue
		}
		unused: u8
		built := krunker_ws_message(reply, &unused, 0)
		inject_at(&net.sending, at, Krunker_Net_Outbound{packet = clone_bytes(built[:]), opcode = reply})
		delete(built)
		at += 1 // keep replies in arrival order
	}
}

// Sends the queue in order. A send the socket cannot take yet (E_AGAIN, nothing
// written) stays first in the queue; the socket's write event wakes the thread
// when it can. Returns false on a failure.
@(private = "file")
krunker_net_thread_send :: proc(state: ^Krunker_WS_State, net: ^Krunker_Net_Thread) -> bool {
	for len(net.sending) > 0 {
		item := net.sending[0]
		packet := item.packet
		if len(packet) < 2 { delete(packet, net_heap()); ordered_remove(&net.sending, 0); continue }
		next := kproto.krunker_msgpack_counter_next(net.wire_counter, item.opcode)
		packet[len(packet) - 2] = (next >> 4) & 0x0f
		packet[len(packet) - 1] = next & 0x0f
		sent: c.size_t
		code := curl.ws_send(state.handle, rawptr(&packet[0]), c.size_t(len(packet)), &sent, 0, curl.WS_BINARY)
		if code == .E_AGAIN && sent == 0 { return true }
		if code != .E_OK || int(sent) != len(packet) {
			text := fmt.aprintf("opcode=%s curl=%v (%s) sent=%d expected=%d detail=%s", item.opcode, code, string(curl.easy_strerror(code)), sent, len(packet), string(cast(cstring)&state.error_buffer[0]), allocator = net_heap())
			sync.mutex_lock(&net.lock)
			net.error_code, net.send_error, net.failed = code, text, true
			sync.mutex_unlock(&net.lock)
			return false
		}
		net.wire_counter = next
		if item.opcode == "po" || item.opcode == "v" {
			net.replies += 1
			if net.replies <= 3 { kproto.network_log("net-thread", fmt.tprintf("answered on arrival opcode=%s counter=%d", item.opcode, next)) }
		}
		delete(packet, net_heap())
		ordered_remove(&net.sending, 0)
	}
	return true
}

// The threaded counterpart of krunker_ws_poll: applies what the network
// thread received, in arrival order, with each message's arrival time.
krunker_ws_poll_threaded :: proc(client: ^Client) {
	state := &client.krunker
	net := &g_net_thread
	if !krunker_ws_flush_pending(state) { state.connected = false; krunker_ws_set_status(client, "Krunker WebSocket send failed."); return }

	inbox: [dynamic]Krunker_Net_Inbound
	sync.mutex_lock(&net.lock)
	inbox, net.inbox = net.inbox, {}
	failed, closed := net.failed, net.closed
	sync.mutex_unlock(&net.lock)
	defer {
		for item in inbox { delete(item.payload, net_heap()) }
		delete(inbox)
	}

	for item in inbox {
		krunker_ws_apply_world(client, item.payload, received_at = item.received_at)
		if !state.connected { return }
	}
	if failed {
		state.connected = false
		switch {
		case closed:
			kproto.network_log("ws-close", fmt.tprintf("code=%d reason=%s (network thread) got_load=%v spawned=%v", net.close_code, net.close_reason, state.got_load, state.spawned))
			if len(state.server_error) > 0 { krunker_ws_set_status(client, fmt.tprintf("Krunker disconnected: %s; see logs/krunker-network.log", state.server_error)) }
			else if net.close_code < 0 { krunker_ws_set_status(client, "Krunker lobby closed the WebSocket without a status or reason; see logs/krunker-network.log") }
			else { krunker_ws_set_status(client, fmt.tprintf("Krunker lobby closed the WebSocket: %d %s; see logs/krunker-network.log", net.close_code, net.close_reason)) }
		case len(net.assembly_error) > 0:
			krunker_ws_set_status(client, net.assembly_error)
		case len(net.send_error) > 0:
			kproto.network_log("ws-send", fmt.tprintf("ERROR (network thread) %s", net.send_error))
			krunker_ws_set_status(client, "Krunker WebSocket send failed; see logs/krunker-network.log")
		case:
			kproto.network_log("ws-recv", fmt.tprintf("ERROR curl=%v (network thread) detail=%s", net.error_code, net.error_detail))
			krunker_ws_set_status(client, fmt.tprintf("Krunker WebSocket receive failed: %v; see logs/krunker-network.log", net.error_code))
		}
		return
	}
	krunker_ws_bootstrap_tick(client)
}
