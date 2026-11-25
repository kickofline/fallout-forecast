extends RefCounted
## One accepted Open Protocol WebSocket or raw TCP connection.
##
## A tier owns the connection after hello. Call poll() once per frame to get
## [{"data": PackedByteArray, "text": bool}, ...]. Check closed after polling.
## Use send_message(Dictionary) for JSON and send_binary(PackedByteArray) for
## binary. close(reason) initiates a flush/close. Keep polling until closed,
## then call dispose(). peer_address is the TCP peer IP; encoding is "json"
## or "bin", selected from hello. The common listener will stop polling it.

const MULTIPLEXED_FRAME_LIMIT := 65536
const OUT_LIMIT := 524288
const MAX_BATCH := 64

var encoding := "json"
var peer_address: String
var ws: WebSocketPeer
var tcp: StreamPeerTCP
var deadline := 0
var closed := false
var closing := false
var _in := PackedByteArray()
var _out := PackedByteArray()

## Godot's JSON.stringify leaves U+0000-U+001F raw (except \b \t \n \f \r) and
## writes U+000B as "\v", neither of which is valid JSON. _UNSAFE spots either
## quickly; _TOKENS walks escape pairs so a literal backslash is never misread.
static var _UNSAFE: RegEx
static var _TOKENS: RegEx


func _init(stream: StreamPeerTCP, websocket: bool) -> void:
	stream.set_no_delay(true)
	peer_address = stream.get_connected_host()
	deadline = Time.get_ticks_msec() + 5000
	if websocket:
		ws = WebSocketPeer.new()
		ws.inbound_buffer_size = MULTIPLEXED_FRAME_LIMIT * 2
		ws.outbound_buffer_size = OUT_LIMIT
		ws.heartbeat_interval = 2.0
		closed = ws.accept_stream(stream) != OK
	else:
		tcp = stream


func poll(limit := MAX_BATCH) -> Array[Dictionary]:
	var packets: Array[Dictionary] = []
	if closed:
		return packets
	if ws:
		ws.poll()
		if ws.get_ready_state() == WebSocketPeer.STATE_CLOSED:
			closed = true
		elif ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
			for _i in mini(ws.get_available_packet_count(), limit):
				var data := ws.get_packet()
				if data.size() > MULTIPLEXED_FRAME_LIMIT:
					closed = true
					return []
				packets.append({"data": data, "text": ws.was_string_packet()})
	else:
		tcp.poll()
		if tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			closed = true
			return packets
		var available := tcp.get_available_bytes()
		if available > 0:
			var read: Array = tcp.get_partial_data(mini(available, MULTIPLEXED_FRAME_LIMIT))
			if read[0] != OK:
				closed = true
				return []
			_in.append_array(read[1])
		var offset := 0
		while _in.size() - offset >= 4 and packets.size() < limit:
			var length := _in.decode_u32(offset)
			if length == 0 or length > MULTIPLEXED_FRAME_LIMIT:
				closed = true
				return []
			if _in.size() - offset - 4 < length:
				break
			var data := _in.slice(offset + 4, offset + 4 + length)
			packets.append({"data": data, "text": data[0] >= 0x09})
			offset += 4 + length
		if offset:
			_in = _in.slice(offset)
		if _in.size() > 2 * MULTIPLEXED_FRAME_LIMIT:
			closed = true
		_flush()
		if closing and _out.is_empty():
			closed = true
	if deadline and Time.get_ticks_msec() >= deadline:
		closed = true
	return packets


func send_message(message: Dictionary) -> void:
	_send(strict_json(JSON.stringify(message, "", false)).to_utf8_buffer(), true)


## Rewrite JSON.stringify output into RFC 8259 JSON. Clean text passes through.
static func strict_json(text: String) -> String:
	if _UNSAFE == null:
		_UNSAFE = RegEx.create_from_string("[\\x00-\\x1f]|\\\\v")
		_TOKENS = RegEx.create_from_string("\\\\.|[\\x00-\\x1f]")
	if _UNSAFE.search(text) == null:
		return text
	var out := ""
	var last := 0
	for found in _TOKENS.search_all(text):
		var token := found.get_string()
		var replacement := token
		if token == "\\v":
			replacement = "\\u000b"
		elif token.length() == 1:
			replacement = "\\u%04x" % token.unicode_at(0)
		if replacement != token:
			out += text.substr(last, found.get_start() - last) + replacement
			last = found.get_end()
	return out + text.substr(last)


func send_binary(payload: PackedByteArray) -> void:
	_send(payload, false)


func _send(payload: PackedByteArray, text: bool) -> void:
	if closed or closing:
		return
	if ws:
		if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
			var mode := WebSocketPeer.WRITE_MODE_TEXT if text else WebSocketPeer.WRITE_MODE_BINARY
			if ws.send(payload, mode) != OK:
				closed = true
	else:
		if _out.size() + payload.size() + 4 > OUT_LIMIT:
			closed = true
			return
		var offset := _out.size()
		_out.resize(offset + 4)
		_out.encode_u32(offset, payload.size())
		_out.append_array(payload)
		_flush()


func _flush() -> void:
	if _out.is_empty() or closed:
		return
	var result := tcp.put_partial_data(_out)
	if result[0] != OK:
		closed = true
	elif result[1] > 0:
		_out = _out.slice(result[1])


func close(reason := "") -> void:
	closing = true
	deadline = Time.get_ticks_msec() + 1000
	if ws:
		ws.close(1000, reason.left(30))
	elif _out.is_empty():
		closed = true


func dispose() -> void:
	if ws and ws.get_ready_state() != WebSocketPeer.STATE_CLOSED:
		ws.close(-1)
	if tcp:
		tcp.disconnect_from_host()
