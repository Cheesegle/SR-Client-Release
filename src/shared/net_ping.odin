package shared

import "core:encoding/endian"

// Native round-trip probe. The client sends PING with a sequence number and
// the server echoes the same packet back. Servers that predate the echo skip
// the unknown type, so this does not change PROTOCOL_VERSION.
NET_PING_PAYLOAD_SIZE :: 4
NET_PING_PACKET_SIZE :: PACKET_HEADER_SIZE + NET_PING_PAYLOAD_SIZE
NET_PING_INTERVAL :: 1.0

packet_serialize_ping :: proc(buf: []byte, seq: u32) -> int {
	if len(buf) < NET_PING_PACKET_SIZE { return 0 }
	endian.put_u32(buf[:4], .Little, PACKET_MAGIC)
	buf[4] = u8(Packet_Type.PING)
	endian.put_u16(buf[5:7], .Little, NET_PING_PAYLOAD_SIZE)
	endian.put_u32(buf[PACKET_HEADER_SIZE:NET_PING_PACKET_SIZE], .Little, seq)
	return NET_PING_PACKET_SIZE
}

packet_deserialize_ping :: proc(buf: []byte) -> (seq: u32, ok: bool) {
	header, header_ok := packet_deserialize_header(buf)
	if !header_ok || header.packet_type != .PING || header.payload_len != NET_PING_PAYLOAD_SIZE || len(buf) != NET_PING_PACKET_SIZE { return 0, false }
	seq, _ = endian.get_u32(buf[PACKET_HEADER_SIZE:NET_PING_PACKET_SIZE], .Little)
	return seq, true
}

// One probe is in flight at a time. A reply only counts when it matches the
// outstanding sequence, so late echoes never produce a short sample.
Net_Ping_State :: struct {
	seq: u32,
	sent_at: f64,
	outstanding, has_sample: bool,
	rtt_ms: i32,
}

net_ping_due :: proc(state: ^Net_Ping_State, now: f64) -> (seq: u32, send: bool) {
	if state.seq != 0 && now - state.sent_at < NET_PING_INTERVAL { return 0, false }
	state.seq += 1
	if state.seq == 0 { state.seq = 1 }
	state.sent_at, state.outstanding = now, true
	return state.seq, true
}

net_ping_receive :: proc(state: ^Net_Ping_State, seq: u32, now: f64) -> bool {
	if !state.outstanding || seq != state.seq || now < state.sent_at { return false }
	state.outstanding, state.has_sample = false, true
	// Krunker shows the most recent value without client-side smoothing.
	state.rtt_ms = i32((now - state.sent_at) * 1000 + 0.5)
	return true
}
