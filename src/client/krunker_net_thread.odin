package main

import "core:c"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import glfw "vendor:glfw"
import curl "vendor:curl"
import kproto "../krunker"

// Optional network thread (Settings > Experimental > Network thread).
//
// Off: the game loop reads the WebSocket itself each frame (krunker_ws_poll).
// On: a thread reads the socket about every millisecond, assembles complete
// messages and stamps their arrival time; the game loop only takes the
// finished messages. A slow frame then no longer delays reading, a network
// burst no longer stalls a frame, and snapshot timing (interpolation) uses
// the real arrival time instead of the frame's. Decoding and applying stay on
// the game thread, so game state is never touched by two threads.
//
// The curl handle is shared: every ws_send / ws_recv holds net_lock.
//
// SR 0.47: the thread also answers Krunker's ping (pi) with po the moment it
// arrives, as the browser does from its message event between frames,
// instead of waiting for the next game frame. Every sender holds send_lock
// from reading the packet counter (ah_num) until it commits it, so the
// counter keeps exactly one writer at a time. Lock order: send_lock, then lock.
// Inputs stay on the game thread, built per frame exactly like Krunker's own
// client, so hit registration is unchanged.

Krunker_Net_Inbound :: struct {
	payload: []byte,
	received_at: f64,
}

Krunker_Net_Thread :: struct {
	thread: ^thread.Thread,
	lock: sync.Mutex,
	send_lock: sync.Mutex,
	running: bool, // owner: game thread
	po_answered: int, // atomic: pi the thread answered that the game thread has not seen yet
	po_sent: int,     // diagnostics
	stop: bool,    // atomic
	inbox: [dynamic]Krunker_Net_Inbound,
	// The first failure the thread saw; reported by the game thread.
	failed: bool,
	closed: bool,
	close_code: int,
	close_reason: string,
	error_code: curl.code,
	error_detail: string,
	assembly_error: string,
	recv_chunks: int,
}

g_net_thread: Krunker_Net_Thread

// Every send goes through here so the network thread never uses the handle at
// the same time.
// Held by every sender from reading ah_num to committing it.
krunker_net_send_begin :: proc() { if g_net_thread.running { sync.mutex_lock(&g_net_thread.send_lock) } }
krunker_net_send_end :: proc() { if g_net_thread.running { sync.mutex_unlock(&g_net_thread.send_lock) } }

// The game thread saw a pi: true when the network thread already answered it.
krunker_net_thread_took_ping :: proc() -> bool {
	net := &g_net_thread
	if !net.running { return false }
	for {
		n := sync.atomic_load(&net.po_answered)
		if n <= 0 { return false }
		if _, ok := sync.atomic_compare_exchange_strong(&net.po_answered, n, n - 1); ok { return true }
	}
}

// pi messages in one complete payload (tiny payloads only; pi is 1 element).
krunker_net_ping_count :: proc(payload: []byte) -> int {
	if len(payload) == 0 || len(payload) > 64 || payload[0] & 0xF0 != 0x90 { return 0 }
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	messages, _, error_text := kproto.krunker_msgpack_decode_packet(payload)
	if len(error_text) != 0 { return 0 }
	count := 0
	for value in messages {
		packet, ok := value.([]kproto.Krunker_Msgpack_Value)
		if !ok || len(packet) == 0 { continue }
		if opcode, text := packet[0].(string); text && opcode == "pi" { count += 1 }
	}
	return count
}

// Sends po from the network thread with the shared counter.
@(private = "file")
krunker_net_send_po :: proc(state: ^Krunker_WS_State) -> bool {
	net := &g_net_thread
	sync.mutex_lock(&net.send_lock)
	defer sync.mutex_unlock(&net.send_lock)
	if len(state.pending) > 0 { return false } // keep order behind queued control messages
	next_counter := state.ah_num
	packet := krunker_ws_message("po", &next_counter, state.q_index)
	defer delete(packet)
	sent: c.size_t
	sync.mutex_lock(&net.lock)
	code := curl.ws_send(state.handle, rawptr(&packet[0]), c.size_t(len(packet)), &sent, 0, curl.WS_BINARY)
	sync.mutex_unlock(&net.lock)
	if code != .E_OK || int(sent) != len(packet) { return false }
	state.ah_num = next_counter
	net.po_sent += 1
	return true
}

krunker_ws_raw_send :: proc(state: ^Krunker_WS_State, packet: []byte, sent: ^c.size_t) -> curl.code {
	if len(packet) == 0 { return .E_OK }
	net := &g_net_thread
	if net.running { sync.mutex_lock(&net.lock) }
	defer if net.running { sync.mutex_unlock(&net.lock) }
	return curl.ws_send(state.handle, rawptr(&packet[0]), c.size_t(len(packet)), sent, 0, curl.WS_BINARY)
}

krunker_net_thread_start :: proc(state: ^Krunker_WS_State) {
	net := &g_net_thread
	if net.running || state.handle == nil { return }
	net^ = {}
	// running first: from here every game-thread sender takes send_lock.
	net.running = true
	net.thread = thread.create_and_start_with_poly_data(state, krunker_net_thread_run)
	if net.thread == nil { net.running = false; kproto.network_log("net-thread", "could not start; reading on the game thread"); return }
	kproto.network_log("net-thread", "started")
}

krunker_net_thread_stop :: proc() {
	net := &g_net_thread
	if !net.running { return }
	sync.atomic_store(&net.stop, true)
	thread.join(net.thread)
	if net.po_sent > 0 { kproto.network_log("net-thread", fmt.tprintf("stopped; answered %d pings on the network thread", net.po_sent)) }
	thread.destroy(net.thread)
	for item in net.inbox { delete(item.payload) }
	delete(net.inbox)
	delete(net.close_reason)
	delete(net.error_detail)
	delete(net.assembly_error)
	net^ = {}
}

@(private = "file")
krunker_net_thread_run :: proc(state: ^Krunker_WS_State) {
	cpu_pin_current_thread_off_game_core() // never on the game thread's core
	net := &g_net_thread
	buffer: [16384]byte
	for !sync.atomic_load(&net.stop) {
		pings := 0
		held: Krunker_Net_Inbound
		sync.mutex_lock(&net.lock)
		failed := net.failed
		for iterations := 0; !failed && iterations < 256; iterations += 1 {
			received: c.size_t
			meta: ^curl.ws_frame
			code := curl.ws_recv(state.handle, rawptr(&buffer[0]), c.size_t(len(buffer)), &received, &meta)
			if code == .E_AGAIN { break }
			if code != .E_OK {
				net.failed, net.error_code = true, code
				net.error_detail = strings.clone(string(cast(cstring)&state.error_buffer[0]))
				failed = true
				break
			}
			net.recv_chunks += 1
			if meta != nil && (meta.flags & curl.WS_CLOSE) == curl.WS_CLOSE {
				net.failed, net.closed = true, true
				net.close_code = received >= 2 ? int(buffer[0])*256 + int(buffer[1]) : -1
				if received > 2 { net.close_reason = strings.clone(string(buffer[2:int(received)])) }
				failed = true
				break
			}
			if received == 0 { break }
			if meta == nil { net.failed = true; net.assembly_error = strings.clone("WebSocket receive omitted frame metadata."); failed = true; break }
			if (meta.flags & (curl.WS_PING | curl.WS_PONG)) != {} { continue }
			if (meta.flags & curl.WS_TEXT) != {} { continue }
			payload, complete, assembly_error := kproto.krunker_ws_message_feed(&state.message, buffer[:int(received)], i64(meta.offset), i64(meta.bytesleft), (meta.flags & curl.WS_CONT) != {})
			if len(assembly_error) > 0 { net.failed = true; net.assembly_error = strings.clone(assembly_error); failed = true; break }
			if !complete { continue }
			copied := make([]byte, len(payload))
			copy(copied, payload)
			if pings = krunker_net_ping_count(copied); pings > 0 {
				// Hand this message over only after po went out (below), so the
				// game thread never sees a pi without knowing it was answered.
				held = Krunker_Net_Inbound{payload = copied, received_at = glfw.GetTime()}
				break
			}
			append(&net.inbox, Krunker_Net_Inbound{payload = copied, received_at = glfw.GetTime()})
		}
		sync.mutex_unlock(&net.lock)
		if failed { break }
		if pings > 0 {
			// Answer pi now. The game thread skips the po for each one answered here.
			for _ in 0 ..< pings {
				if !state.connected || !krunker_net_send_po(state) { break }
				sync.atomic_add(&net.po_answered, 1)
			}
			sync.mutex_lock(&net.lock)
			append(&net.inbox, held)
			sync.mutex_unlock(&net.lock)
			continue // poll again right away
		}
		time.sleep(time.Millisecond)
	}
}

// The threaded counterpart of krunker_ws_poll.
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
		for item in inbox { delete(item.payload) }
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
		case:
			kproto.network_log("ws-recv", fmt.tprintf("ERROR curl=%v (network thread) detail=%s", net.error_code, net.error_detail))
			krunker_ws_set_status(client, fmt.tprintf("Krunker WebSocket receive failed: %v; see logs/krunker-network.log", net.error_code))
		}
		return
	}
	krunker_ws_bootstrap_tick(client)
}
