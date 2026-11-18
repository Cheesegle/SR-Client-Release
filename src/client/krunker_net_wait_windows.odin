#+build windows
package main

import win "core:sys/windows"
import curl "vendor:curl"

// The network thread sleeps here until there is something to do: data or a
// close on the WebSocket's TCP socket (WSAEventSelect), room to send again
// after a blocked send, or a packet queued by the game thread (wake). Nothing
// polls, so a snapshot or a ping is read the moment Windows has it, and a
// queued input packet leaves without waiting for a timer tick.
//
// curl (CONNECT_ONLY) keeps the socket non-blocking itself, which
// WSAEventSelect also requires; curl never waits on the socket after the
// upgrade, so the association does not disturb it.
Net_Waiter :: struct {
	socket:       win.SOCKET,
	socket_event: win.HANDLE, // nil: the socket was not available; wait on wake with a short timeout
	wake:         win.HANDLE, // auto-reset
}

// Upper bound on one wait. Events end it as soon as anything happens; the
// bound only matters if Windows ever missed one.
NET_WAIT_MAX_MS :: 2
// Without a socket event (should not happen): poll on this interval.
NET_WAIT_POLL_MS :: 1

net_waiter_init :: proc(w: ^Net_Waiter, handle: ^curl.CURL) {
	w^ = {}
	w.wake = win.CreateEventW(nil, false, false, nil)
	// curl_socket_t is a SOCKET (pointer-sized) on Windows; the binding's
	// socket_t is a C int, too small to receive it.
	socket := win.INVALID_SOCKET
	if handle == nil || curl.easy_getinfo(handle, .ACTIVESOCKET, &socket) != .E_OK || socket == win.INVALID_SOCKET { return }
	event := win.WSACreateEvent()
	if event == nil { return }
	if win.WSAEventSelect(socket, event, win.FD_READ | win.FD_WRITE | win.FD_CLOSE) != 0 {
		win.WSACloseEvent(event)
		return
	}
	w.socket, w.socket_event = socket, event
}

// Before curl closes the socket: drops the association (the socket stays
// non-blocking, as curl expects).
net_waiter_fini :: proc(w: ^Net_Waiter) {
	if w.socket_event != nil {
		win.WSAEventSelect(w.socket, nil, 0)
		win.WSACloseEvent(w.socket_event)
	}
	if w.wake != nil { win.CloseHandle(w.wake) }
	w^ = {}
}

net_waiter_has_socket :: proc(w: ^Net_Waiter) -> bool { return w.socket_event != nil }

// Any thread: ends the network thread's current or next wait.
net_waiter_wake :: proc(w: ^Net_Waiter) {
	if w.wake != nil { win.SetEvent(w.wake) }
}

net_waiter_wait :: proc(w: ^Net_Waiter) {
	handles: [2]win.HANDLE
	count: u32
	if w.socket_event != nil { handles[count] = w.socket_event; count += 1 }
	if w.wake != nil { handles[count] = w.wake; count += 1 }
	if count == 0 { win.Sleep(NET_WAIT_POLL_MS); return }
	timeout: u32 = w.socket_event != nil ? NET_WAIT_MAX_MS : NET_WAIT_POLL_MS
	win.WaitForMultipleObjects(count, &handles[0], false, timeout)
	if w.socket_event != nil {
		// Clears the recorded events and resets the event object. FD_READ is
		// re-recorded by the next recv while data remains.
		events: win.WSANETWORKEVENTS
		win.WSAEnumNetworkEvents(w.socket, w.socket_event, &events)
	}
}
