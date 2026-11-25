extends MultiplayerPeerExtension
## Server-side MultiplayerPeer adapter beneath SceneMultiplayer.
##
## Wraps the dedicated server's WebSocketMultiplayerPeer so Open Protocol
## Full-tier clients appear to SceneMultiplayer and all game scripts as
## ordinary multiplayer peers with real peer IDs, connect/disconnect signals,
## roster entries, lobby voting, runs, and late join. Normal Godot WebSocket
## clients pass straight through to the inner WebSocketMultiplayerPeer untouched.

const Codec := preload("res://game/open_protocol/scene_packet_codec.gd")
const VariantJson := preload("res://game/open_protocol/variant_json.gd")

const OPEN_PROTOCOL_VERSION := 1
const MAX_PACKET_SIZE := 65536
const MAX_FULL_PEERS := 12
const MAX_DRAINING_CONNS := 32
const JOIN_DEADLINE_MS := 10000


class FullClient:
	var peer_id: int
	var conn: RefCounted  # game/open_protocol_wire.gd
	var encoding: String
	var join_deadline: int = 0
	## Server SceneCacheInterface cache_id -> relative node path (for this peer).
	var server_cache: Dictionary = {}


static var _active: WeakRef

var _ws: WebSocketMultiplayerPeer
var _ws_peers: Dictionary = {}  # peer_id -> true
var _full_peers: Dictionary = {}  # peer_id -> FullClient
var _draining_conns: Array = []  # closed connections still flushing
var _full_inbox: Array[Dictionary] = []  # {"peer": int, "channel": int, "mode": int, "data": PackedByteArray}
var _target_peer: int = MultiplayerPeer.TARGET_PEER_BROADCAST
var _transfer_channel: int = 0
var _transfer_mode: MultiplayerPeer.TransferMode = MultiplayerPeer.TRANSFER_MODE_RELIABLE
var _refuse: bool = false
var _closed: bool = false


func _init(ws_peer: WebSocketMultiplayerPeer = null) -> void:
	_ws = ws_peer
	if _ws != null:
		_ws.peer_connected.connect(_on_ws_peer_connected)
		_ws.peer_disconnected.connect(_on_ws_peer_disconnected)
		_active = weakref(self)


static func get_active() -> MultiplayerPeerExtension:
	if _active == null:
		return null
	var inst: Variant = _active.get_ref()
	if inst is MultiplayerPeerExtension and not inst._closed:
		return inst
	return null


func _on_ws_peer_connected(id: int) -> void:
	_ws_peers[id] = true
	peer_connected.emit(id)


func _on_ws_peer_disconnected(id: int) -> void:
	_ws_peers.erase(id)
	peer_disconnected.emit(id)


## Admit an Open Protocol connection (after hello validation) as a real peer.
func add_full_peer(conn: RefCounted, _hello: Dictionary) -> int:
	if _closed or _refuse:
		conn.send_message({"t": "error", "msg": "Server is not accepting connections"})
		conn.close("refused")
		_enqueue_drain(conn)
		return 0
	if _full_peers.size() >= MAX_FULL_PEERS:
		conn.send_message({"t": "error", "msg": "Too many Open Protocol connections"})
		conn.close("full")
		_enqueue_drain(conn)
		return 0
	var peer_id := _allocate_peer_id()
	var client := FullClient.new()
	client.peer_id = peer_id
	client.conn = conn
	client.encoding = str(conn.encoding)
	client.join_deadline = Time.get_ticks_msec() + JOIN_DEADLINE_MS
	_full_peers[peer_id] = client
	conn.send_message({
		"t": "welcome",
		"v": OPEN_PROTOCOL_VERSION,
		"tier": "full",
		"enc": client.encoding,
		"you": peer_id,
		"game_protocol": Net.PROTOCOL,
		"maps": _available_maps(),
	})
	peer_connected.emit(peer_id)
	return peer_id


func _enqueue_drain(conn: RefCounted) -> void:
	if conn.closed or _draining_conns.size() >= MAX_DRAINING_CONNS:
		conn.dispose()
	else:
		_draining_conns.append(conn)


func active_peer_count() -> int:
	return _full_peers.size()


func _allocate_peer_id() -> int:
	var id := int(generate_unique_id())
	while id <= 1 or _ws_peers.has(id) or _full_peers.has(id) or Net.roster.has(id):
		id = int(generate_unique_id())
	return id


func _available_maps() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for m: Dictionary in Maps.available():
		if not m.get("dev_only", false):
			out.append({"id": m.id, "name": m.name})
	return out


func is_peer_open(peer_id: int) -> bool:
	if _full_peers.has(peer_id):
		var client: FullClient = _full_peers[peer_id]
		if client.conn.closed or client.conn.closing:
			return false
		if client.conn.ws != null:
			return client.conn.ws.get_ready_state() == WebSocketPeer.STATE_OPEN
		return true
	if _ws != null and _ws_peers.has(peer_id):
		var ws: WebSocketPeer = _ws.get_peer(peer_id)
		return ws != null and ws.get_ready_state() == WebSocketPeer.STATE_OPEN
	return false


func has_full_peer(peer_id: int) -> bool:
	return _full_peers.has(peer_id)


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


# ------------------------------------------------------------------ MultiplayerPeerExtension
func _poll() -> void:
	if _closed:
		return
	if _ws != null:
		_ws.poll()
	for conn in _draining_conns.duplicate():
		conn.poll()
		if conn.closed:
			conn.dispose()
			_draining_conns.erase(conn)
	var tree := _tree()
	var now := Time.get_ticks_msec()
	for peer_id: int in _full_peers.keys():
		var client: FullClient = _full_peers.get(peer_id)
		if client == null:
			continue
		if client.join_deadline > 0:
			if Net.roster.has(peer_id):
				client.join_deadline = 0
			elif now >= client.join_deadline:
				_disconnect_full_peer(peer_id, "join timeout")
				continue
		var packets: Array = client.conn.poll()
		if client.conn.closed:
			_remove_full_peer(peer_id, false)
			continue
		for pkt: Dictionary in packets:
			_handle_client_packet(client, pkt, tree)
			if not _full_peers.has(peer_id) or client.conn.closing or client.conn.closed:
				break


func _handle_client_packet(client: FullClient, pkt: Dictionary, tree: SceneTree) -> void:
	if pkt.get("text", false):
		var raw_text: String = (pkt["data"] as PackedByteArray).get_string_from_utf8()
		var parsed: Variant = JSON.parse_string(raw_text)
		if not parsed is Dictionary or not parsed.get("t") is String:
			client.conn.send_message({"t": "error", "msg": "Expected JSON object with string 't'"})
			return
		var msg: Dictionary = parsed
		match msg["t"]:
			"ping":
				var ms: Variant = msg.get("ms")
				if ms is float and is_finite(ms) and floor(ms) == ms:
					ms = int(ms)
				client.conn.send_message({"t": "pong", "ms": ms})
			"leave":
				_disconnect_full_peer(client.peer_id, "left")
			"rpc":
				_ingest_json_rpc(client, msg, tree)
			"raw":
				_ingest_json_raw(client, msg)
			_:
				client.conn.send_message({"t": "error", "msg": "Unknown message type '%s'" % str(msg["t"])})
	else:
		if client.encoding != "bin":
			client.conn.send_message({"t": "error", "msg": "Binary frame received while encoding is 'json'"})
			return
		var dec := Codec.decode_full_bin(pkt["data"], tree)
		if not dec.ok:
			client.conn.send_message({"t": "error", "msg": str(dec.error)})
			return
		match dec["t"]:
			"rpc":
				_enqueue_rpc_from_client(client, dec["node"], dec["method"], dec["args"],
					int(dec["ch"]), int(dec["mode"]), tree)
			"raw":
				_full_inbox.append({
					"peer": client.peer_id,
					"channel": int(dec["ch"]),
					"mode": int(dec["mode"]),
					"data": Codec.encode_raw(dec["data"]),
				})


func _ingest_json_rpc(client: FullClient, msg: Dictionary, tree: SceneTree) -> void:
	var node_val: Variant = msg.get("node")
	var method_val: Variant = msg.get("method")
	var args_val: Variant = msg.get("args", [])
	if not node_val is String or not method_val is String or not args_val is Array:
		client.conn.send_message({"t": "error", "msg": "Invalid rpc fields (expected node:String, method:String, args:Array)"})
		return
	var norm_path := Codec.normalize_rel_path(node_val)
	var node := tree.root.get_node_or_null(norm_path) if tree and tree.root else null
	if node == null:
		# Benign during scene transitions (e.g. in-flight transform right after run unload).
		return
	var hints := Codec.get_method_arg_types(node, method_val)
	var raw_args: Array = args_val
	var args := []
	for i in raw_args.size():
		var hint: int = hints[i] if i < hints.size() else TYPE_NIL
		args.append(VariantJson.from_json(raw_args[i], hint))
	var ch := ThinClientInput.integer(msg.get("ch"), 0, 255, -1)
	var mode: int = -1
	if msg.get("rel") is bool:
		mode = MultiplayerPeer.TRANSFER_MODE_RELIABLE if msg["rel"] else MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED
	_enqueue_rpc_from_client(client, norm_path, method_val, args, ch, mode, tree)


func _ingest_json_raw(client: FullClient, msg: Dictionary) -> void:
	var b64: Variant = msg.get("data")
	if not b64 is String:
		client.conn.send_message({"t": "error", "msg": "Invalid raw message (expected base64 'data')"})
		return
	var raw := Marshalls.base64_to_raw(b64)
	if raw.is_empty():
		return
	var ch := ThinClientInput.integer(msg.get("ch"), 0, 255, 0)
	var reliable: Variant = msg.get("rel", true)
	var mode := MultiplayerPeer.TRANSFER_MODE_UNRELIABLE if reliable is bool and not reliable else MultiplayerPeer.TRANSFER_MODE_RELIABLE
	_full_inbox.append({
		"peer": client.peer_id,
		"channel": ch,
		"mode": mode,
		"data": Codec.encode_raw(raw),
	})


func _enqueue_rpc_from_client(client: FullClient, node_path: String, method_name: String,
		args: Array, channel: int, mode: int, tree: SceneTree) -> void:
	var enc := Codec.encode_rpc(tree, node_path, method_name, args, -1)
	if not enc.ok:
		if not bool(enc.get("node_missing", false)):
			client.conn.send_message({"t": "error", "msg": str(enc.error)})
		return
	_full_inbox.append({
		"peer": client.peer_id,
		"channel": channel if channel >= 0 else int(enc.channel),
		"mode": mode if mode >= 0 else int(enc.transfer_mode),
		"data": enc.packet,
	})


func _get_available_packet_count() -> int:
	return _full_inbox.size() + (_ws.get_available_packet_count() if _ws != null else 0)


func _get_max_packet_size() -> int:
	return maxi(MAX_PACKET_SIZE, _ws.get_max_packet_size() if _ws != null else MAX_PACKET_SIZE)


func _get_packet_peer() -> int:
	if not _full_inbox.is_empty():
		return int(_full_inbox[0]["peer"])
	return _ws.get_packet_peer() if _ws != null else 0


func _get_packet_channel() -> int:
	if not _full_inbox.is_empty():
		return int(_full_inbox[0]["channel"])
	return _ws.get_packet_channel() if _ws != null else 0


func _get_packet_mode() -> MultiplayerPeer.TransferMode:
	if not _full_inbox.is_empty():
		return int(_full_inbox[0]["mode"]) as MultiplayerPeer.TransferMode
	return _ws.get_packet_mode() if _ws != null else MultiplayerPeer.TRANSFER_MODE_RELIABLE


func _get_packet_script() -> PackedByteArray:
	if not _full_inbox.is_empty():
		var pkt: Dictionary = _full_inbox.pop_front()
		return pkt["data"]
	return _ws.get_packet() if _ws != null else PackedByteArray()


func _put_packet_script(p_buffer: PackedByteArray) -> Error:
	if _closed:
		return ERR_UNCONFIGURED
	if _target_peer > 0:
		if _full_peers.has(_target_peer):
			return _send_to_full(_full_peers[_target_peer], p_buffer)
		if _ws != null:
			_ws.set_transfer_channel(_transfer_channel)
			_ws.set_transfer_mode(_transfer_mode)
			_ws.set_target_peer(_target_peer)
			return _ws.put_packet(p_buffer)
		return ERR_DOES_NOT_EXIST
	var exclude := -_target_peer if _target_peer < 0 else 0
	for peer_id: int in _full_peers.keys():
		if peer_id != exclude:
			_send_to_full(_full_peers[peer_id], p_buffer)
	if _ws != null and not _ws_peers.is_empty():
		_ws.set_transfer_channel(_transfer_channel)
		_ws.set_transfer_mode(_transfer_mode)
		_ws.set_target_peer(_target_peer)
		_ws.put_packet(p_buffer)
	return OK


func _send_to_full(client: FullClient, p_buffer: PackedByteArray) -> Error:
	if client.conn.closed or client.conn.closing:
		return ERR_CONNECTION_ERROR
	var tree := _tree()
	var dec := Codec.decode_packet(p_buffer, tree, client.server_cache)
	if not dec.ok:
		push_warning("FullPeer: failed to decode server packet for peer %d: %s" % [client.peer_id, str(dec.error)])
		return OK
	match int(dec["cmd"]):
		Codec.CMD_SIMPLIFY_PATH:
			var cid: int = int(dec["cache_id"])
			client.server_cache[cid] = str(dec["path"])
			# Confirm path internally so the external client never sees Godot cache IDs.
			_full_inbox.append({
				"peer": client.peer_id,
				"channel": 0,
				"mode": MultiplayerPeer.TRANSFER_MODE_RELIABLE,
				"data": Codec.encode_confirm_path(cid, true),
			})
		Codec.CMD_CONFIRM_PATH:
			pass
		Codec.CMD_REMOTE_CALL:
			if client.encoding == "bin":
				var frame := Codec.encode_full_bin_rpc(
					str(dec["node"]), str(dec["method"]), dec["args"], _transfer_channel, int(_transfer_mode))
				client.conn.send_binary(frame)
			else:
				var json_args := []
				for arg: Variant in dec["args"]:
					json_args.append(VariantJson.to_json(arg))
				client.conn.send_message({
					"t": "rpc",
					"node": str(dec["node"]),
					"method": str(dec["method"]),
					"args": json_args,
					"ch": _transfer_channel,
					"rel": _transfer_mode == MultiplayerPeer.TRANSFER_MODE_RELIABLE,
				})
		Codec.CMD_RAW:
			if client.encoding == "bin":
				client.conn.send_binary(Codec.encode_full_bin_raw(dec["data"], _transfer_channel, int(_transfer_mode)))
			else:
				client.conn.send_message({
					"t": "raw",
					"data": Marshalls.raw_to_base64(dec["data"]),
					"ch": _transfer_channel,
					"rel": _transfer_mode == MultiplayerPeer.TRANSFER_MODE_RELIABLE,
				})
		_:
			push_warning("FullPeer: unsupported SceneMultiplayer cmd %d for peer %d" % [int(dec["cmd"]), client.peer_id])
	return OK


func _set_transfer_channel(p_channel: int) -> void:
	_transfer_channel = p_channel


func _get_transfer_channel() -> int:
	return _transfer_channel


func _set_transfer_mode(p_mode: MultiplayerPeer.TransferMode) -> void:
	_transfer_mode = p_mode


func _get_transfer_mode() -> MultiplayerPeer.TransferMode:
	return _transfer_mode


func _set_target_peer(p_peer: int) -> void:
	_target_peer = p_peer


func _is_server() -> bool:
	return true


func _get_unique_id() -> int:
	return 1


func _get_connection_status() -> MultiplayerPeer.ConnectionStatus:
	if _closed or _ws == null:
		return MultiplayerPeer.CONNECTION_DISCONNECTED
	return _ws.get_connection_status()


func _set_refuse_new_connections(p_enable: bool) -> void:
	_refuse = p_enable
	if _ws != null:
		_ws.refuse_new_connections = p_enable


func _is_refusing_new_connections() -> bool:
	return _refuse


func _is_server_relay_supported() -> bool:
	return false


func _disconnect_peer(p_peer: int, p_force: bool) -> void:
	if _full_peers.has(p_peer):
		if p_force:
			_remove_full_peer(p_peer, true)
		else:
			_disconnect_full_peer(p_peer, "disconnected")
	elif _ws != null:
		_ws.disconnect_peer(p_peer, p_force)


func _disconnect_full_peer(peer_id: int, reason: String) -> void:
	var client: FullClient = _full_peers.get(peer_id)
	if client == null:
		return
	_full_peers.erase(peer_id)
	_purge_inbox(peer_id)
	client.conn.close(reason)
	_enqueue_drain(client.conn)
	peer_disconnected.emit(peer_id)


func _remove_full_peer(peer_id: int, dispose_now: bool) -> void:
	var client: FullClient = _full_peers.get(peer_id)
	if client == null:
		return
	_full_peers.erase(peer_id)
	_purge_inbox(peer_id)
	if dispose_now or client.conn.closed:
		client.conn.dispose()
	else:
		client.conn.close()
		_enqueue_drain(client.conn)
	peer_disconnected.emit(peer_id)


func _purge_inbox(peer_id: int) -> void:
	var kept: Array[Dictionary] = []
	for pkt: Dictionary in _full_inbox:
		if int(pkt["peer"]) != peer_id:
			kept.append(pkt)
	_full_inbox = kept


func _close() -> void:
	if _closed:
		return
	_closed = true
	if _active != null and _active.get_ref() == self:
		_active = null
	for peer_id: int in _full_peers.keys():
		var client: FullClient = _full_peers[peer_id]
		client.conn.dispose()
	_full_peers.clear()
	for conn in _draining_conns:
		conn.dispose()
	_draining_conns.clear()
	_full_inbox.clear()
	_ws_peers.clear()
	if _ws != null:
		_ws.close()
