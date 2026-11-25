extends Node
## Common Open Protocol listener and the authoritative Thin tier.

const Wire := preload("res://game/open_protocol_wire.gd")
const Binary := preload("res://game/thin_client_binary.gd")
const Feed := preload("res://game/thin_client_feed.gd")
const MapOutline := preload("res://game/thin_client_map.gd")
const FULL_TIER_PATH := "res://game/open_protocol/full_tier.gd"
const VERSION := 1
## Established Open Protocol connections: Thin sessions plus Full peers.
const MAX_CONNECTIONS := 12
## Connections that have not sent a valid hello yet. Kept apart from
## MAX_CONNECTIONS so idle sockets can't lock out clients that do say hello.
const MAX_PENDING := 16
const MAX_PENDING_PER_ADDRESS := 3
## Refused connections are dropped without a handshake, so many can be cleared
## per frame; that keeps a reconnect flood from starving the OS accept backlog.
const MAX_TAKES_PER_FRAME := 128
const MAX_ADMITS_PER_FRAME := 4
## Wrong join codes from one address before it is refused for a cooldown.
## The cooldown doubles on each repeat, up to COOLDOWN_MAX_MS.
const FAIL_LIMIT := 5
const FAIL_WINDOW_MS := 60000
const COOLDOWN_MS := 60000
const COOLDOWN_MAX_MS := 3600000
## Wrong join codes per minute across every address (covers clients that all
## arrive from one trusted proxy address). Past this, codes are not checked.
const GLOBAL_FAILS_PER_MINUTE := 30


class Session:
	var wire: Wire
	var input: ThinClientInput
	var state := ""
	var rate := 20
	var radius := 0.0
	var max_enemies := -1
	var next_snap := 0
	var tick := 0
	var last_lobby := {}
	var feed: Feed
	var draft_open := false


var _websocket := TCPServer.new()
var _raw := TCPServer.new()
var _join_code := ""
## Addresses or CIDR subnets exempt from per-address limits, e.g. a TLS proxy
## (or its Docker bridge subnet) in front of the WebSocket port.
var _trusted_proxies: Array[Dictionary] = []
var _failures := {}  # address -> {"count", "first", "until", "strikes"}
var _global_fails: Array[int] = []
var _sessions: Array[Session] = []
var _by_id: Dictionary = {}
var _next_id := 2
var _maps: Array[Dictionary] = []
var _map_cache := {}
var _downs := {}


func listen(ws_port: int, tcp_port: int, join_code: String,
		trusted_proxies := PackedStringArray()) -> Error:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_join_code = join_code
	_trusted_proxies = parse_trusted_proxies(trusted_proxies)
	if ws_port > 0:
		var err := _websocket.listen(ws_port)
		if err != OK:
			return err
	if tcp_port > 0:
		var err := _raw.listen(tcp_port)
		if err != OK:
			_websocket.stop()
			return err
	for map in Maps.available():
		if not map.get("dev_only", false):
			_maps.append({"id": map.id, "name": map.name})
	Net.roster_changed.connect(_broadcast_lobby)
	Net.chat_received.connect(func(_who: String, _message: String): _broadcast_lobby())
	Net.run_started.connect(_start_run)
	GameManager.run_finished.connect(_on_results)
	GameManager.banner.connect(func(message: String, _color: Color, _seconds: float):
		_record_event({"e": "banner", "text": message}))
	GameManager.mutations.cards_dealt.connect(_on_draft)
	GameManager.mutations.draft_resolved.connect(func(_index: int):
		for session: Session in _by_id.values():
			if session.draft_open:
				session.draft_open = false
				session.wire.send_message({"t": "draft_done"}))
	GameManager.tape_choice_changed.connect(_on_tape)
	WeatherManager.lightning_struck.connect(_on_lightning)
	WeatherManager.ambient_lightning_struck.connect(_on_lightning)
	return OK


func _process(_delta: float) -> void:
	_accept(_websocket, true)
	_accept(_raw, false)
	var now := Time.get_ticks_msec()
	for session: Session in _sessions.duplicate():
		var packets := session.wire.poll(1 if session.state.is_empty() else Wire.MAX_BATCH)
		if session.wire.closed:
			_dispose(session)
			continue
		for packet in packets:
			_receive(session, packet)
			if session.wire.closing or session not in _sessions:
				break
		if session not in _sessions or session.wire.closing or not session.input:
			continue
		if session.state == "loading":
			_check_player(session)
		if session.state == "run" and now >= session.next_snap:
			_snapshot(session, now)


func _accept(listener: TCPServer, websocket: bool) -> void:
	var admitted := 0
	for _i in MAX_TAKES_PER_FRAME:
		if admitted >= MAX_ADMITS_PER_FRAME or not listener.is_connection_available():
			return
		var stream := listener.take_connection()
		var address := stream.get_connected_host()
		if _pending_count() >= MAX_PENDING or _blocked(address) or (
				_per_address(address) and _pending_count(address) >= MAX_PENDING_PER_ADDRESS):
			stream.disconnect_from_host()
			continue
		admitted += 1
		var session := Session.new()
		session.wire = Wire.new(stream, websocket)
		_sessions.append(session)


func _pending_count(address := "") -> int:
	var count := 0
	for session: Session in _sessions:
		if session.state.is_empty() and (address.is_empty() or session.wire.peer_address == address):
			count += 1
	return count


func _established_count() -> int:
	return _sessions.size() - _pending_count() + _full_peer_count()


func _full_peer_count() -> int:
	if multiplayer.has_multiplayer_peer() and multiplayer.multiplayer_peer.has_method("active_peer_count"):
		return int(multiplayer.multiplayer_peer.active_peer_count())
	return 0


func input_for(id: int) -> ThinClientInput:
	var session: Session = _by_id.get(id)
	return session.input if session else null


func _receive(session: Session, packet: Dictionary) -> void:
	var message: Variant
	if packet.text:
		message = JSON.parse_string(packet.data.get_string_from_utf8())
	elif session.wire.encoding == "bin" and session.input:
		message = Binary.input(packet.data)
	if not message is Dictionary or not message.get("t") is String:
		_fail(session, "Expected an Open Protocol message")
		return
	if session.state.is_empty():
		_hello(session, message)
		return
	match message.t:
		"ping":
			session.wire.send_message({"t": "pong", "ms": message.get("ms")})
		"leave":
			_status(session, "disconnected", "Left session")
			_release_player(session)
			session.wire.close()
		"lobby":
			if session.state in ["lobby", "results"]:
				_lobby_action(session.input.id, message)
		"in":
			if session.state == "run":
				if session.wire.encoding != "bin" or ThinClientInput.integer(message.get("seq"), 0, Binary.NO_ACK - 1, -1) >= 0:
					session.input.enqueue(message)
		"choice":
			if session.state == "run":
				_choose(session.input.id, message)
		"map_req":
			_send_map(session)


func _hello(session: Session, message: Dictionary) -> void:
	if message.t != "hello" or ThinClientInput.integer(message.get("v"), 1, 1, 0) != VERSION:
		_fail(session, "Expected hello with Open Protocol v%d" % VERSION)
		return
	if not _join_code.is_empty():
		var address := session.wire.peer_address
		if _blocked(address) or _recent_global_fails() >= GLOBAL_FAILS_PER_MINUTE:
			_fail(session, "Too many join attempts, try again later")
			return
		if not _code_matches(message.get("code")):
			_record_failure(address)
			_fail(session, "Invalid join code")
			return
		_failures.erase(address)
	var enc: Variant = message.get("enc", "json")
	if enc not in ["json", "bin"]:
		_fail(session, "Unsupported encoding")
		return
	if _established_count() >= MAX_CONNECTIONS:
		_fail(session, "Too many Open Protocol connections")
		return
	session.wire.encoding = enc
	session.wire.deadline = 0
	match message.get("tier", "thin"):
		"full":
			if ResourceLoader.exists(FULL_TIER_PATH):
				_sessions.erase(session)
				var tier = load(FULL_TIER_PATH)
				tier.accept(session.wire, message)
			else:
				_fail(session, "full tier unavailable")
			return
		"thin":
			pass
		_:
			_fail(session, "Unsupported tier")
			return
	if Net.roster.size() >= Net.MAX_PLAYERS:
		_fail(session, "SERVER FULL")
		return
	var name_value: Variant = message.get("name")
	var callsign := Net.clean_name(name_value)
	while Net.roster.has(_next_id) or _next_id in multiplayer.get_peers():
		_next_id += 1
	var id := _next_id
	_next_id += 1
	session.rate = ThinClientInput.integer(message.get("rate"), 2, 20, 20)
	var radius: Variant = message.get("radius")
	session.radius = clampf(radius, 1, 500) if ThinClientInput.number(radius) and radius > 0 else 0.0
	session.max_enemies = ThinClientInput.integer(message.get("max_enemies"), 0, 256, -1)
	session.input = ThinClientInput.new(id)
	_by_id[id] = session
	Net.add_thin_player(id, "THIN PLAYER" if callsign.is_empty() else callsign)
	session.wire.send_message({"t": "welcome", "v": VERSION, "game_protocol": Net.PROTOCOL, "you": id,
		"maps": _maps, "tier": "thin", "enc": enc, "rate": session.rate,
		"radius": session.radius, "max_enemies": session.max_enemies})
	_status(session, "lobby")
	_send_lobby(session)
	if Net.run_active:
		_load_run(session)


# ------------------------------------------------------------------ join code limits
## Constant-time comparison of a hello code with the server's join code.
func _code_matches(value: Variant) -> bool:
	if not value is String:
		return false
	var given := (value as String).sha256_buffer()
	var expected := _join_code.sha256_buffer()
	var diff := 0
	for i in expected.size():
		diff |= given[i] ^ expected[i]
	return diff == 0


func _per_address(address: String) -> bool:
	return not address.is_empty() and not is_trusted_proxy(address, _trusted_proxies)


## Parse comma-split IP addresses and IPv4/IPv6 CIDR ranges (e.g. "10.0.2.0/24",
## "127.0.0.1", "fd00::/8"). Invalid entries are logged and ignored.
static func parse_trusted_proxies(entries: PackedStringArray) -> Array[Dictionary]:
	var rules: Array[Dictionary] = []
	for entry in entries:
		var rule := _parse_trusted_proxy(entry)
		if rule.is_empty():
			print("[open-protocol] WARNING ignoring invalid trusted proxy entry: %s" % entry)
		else:
			rules.append(rule)
	return rules


static func is_trusted_proxy(address: String, rules: Array[Dictionary]) -> bool:
	if rules.is_empty() or address.is_empty():
		return false
	var addr_bytes := _normalize_ip(_parse_ip_raw(address))
	if addr_bytes.is_empty():
		return false
	for rule: Dictionary in rules:
		if _match_cidr(addr_bytes, rule):
			return true
	return false


static func _parse_trusted_proxy(entry: String) -> Dictionary:
	var trimmed := entry.strip_edges()
	if trimmed.is_empty():
		return {}
	var slash := trimmed.find("/")
	if slash != -1:
		if trimmed.find("/", slash + 1) != -1:
			return {}
		var ip_part := trimmed.left(slash)
		var prefix_part := trimmed.substr(slash + 1)
		if not _is_ascii_digits(prefix_part):
			return {}
		var raw := _parse_ip_raw(ip_part)
		if raw.is_empty():
			return {}
		var prefix := prefix_part.to_int()
		if prefix < 0 or prefix > raw.size() * 8:
			return {}
		if raw.size() == 16 and _is_ipv4_mapped(raw) and prefix >= 96:
			raw = raw.slice(12, 16)
			prefix -= 96
		return {"bytes": raw, "prefix": prefix, "raw": trimmed}
	var exact := _normalize_ip(_parse_ip_raw(trimmed))
	if exact.is_empty():
		return {}
	return {"bytes": exact, "prefix": exact.size() * 8, "raw": trimmed}


static func _match_cidr(addr_bytes: PackedByteArray, rule: Dictionary) -> bool:
	var rule_bytes: PackedByteArray = rule.bytes
	var prefix: int = int(rule.prefix)
	var candidate := addr_bytes
	if candidate.size() != rule_bytes.size():
		if candidate.size() == 4 and rule_bytes.size() == 16:
			candidate = _ipv4_to_mapped_v6(candidate)
		else:
			return false
	var full_bytes := prefix >> 3
	for i in full_bytes:
		if candidate[i] != rule_bytes[i]:
			return false
	var rem := prefix & 7
	if rem > 0:
		var mask := (0xFF << (8 - rem)) & 0xFF
		if (candidate[full_bytes] & mask) != (rule_bytes[full_bytes] & mask):
			return false
	return true


static func _is_ipv4_mapped(bytes: PackedByteArray) -> bool:
	if bytes.size() != 16:
		return false
	for i in 10:
		if bytes[i] != 0:
			return false
	return bytes[10] == 0xFF and bytes[11] == 0xFF


static func _normalize_ip(bytes: PackedByteArray) -> PackedByteArray:
	return bytes.slice(12, 16) if _is_ipv4_mapped(bytes) else bytes


static func _ipv4_to_mapped_v6(v4: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(16)
	out[10] = 0xFF
	out[11] = 0xFF
	for i in 4:
		out[12 + i] = v4[i]
	return out


static func _parse_ip_raw(text: String) -> PackedByteArray:
	var s := text.strip_edges()
	if s.begins_with("["):
		var close := s.find("]")
		if close == -1:
			return PackedByteArray()
		var tail := s.substr(close + 1)
		if not tail.is_empty() and not tail.begins_with("%"):
			return PackedByteArray()
		s = s.substr(1, close - 1)
	var zone := s.find("%")
	if zone != -1:
		s = s.left(zone)
	if s.is_empty():
		return PackedByteArray()
	if s.find(":") == -1:
		return _parse_ipv4(s)
	return _parse_ipv6(s)


static func _parse_ipv4(text: String) -> PackedByteArray:
	var parts := text.split(".", true)
	if parts.size() != 4:
		return PackedByteArray()
	var out := PackedByteArray()
	out.resize(4)
	for i in 4:
		if not _is_ascii_digits(parts[i]):
			return PackedByteArray()
		var v := parts[i].to_int()
		if v < 0 or v > 255:
			return PackedByteArray()
		out[i] = v
	return out


static func _parse_ipv6(text: String) -> PackedByteArray:
	var halves := text.split("::", true)
	if halves.size() > 2:
		return PackedByteArray()
	var left := _parse_ipv6_groups(halves[0], halves.size() == 1)
	if left.size() == 1 and left[0] == -1:
		return PackedByteArray()
	var groups := PackedInt32Array(left)
	if halves.size() == 2:
		var right := _parse_ipv6_groups(halves[1], true)
		if right.size() == 1 and right[0] == -1:
			return PackedByteArray()
		var missing := 8 - groups.size() - right.size()
		if missing <= 0:
			return PackedByteArray()
		for _i in missing:
			groups.append(0)
		groups.append_array(right)
	elif groups.size() != 8:
		return PackedByteArray()
	var out := PackedByteArray()
	out.resize(16)
	for i in 8:
		out[i * 2] = (groups[i] >> 8) & 0xFF
		out[i * 2 + 1] = groups[i] & 0xFF
	return out


static func _parse_ipv6_groups(part: String, allow_ipv4_tail: bool) -> PackedInt32Array:
	var groups := PackedInt32Array()
	if part.is_empty():
		return groups
	var tokens := part.split(":", true)
	for i in tokens.size():
		var tok := tokens[i]
		if tok.is_empty():
			return PackedInt32Array([-1])
		if tok.find(".") != -1:
			if not allow_ipv4_tail or i != tokens.size() - 1:
				return PackedInt32Array([-1])
			var v4 := _parse_ipv4(tok)
			if v4.is_empty():
				return PackedInt32Array([-1])
			groups.append((v4[0] << 8) | v4[1])
			groups.append((v4[2] << 8) | v4[3])
			continue
		var hex := _parse_hex16(tok)
		if hex < 0:
			return PackedInt32Array([-1])
		groups.append(hex)
	return groups


static func _is_ascii_digits(s: String) -> bool:
	if s.is_empty() or s.length() > 3:
		return false
	for i in s.length():
		var c := s.unicode_at(i)
		if c < 48 or c > 57:
			return false
	return true


static func _parse_hex16(s: String) -> int:
	if s.is_empty() or s.length() > 4:
		return -1
	var val := 0
	for i in s.length():
		var c := s.unicode_at(i)
		var d := -1
		if c >= 48 and c <= 57:
			d = c - 48
		elif c >= 65 and c <= 70:
			d = c - 55
		elif c >= 97 and c <= 102:
			d = c - 87
		else:
			return -1
		val = (val << 4) | d
	return val


func _blocked(address: String) -> bool:
	if not _per_address(address):
		return false
	var row: Dictionary = _failures.get(address, {})
	return not row.is_empty() and Time.get_ticks_msec() < int(row.until)


func _recent_global_fails() -> int:
	var cutoff := Time.get_ticks_msec() - 60000
	while not _global_fails.is_empty() and _global_fails[0] < cutoff:
		_global_fails.pop_front()
	return _global_fails.size()


func _record_failure(address: String) -> void:
	var now := Time.get_ticks_msec()
	_global_fails.append(now)
	print("[open-protocol] invalid join code from %s" % address)
	if not _per_address(address):
		return
	if _failures.size() > 4096:
		for key: String in _failures.keys():
			var old: Dictionary = _failures[key]
			if now >= int(old.until) and now - int(old.first) > FAIL_WINDOW_MS:
				_failures.erase(key)
	var row: Dictionary = _failures.get(address, {"count": 0, "first": now, "until": 0, "strikes": 0})
	if now - int(row.first) > FAIL_WINDOW_MS:
		row.count = 0
		row.first = now
	row.count = int(row.count) + 1
	if int(row.count) >= FAIL_LIMIT:
		row.strikes = int(row.strikes) + 1
		var cooldown := mini(COOLDOWN_MS << mini(int(row.strikes) - 1, 10), COOLDOWN_MAX_MS)
		row.until = now + cooldown
		row.count = 0
		row.first = now
		print("[open-protocol] %s refused for %d s after repeated invalid join codes" % [address, cooldown / 1000])
	_failures[address] = row


func _release_player(session: Session) -> void:
	if session.input:
		var id := session.input.id
		session.input.clear()
		session.input = null
		_by_id.erase(id)
		Net.remove_roster_peer(id)
		GameManager.remove_ready_peer(id)
		GameManager.mutations.remove_vote(id)
		_on_tape()


func _dispose(session: Session) -> void:
	_release_player(session)
	session.wire.dispose()
	_sessions.erase(session)


func _fail(session: Session, message: String) -> void:
	session.wire.send_message({"t": "error", "msg": message})
	_release_player(session)
	session.wire.close()


func _status(session: Session, state: String, msg := "") -> void:
	session.state = state
	session.wire.send_message({"t": "status", "state": state, "msg": msg})


func _lobby_action(id: int, message: Dictionary) -> void:
	match message.get("a"):
		"ready":
			if message.get("v") is bool:
				Net.set_ready_for_peer(id, message.v)
		"vote":
			if message.get("map") is String:
				Net.set_vote_for_peer(id, message.map)
		"start":
			Net.force_start_for_peer(id)
		"chat":
			if message.get("text") is String:
				Net.send_chat_for_peer(id, message.text)


func _broadcast_lobby() -> void:
	for session: Session in _by_id.values():
		_send_lobby(session)


func _send_lobby(session: Session) -> void:
	if session.state != "lobby":
		return
	var players := []
	for id: int in Net.roster:
		var info: Dictionary = Net.roster[id]
		players.append({"id": id, "name": info.name, "ready": info.ready,
			"vote": Net._map_votes.get(id, ""), "car": Net.is_thin_peer(id)})
	var chat := []
	for entry in Net.chat_log:
		chat.append({"from": entry[0], "text": entry[1]})
	var data := {"t": "lobby", "players": players, "maps": _maps,
		"countdown": -1, "chat": chat, "vote_counts": Net.lobby_vote_counts.duplicate()}
	if data != session.last_lobby:
		session.last_lobby = data
		session.wire.send_message(data)


func _start_run() -> void:
	_downs.clear()
	for session: Session in _by_id.values():
		_load_run(session)


func _load_run(session: Session) -> void:
	session.input.clear()
	session.feed = Feed.new(get_tree())
	session.feed.radius = session.radius
	session.feed.max_enemies = session.max_enemies
	session.next_snap = 0
	_status(session, "loading")
	session.wire.send_message({"t": "load", "map": Net.run_map_id})


func _check_player(session: Session) -> void:
	var player := GameManager.player_for_peer(session.input.id) as Player
	var loot := RunLoot.find(get_tree())
	if not GameManager.run_active or not player or not loot or loot.run_id == 0:
		return
	player.damaged.connect(session.feed.hurt)
	player.hurt_from.connect(session.feed.hurt_from.bind(player))
	loot.choose_thin_starter(session.input.id)
	_status(session, "run")
	if GameManager.mutations.is_voting():
		_send_draft(session, GameManager.mutations.cards)
	if GameManager.awaiting_tape_choice:
		_send_tape(session)


func _snapshot(session: Session, now: int) -> void:
	var player := GameManager.player_for_peer(session.input.id) as Player
	var loot := RunLoot.find(get_tree())
	if not player or not loot:
		return
	var interval := 1000.0 / session.rate
	session.next_snap = now + roundi(interval) if session.next_snap == 0 else (
		maxi(now + 1, session.next_snap + roundi(interval)))
	session.tick += 1
	var frame := session.feed.snapshot(player, loot, session.tick, session.input.ack, now)
	if session.wire.encoding == "bin":
		session.wire.send_binary(Binary.snapshot(frame))
	else:
		session.wire.send_message(frame)
	_flush_events(session)


func _send_map(session: Session) -> void:
	var id := Net.run_map_id if Net.run_active else ""
	if not _map_cache.has(id):
		var scene := get_tree().current_scene
		var level := scene.get_node_or_null("Level") as Node3D if scene else null
		if id.is_empty() or level == null:
			session.wire.send_message({"t": "map", "id": null, "boxes": [], "bounds": null})
			return
		_map_cache[id] = MapOutline.describe(level, id)
	session.wire.send_message(_map_cache[id])


func _on_draft(_enemy: String, cards: Array) -> void:
	for session: Session in _by_id.values():
		if session.state == "run":
			_send_draft(session, cards)


func _send_draft(session: Session, dealt: Array) -> void:
	var cards := []
	for id in dealt:
		var def: Dictionary = GameManager.PLAYER_MUTATIONS.get(id, {})
		cards.append({"id": id, "title": def.get("name"), "desc": def.get("desc"), "icon": id})
	session.draft_open = true
	session.wire.send_message({"t": "draft", "kind": "mutation", "cards": cards,
		"time_left": GameManager.mutations.time_left})


func _on_tape() -> void:
	if GameManager.awaiting_tape_choice:
		for session: Session in _by_id.values():
			if session.state == "run":
				_send_tape(session)


func _send_tape(session: Session) -> void:
	session.wire.send_message({"t": "tape", "time_left": null,
		"can_choose": session.input.id == GameManager.tape_decider()})


func _choose(id: int, message: Dictionary) -> void:
	var index := ThinClientInput.integer(message.get("i"), 0, 2, -1)
	match message.get("kind"):
		"mutation":
			GameManager.mutations.vote_for_peer(id, index)
		"tape":
			if index in [0, 1]:
				GameManager._apply_tape_choice(id, index == 0)


func _on_results(won: bool, results: Dictionary) -> void:
	var players := []
	var kills := 0
	for peer: int in results.players:
		var row: Dictionary = results.players[peer]
		players.append({"name": row.name, "kills": row.kills, "downs": _downs.get(peer, 0),
			"revives": row.revives})
		kills += int(row.kills)
	for session: Session in _by_id.values():
		_flush_events(session)
		session.input.clear()
		_status(session, "results")
		session.wire.send_message({"t": "results", "won": won, "time_s": results.seconds,
			"waves": results.waves, "kills": kills, "players": players, "score": results.endless_score})


func lobby_reset() -> void:
	for session: Session in _by_id.values():
		session.feed = null
		session.last_lobby = {}
		session.draft_open = false
		_status(session, "lobby")
		_send_lobby(session)


func ping(player: Player) -> void:
	var pings := get_tree().current_scene.get_node("Pings") as PingSystem
	if player.state == "downed":
		pings.send_for_peer(player.peer_id(), "revive", player.global_position)
	elif player.state == "ok":
		var row := pings.context_ping(player)
		pings.send_for_peer(player.peer_id(), row.kind, row.pos, row.enemy_id)


func _on_lightning(at: Vector3, _seed: int) -> void:
	for session: Session in _by_id.values():
		if session.feed:
			session.feed.lightning = true
	_record_event({"e": "lightning", "at": Feed.vec(at)})
	record_sound("thunder", at)


func record_shot(by: int, weapon: String, origin: Vector3, dir: Vector3, traces: Array) -> void:
	if _by_id.is_empty():
		return
	var muzzle := origin + dir * 0.55
	for trace: Array in traces:
		_record_event({"e": "shot", "by": by, "weapon": weapon, "from": Feed.vec(muzzle),
			"to": Feed.vec(trace[0])})
	var data := ItemCatalog.definition(weapon).weapon
	if not data.shot_sound.is_empty():
		record_sound(data.shot_sound, muzzle)


func record_hit(id: int, at: Vector3, amount: int, critical: bool) -> void:
	_record_event({"e": "hit", "at": Feed.vec(at), "head": critical, "dmg": amount}, id)


func record_down(id: int) -> void:
	_downs[id] = int(_downs.get(id, 0)) + 1


func record_kill(enemy: EnemyBase) -> void:
	_record_event({"e": "kill", "enemy": enemy.net_id, "type": Feed.enemy_type(enemy)})


func record_boss_kill() -> void:
	_record_event({"e": "kill", "enemy": 0, "type": "cumulus"})


func record_pickup(id: int, item: String) -> void:
	_record_event({"e": "pickup", "item": item}, id)
	_record_event({"e": "sound", "name": "pickup", "at": null}, id)


func record_sound(cue: String, at: Variant) -> void:
	if not _by_id.is_empty():
		_record_event({"e": "sound", "name": cue, "at": Feed.vec(at) if at is Vector3 else null})


func _record_event(row: Dictionary, only := 0) -> void:
	for peer: int in _by_id:
		if only == 0 or peer == only:
			var session: Session = _by_id[peer]
			if session.feed:
				session.feed.event(row)


func _flush_events(session: Session) -> void:
	if session.feed:
		var events := session.feed.take_events()
		if not events.is_empty():
			session.wire.send_message({"t": "ev", "list": events})
