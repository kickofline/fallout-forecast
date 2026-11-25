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
const WS_HEARTBEAT_SECONDS := 20.0

var encoding := "json"
var peer_address: String
var ws: WebSocketPeer
var tcp: StreamPeerTCP
var deadline := 0
var closed := false
var closing := false
var label := "pending"
var _disconnect_reason := ""
var _disposed := false
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
		ws.heartbeat_interval = WS_HEARTBEAT_SECONDS
		if ws.accept_stream(stream) != OK:
			_end("WebSocket accept failed")
	else:
		tcp = stream


func poll(limit := MAX_BATCH) -> Array[Dictionary]:
	var packets: Array[Dictionary] = []
	if closed:
		return packets
	if ws:
		var was_connecting := ws.get_ready_state() == WebSocketPeer.STATE_CONNECTING
		ws.poll()
		var state := ws.get_ready_state()
		if state == WebSocketPeer.STATE_CLOSED:
			_end("WebSocket upgrade failed" if was_connecting else _websocket_close_reason())
			return packets
		if state == WebSocketPeer.STATE_CLOSING and not closing:
			_disconnect_reason = _websocket_close_reason()
			closing = true
			deadline = Time.get_ticks_msec() + 1000
		elif state == WebSocketPeer.STATE_OPEN:
			for _i in mini(ws.get_available_packet_count(), limit):
				var data := ws.get_packet()
				if data.size() > MULTIPLEXED_FRAME_LIMIT:
					close("message too large", "Client message exceeds 65536 bytes", 1009)
					return []
				packets.append({"data": data, "text": ws.was_string_packet()})
	else:
		tcp.poll()
		var status := tcp.get_status()
		if status != StreamPeerTCP.STATUS_CONNECTED:
			_end("TCP connection error" if status == StreamPeerTCP.STATUS_ERROR else "TCP peer closed")
			return packets
		var available := tcp.get_available_bytes()
		if available > 0:
			var read: Array = tcp.get_partial_data(mini(available, MULTIPLEXED_FRAME_LIMIT))
			if read[0] != OK:
				_end("TCP read failed: %s" % error_string(read[0]))
				return []
			_in.append_array(read[1])
		var offset := 0
		while _in.size() - offset >= 4 and packets.size() < limit:
			var length := _in.decode_u32(offset)
			if length == 0 or length > MULTIPLEXED_FRAME_LIMIT:
				close("invalid frame length", "Client message length must be 1 to 65536 bytes")
				return []
			if _in.size() - offset - 4 < length:
				break
			var data := _in.slice(offset + 4, offset + 4 + length)
			packets.append({"data": data, "text": data[0] >= 0x09})
			offset += 4 + length
		if offset:
			_in = _in.slice(offset)
		if _in.size() > 2 * MULTIPLEXED_FRAME_LIMIT:
			close("inbound buffer overflow", "Too much unprocessed input")
		_flush()
		if closing and _out.is_empty():
			_end("close flushed")
	if deadline and Time.get_ticks_msec() >= deadline:
		if closing:
			_end("close flush timeout")
		else:
			close("hello timeout", "Open Protocol hello timed out", 1008)
		return []
	return packets


func send_message(message: Dictionary) -> void:
	_send(strict_json(JSON.stringify(message, "", false)).to_utf8_buffer(), true)


## Skip generating a snapshot while a previous frame is still buffered by
## this transport. The next attempt samples current state once writes drain.
func can_send_snapshot() -> bool:
	return not closed and not closing and _buffered_bytes() == 0 and (
		not ws or ws.get_ready_state() == WebSocketPeer.STATE_OPEN)


func send_snapshot(frame: Variant) -> void:
	if not can_send_snapshot():
		return
	var text := frame is Dictionary
	var payload: PackedByteArray = strict_json(JSON.stringify(frame, "", false)).to_utf8_buffer() if text else frame
	if _can_buffer(payload):
		_write(payload, text)


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
	if not _can_buffer(payload):
		close("outbound buffer overflow", "Server outbound buffer overflow", 1011)
		return
	_write(payload, text)


func _buffered_bytes() -> int:
	return ws.get_current_outbound_buffered_amount() if ws else _out.size()


func _can_buffer(payload: PackedByteArray) -> bool:
	return _buffered_bytes() + payload.size() + (0 if ws else 4) <= OUT_LIMIT


func _write(payload: PackedByteArray, text: bool) -> void:
	if ws:
		if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
			var mode := WebSocketPeer.WRITE_MODE_TEXT if text else WebSocketPeer.WRITE_MODE_BINARY
			var err := ws.send(payload, mode)
			if err == ERR_OUT_OF_MEMORY:
				close("outbound buffer overflow", "", 1011)
			elif err != OK:
				_end("WebSocket write failed: %s" % error_string(err))
	else:
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
		_end("TCP write failed: %s" % error_string(result[0]))
	elif result[1] > 0:
		_out = _out.slice(result[1])


func close(reason: String, message := "", code := 1000) -> void:
	if closed or closing:
		return
	_disconnect_reason = reason if message.is_empty() else "%s: %s" % [reason, message]
	closing = true
	deadline = Time.get_ticks_msec() + 1000
	if not message.is_empty():
		var payload := strict_json(JSON.stringify({"t": "error", "msg": message})).to_utf8_buffer()
		if _can_buffer(payload):
			_write(payload, true)
	if ws:
		ws.close(code, reason)
	elif _out.is_empty():
		_end("close flushed")


func _websocket_close_reason() -> String:
	var code := ws.get_close_code()
	if code == -1:
		# Godot reports both missed WebSocket pongs and transport loss as -1.
		return "WebSocket closed without a close frame (transport loss or heartbeat timeout)"
	return "WebSocket close code %d, reason %s" % [
		code, strict_json(JSON.stringify(ws.get_close_reason()))]


func _end(reason: String) -> void:
	if _disconnect_reason.is_empty():
		_disconnect_reason = reason
	closed = true


func dispose(reason := "server shutdown") -> void:
	if _disposed:
		return
	_disposed = true
	_end(reason)
	print("[open-protocol] %s %s %s disconnected: %s" % [
		label, "ws" if ws else "tcp", peer_address, _disconnect_reason])
	if ws and ws.get_ready_state() != WebSocketPeer.STATE_CLOSED:
		ws.close(-1)
	if tcp:
		tcp.disconnect_from_host()
