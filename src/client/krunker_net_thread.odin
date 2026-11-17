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

Krunker_Net_Inbound :: struct {
	payload: []byte,
	received_at: f64,
}

Krunker_Net_Thread :: struct {
	thread: ^thread.Thread,
	lock: sync.Mutex,
	running: bool, // owner: game thread
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
	net.thread = thread.create_and_start_with_poly_data(state, krunker_net_thread_run)
	if net.thread == nil { kproto.network_log("net-thread", "could not start; reading on the game thread"); return }
	net.running = true
	kproto.network_log("net-thread", "started")
}

krunker_net_thread_stop :: proc() {
	net := &g_net_thread
	if !net.running { return }
	sync.atomic_store(&net.stop, true)
	thread.join(net.thread)
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
	net := &g_net_thread
	buffer: [16384]byte
	for !sync.atomic_load(&net.stop) {
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
			append(&net.inbox, Krunker_Net_Inbound{payload = copied, received_at = glfw.GetTime()})
		}
		sync.mutex_unlock(&net.lock)
		if failed { break }
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
