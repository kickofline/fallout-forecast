extends Node
## Autoload "Net": the session and the lobby roster.
##
## One place answers "am I the host?". Every script used to carry its own copy
## of that check; now they all ask Net. Offline counts as host, exactly as
## before, so solo play runs the same code path as a hosted game.
##
## Transport is WebSocketMultiplayerPeer everywhere (so browser builds can
## play). Multiplayer is CLOUD PLAY only: the dedicated server listens for ws://
## on TCP PORT behind TLS termination at CLOUD_URL (wss://). There is no player
## hosting or LAN discovery any more. Topology is client/server.
## Clients can only talk to the host, never to each other, so every
## client-to-client message goes client -> host -> clients: see the
## "_push_* / _apply_*" pairs on Player and MutationRoll.

signal roster_changed
signal peer_joined(peer_id: int)
signal run_started
signal connection_failed
signal server_closed
signal joined_server

## The public dedicated server (server/README.md). Desktop and web builds both
## join it with join_cloud(); keep this URL stable, the web export uses it.
const CLOUD_URL := "wss://fallout.drew.place/"
const CLOUD_HOST := "fallout.drew.place"
## Bump whenever an rpc or the scene layout changes: a client and server on
## different builds are turned away with a message instead of desyncing.
const PROTOCOL := 19
## Give up on a join that hasn't connected after this long.
const CONNECT_TIMEOUT := 8.0

## WebSocket (TCP) port a host listens on; the cloud container uses it too.
const PORT := 7777
const MAX_PLAYERS := 4
const PING_INTERVAL := 1.0

enum Mode { OFFLINE, HOST, CLIENT }

var mode: Mode = Mode.OFFLINE
var local_name := ""
## peer id -> {"name": String, "ready": bool, "color": int, "skin": int}
## color / skin index Cosmetics.COLORS / SKINS; the host keeps colours unique.
var roster := {}
## Lobby choice can be RANDOM. The run id always names an actual level.
var lobby_map_id := Maps.DEFAULT_ID
var run_map_id := Maps.DEFAULT_ID
var lobby_votes_enabled := false
var lobby_vote_counts := {}
var lobby_my_vote := ""
## Host only. Remote peers get the counts and their own confirmed choice.
var _map_votes := {}
## True between the lobby's START and the results screen.
var run_active := false
## Headless dedicated server (`-- --server`): hosts with no local player, so
## peer 1 is never in the roster. See game/dedicated_server.gd.
var dedicated := false
## Optional transport belonging to the dedicated server.
var thin_server: Node
## Why the last join failed, for the join screen ("" = no answer).
var last_error := ""
## Host-measured smoothed RTT in milliseconds per connected client peer id.
var peer_rtt_ms := {}
## Client: most recent RTT reported back from the host (ms).
var local_rtt_ms := 0.0

var _connect_left := 0.0
var _host_port := PORT
var _ping_timer := 0.0
var _ping_seq := 0
var _ping_sent_ms := {}  # peer_id -> {"seq": int, "ms": int}


func _ready() -> void:
	# Clients only communicate with the server. In particular, it shouldn't
	# relay peer-disconnect packets to another socket that's already closing.
	(multiplayer as SceneMultiplayer).server_relay = false
	multiplayer.peer_connected.connect(_guard_thin_identity)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	if "--server" in OS.get_cmdline_user_args():
		dedicated = true
		var server := Node.new()
		server.name = "DedicatedServer"
		server.set_script(load("res://game/dedicated_server.gd"))
		add_child(server)


func _process(delta: float) -> void:
	if _connect_left > 0.0:
		_connect_left -= delta
		if _connect_left <= 0.0 and mode == Mode.CLIENT:
			last_error = "NO ANSWER"
			_on_connection_failed()
	if mode == Mode.HOST and is_online():
		_ping_timer -= delta
		if _ping_timer <= 0.0:
			_ping_timer = PING_INTERVAL
			_send_rtt_pings()


# ------------------------------------------------------------------ session
## Offline is the host of a game of one. Clients are the only non-hosts.
func is_host() -> bool:
	return mode != Mode.CLIENT


## A joined session, as opposed to solo. Guards every rpc that needs a peer.
func is_online() -> bool:
	return mode != Mode.OFFLINE and multiplayer.has_multiplayer_peer()


func is_offline() -> bool:
	return mode == Mode.OFFLINE


func local_id() -> int:
	return multiplayer.get_unique_id()


func peer_count() -> int:
	return maxi(roster.size(), 1)


## Only the dedicated server hosts (players use CLOUD PLAY). Browsers can't listen at all.
func can_host() -> bool:
	return not OS.has_feature("web")


## Open a session. Returns OK, or an error the lobby can show.
## as_player = false is the dedicated server: no roster entry for peer 1.
func host(port := PORT, as_player := true, default_map := Maps.DEFAULT_ID) -> Error:
	leave()
	if not can_host():
		return ERR_UNAVAILABLE
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_server(port)
	if err != OK:
		return err
	var active_peer: MultiplayerPeer = peer
	if dedicated and ResourceLoader.exists("res://game/open_protocol/full_peer.gd"):
		active_peer = load("res://game/open_protocol/full_peer.gd").new(peer)
	multiplayer.multiplayer_peer = active_peer
	_host_port = port
	mode = Mode.HOST
	lobby_map_id = Maps.fallback(default_map)
	lobby_votes_enabled = not as_player
	var custom := clean_name(Settings.player_name)
	local_name = (custom if custom != "" else "HOST") if as_player else "CLOUD SERVER"
	roster.clear()
	_allowed_colors.clear()
	if as_player:
		roster[1] = {"name": local_name, "ready": false}
		_allowed_colors[1] = Feats.unlocked_colors()
		_assign_cosmetic(1, Settings.suit_color, Settings.suit_skin)
	roster_changed.emit()
	return OK


## Join the public cloud server (CLOUD_URL). Same path on desktop and web.
func join_cloud() -> Error:
	return join(cloud_url())


## The server CLOUD PLAY uses: Settings' custom address, or the public one.
func cloud_url() -> String:
	var custom := Settings.server_url.strip_edges()
	return to_url(custom) if custom != "" else CLOUD_URL


## "192.168.1.20", "host:9000", "ws://..." or "wss://..." -> a WebSocket URL.
func to_url(address: String, port := PORT) -> String:
	var target := address.strip_edges()
	if target.begins_with("ws://") or target.begins_with("wss://"):
		return target
	var colon := target.rfind(":")
	if colon > 0 and target.count(":") == 1:
		return "ws://%s/" % target
	return "ws://%s:%d/" % [target, port]


## Join a session. connection_failed / joined_server arrive later, by signal.
## address is anything to_url() accepts.
func join(address: String, port := PORT) -> Error:
	leave()
	last_error = ""
	var url := to_url(address, port)
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_client(url)
	if err != OK:
		last_error = "BAD ADDRESS"
		return err
	# Set the mode before the peer, so the handshake's callbacks see CLIENT.
	mode = Mode.CLIENT
	roster.clear()
	multiplayer.multiplayer_peer = peer
	_connect_left = CONNECT_TIMEOUT
	return OK


## Drop the session. Safe to call when there isn't one.
func leave() -> void:
	chat_log.clear()
	mode = Mode.OFFLINE
	run_active = false
	lobby_map_id = Maps.DEFAULT_ID
	run_map_id = Maps.DEFAULT_ID
	lobby_votes_enabled = false
	lobby_vote_counts.clear()
	lobby_my_vote = ""
	_map_votes.clear()
	run_peers.clear()
	_reset_run_readiness()
	_connect_left = 0.0
	roster.clear()
	peer_rtt_ms.clear()
	_ping_sent_ms.clear()
	local_rtt_ms = 0.0
	# Mode is already OFFLINE, so the disconnects this triggers are ignored.
	# Back to Godot's default offline peer, not null: with no peer at all,
	# every is_multiplayer_authority() and rpc() in solo play errors.
	if not multiplayer.multiplayer_peer is OfflineMultiplayerPeer:
		if multiplayer.multiplayer_peer.has_method("is_peer_open"):
			multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	roster_changed.emit()


## Anyone can start the run without waiting for everyone to ready up. A player
## host starts it directly; a client asks the host, which starts it (the
## dedicated server listens for force_start_requested).
signal force_start_requested(by: String)


func force_start() -> void:
	if is_host():
		if dedicated:
			force_start_requested.emit(local_name)
		else:
			request_start()
	elif is_online():
		_request_force_start.rpc_id(1)


@rpc("any_peer", "call_remote", "reliable")
func _request_force_start() -> void:
	if not is_host() or run_active:
		return
	var peer := multiplayer.get_remote_sender_id()
	if not roster.has(peer):
		return
	force_start_for_peer(peer)


func force_start_for_peer(peer: int) -> void:
	if not is_host() or run_active or not roster.has(peer):
		return
	var who := str(roster[peer].get("name", "PLAYER"))
	if dedicated:
		force_start_requested.emit(who)
	else:
		request_start()


func set_ready(value: bool) -> void:
	if is_host():
		if roster.has(1):
			roster[1]["ready"] = value
		_broadcast_roster()
		roster_changed.emit()
	elif is_online():
		_request_ready.rpc_id(1, value)


func set_lobby_map(id: String) -> void:
	if not is_host() or not is_online() or run_active or lobby_votes_enabled:
		return
	if id == Maps.RANDOM_ID or Maps.is_available(id):
		lobby_map_id = id
		_broadcast_roster()
		roster_changed.emit()


func vote_for_map(id: String) -> void:
	if not is_host() and is_online() and lobby_votes_enabled and not run_active:
		_request_map_vote.rpc_id(1, id)


@rpc("any_peer", "call_remote", "reliable")
func _request_map_vote(id: String) -> void:
	if not is_host() or run_active or not lobby_votes_enabled:
		return
	var peer := multiplayer.get_remote_sender_id()
	set_vote_for_peer(peer, id)


func set_vote_for_peer(peer: int, id: String) -> void:
	if not is_host() or run_active or not lobby_votes_enabled or not roster.has(peer):
		return
	if id != Maps.RANDOM_ID and not Maps.is_available(id):
		return
	_map_votes[peer] = id
	_broadcast_roster()
	roster_changed.emit()


## Change our suit colour / skin. The host may hand back a different colour
## if someone already wears that one; the roster says what we really got.
func set_cosmetic(color: int, skin: int) -> void:
	if not is_online() or run_active:
		return
	if is_host():
		if roster.has(1):
			_allowed_colors[1] = Feats.unlocked_colors()
			_assign_cosmetic(1, color, skin)
			_broadcast_roster()
			roster_changed.emit()
	else:
		_request_cosmetic.rpc_id(1, color, skin, Feats.unlocked_colors())


# ------------------------------------------------------------------ lobby chat
## A line of lobby chat arrived (from anyone, including us via the host).
signal chat_received(sender: String, text: String)
const CHAT_MAX := 100
const CHAT_HISTORY := 30
## Recent lines, so someone opening the lobby sees the conversation.
var chat_log: Array = []  # [[sender, text], ...]
var _chat_last_ms := {}   # peer id -> last accepted message (host only)


## Send a chat line. Goes through the host, which cleans and rate-limits it.
func send_chat(text: String) -> void:
	var clean := _clean_chat(text)
	if clean == "" or not is_online():
		return
	if is_host():
		_accept_chat(1, local_name, clean)
	else:
		_request_chat.rpc_id(1, clean)


@rpc("any_peer", "call_remote", "reliable")
func _request_chat(text: String) -> void:
	if not is_host():
		return
	var peer := multiplayer.get_remote_sender_id()
	send_chat_for_peer(peer, text)


func send_chat_for_peer(peer: int, text: String) -> void:
	if is_host() and roster.has(peer):
		_accept_chat(peer, str(roster[peer].get("name", "PLAYER")), _clean_chat(text))


func _accept_chat(peer: int, sender: String, text: String) -> void:
	if text == "":
		return
	var now := Time.get_ticks_msec()
	if now - int(_chat_last_ms.get(peer, -10000)) < 700:
		return
	_chat_last_ms[peer] = now
	if dedicated:
		print("[chat] %s: %s" % [sender, text])
	rpc_to_all(_chat_rpc, [sender, text])
	_store_chat(sender, text)


@rpc("authority", "call_remote", "reliable")
func _chat_rpc(sender: String, text: String) -> void:
	_store_chat(sender, _clean_chat(text))


func _store_chat(sender: String, text: String) -> void:
	chat_log.append([sender, text])
	if chat_log.size() > CHAT_HISTORY:
		chat_log.pop_front()
	chat_received.emit(sender, text)


## Plain text only: no control characters, no BBCode, length-capped.
func _clean_chat(text: String) -> String:
	return _clean_text(text).left(CHAT_MAX)


## Display-safe text shared by chat and callsigns. Drops C0/C1 control
## characters and bidi overrides: names and chat reach Open Protocol clients
## through JSON, and Godot's JSON.stringify leaves raw control characters
## unescaped, which strict parsers reject (see OpenProtocolWire.send_message).
func _clean_text(text: String) -> String:
	var out := ""
	for ch in text.strip_edges():
		var code := ch.unicode_at(0)
		if code < 32 or (code >= 127 and code <= 159):
			continue
		if (code >= 0x202A and code <= 0x202E) or (code >= 0x2066 and code <= 0x2069):
			continue
		out += ch
	return out.replace("[", "(").replace("]", ")")


## A callsign as the host stores it: display-safe, trimmed, length-capped.
## Empty means "no usable name".
func clean_name(value: Variant, limit := 18) -> String:
	return _clean_text(value).strip_edges().left(limit) if value is String else ""


func set_display_name(new_name: String) -> void:
	var clean := clean_name(new_name)
	if clean == "":
		return
	local_name = clean
	if not is_online():
		return
	if is_host():
		if roster.has(1):
			roster[1]["name"] = clean
			_broadcast_roster()
			roster_changed.emit()
	else:
		_request_name.rpc_id(1, clean)


## Host: peer id -> colour indices that player has unlocked (Feats). Only used
## to nudge them onto a colour they own; other players see whatever they wear.
var _allowed_colors := {}


## Host: store a peer's look, nudging the colour to the next free one.
func _assign_cosmetic(peer_id: int, color: int, skin: int) -> void:
	var taken := []
	for other in roster:
		if int(other) != peer_id:
			taken.append(int(roster[other].get("color", -1)))
	roster[peer_id]["color"] = Cosmetics.free_color(color, taken, _allowed_colors.get(peer_id, []))
	roster[peer_id]["skin"] = Cosmetics.wrap_skin(skin)


## Host: send everyone into the run.
func request_start() -> void:
	if not is_host() or run_active or roster.is_empty():
		return
	run_map_id = _resolve_lobby_map()
	run_active = true
	for peer in roster:
		if _is_peer_open(peer):
			_start_run.rpc_id(peer, run_map_id)
	run_started.emit()


func _resolve_lobby_map() -> String:
	if not lobby_votes_enabled or lobby_vote_counts.is_empty():
		return Maps.resolve(lobby_map_id)
	var most := 0
	var leaders: Array[String] = []
	for id: String in lobby_vote_counts:
		var count: int = lobby_vote_counts[id]
		if count > most:
			most = count
			leaders.clear()
		if count == most:
			leaders.append(id)
	var winner: String = leaders.pick_random()
	return Maps.resolve(winner)


## The run is over (results screen): late joiners should go to the lobby.
func end_run() -> void:
	var was_active := run_active
	run_active = false
	run_peers.clear()
	_reset_run_readiness()
	if was_active and is_host() and lobby_votes_enabled:
		_map_votes.clear()
		_broadcast_roster()


# ------------------------------------------------------------------ roster
func _on_connected() -> void:
	if mode != Mode.CLIENT:
		return
	var saved := Settings.player_name.strip_edges().left(18)
	if saved != "":
		local_name = saved
	elif local_name == "":
		local_name = "PLAYER %d" % multiplayer.get_unique_id()
	_connect_left = 0.0
	# Keep the hello RPC's argument types stable so older hosts can decline it.
	var hello := JSON.stringify({"name": local_name, "color": Settings.suit_color, "skin": Settings.suit_skin,
		"colors": Feats.unlocked_colors()})
	_hello.rpc_id(1, hello, PROTOCOL)
	joined_server.emit()


# ------------------------------------------------------------------ run scene readiness
## Host: peers whose run scene (main.tscn) is loaded. High-rate relays go only
## to these, so a client still loading or leaving the run doesn't get RPCs
## for nodes it doesn't have yet ("Node not found" spam).
var run_peers := {}
var _pending_run_peers := {}
var _host_run_ready := false
var _server_confirmed_run := false


## True when `peer_id` is connected and its underlying WebSocket is still OPEN.
func _is_peer_open(peer_id: int) -> bool:
	if not is_online() or is_thin_peer(peer_id):
		return false
	if peer_id not in multiplayer.get_peers():
		return false
	if multiplayer.multiplayer_peer.has_method("is_peer_open"):
		return multiplayer.multiplayer_peer.is_peer_open(peer_id)
	if multiplayer.multiplayer_peer is WebSocketMultiplayerPeer:
		var ws: WebSocketPeer = multiplayer.multiplayer_peer.get_peer(peer_id)
		return ws != null and ws.get_ready_state() == WebSocketPeer.STATE_OPEN
	return true


func _open_peers(exclude_peer := 0) -> PackedInt32Array:
	var result := PackedInt32Array()
	if not is_online():
		return result
	for peer in multiplayer.get_peers():
		if peer != exclude_peer and _is_peer_open(peer):
			result.append(peer)
	return result


func _broadcast_roster(exclude_peer := 0) -> void:
	lobby_vote_counts.clear()
	for id: String in _map_votes.values():
		lobby_vote_counts[id] = int(lobby_vote_counts.get(id, 0)) + 1
	for peer in roster:
		if peer != exclude_peer and _is_peer_open(peer):
			_push_roster.rpc_id(peer, roster, lobby_map_id, lobby_votes_enabled,
				lobby_vote_counts, str(_map_votes.get(peer, "")))


## Host: send `method` to every connected peer whose WebSocket is still OPEN.
func rpc_to_all(method: Callable, args: Array = []) -> void:
	for peer in _open_peers():
		Callable.create(method, "rpc_id").callv([peer] + args)


## Every peer: call when the run scene is ready (true) or being left (false).
signal run_peer_loaded(peer_id: int)


func report_in_run(value: bool) -> void:
	if not value:
		_server_confirmed_run = false
	if is_host() or not _is_peer_open(1):
		return
	_report_in_run.rpc_id(1, value)


func can_send_run_rpc() -> bool:
	return is_host() or (_server_confirmed_run and _is_peer_open(1))


## Called after the host has created the map and every player's RPC nodes.
func accept_run_peers() -> void:
	_host_run_ready = true
	for peer: int in _pending_run_peers:
		_accept_run_peer(peer)
	_pending_run_peers.clear()


func _reset_run_readiness() -> void:
	_pending_run_peers.clear()
	_host_run_ready = false
	_server_confirmed_run = false


func _accept_run_peer(peer: int) -> void:
	if not _is_peer_open(peer):
		return
	run_peers[peer] = true
	run_peer_loaded.emit(peer)
	_confirm_run_ready.rpc_id(peer)


@rpc("authority", "call_remote", "reliable")
func _confirm_run_ready() -> void:
	_server_confirmed_run = run_active


@rpc("any_peer", "call_remote", "reliable")
func _report_in_run(value: bool) -> void:
	if not is_host():
		return
	var peer := multiplayer.get_remote_sender_id()
	if value:
		if not run_active or not roster.has(peer) or run_peers.has(peer):
			return
		if _host_run_ready:
			_accept_run_peer(peer)
		else:
			_pending_run_peers[peer] = true
	else:
		_pending_run_peers.erase(peer)
		run_peers.erase(peer)


## Host: send `method` to every peer whose run scene is loaded.
func rpc_to_run(method: Callable, args: Array) -> void:
	for peer in run_peers.keys():
		if _is_peer_open(peer):
			Callable.create(method, "rpc_id").callv([peer] + args)


func _guard_thin_identity(peer_id: int) -> void:
	# A native transport must never act with a server-owned roster identity.
	if is_thin_peer(peer_id):
		multiplayer.multiplayer_peer.disconnect_peer(peer_id)


func _on_peer_disconnected(peer_id: int) -> void:
	if not is_thin_peer(peer_id):
		remove_roster_peer(peer_id)


func remove_roster_peer(peer_id: int) -> void:
	run_peers.erase(peer_id)
	_pending_run_peers.erase(peer_id)
	peer_rtt_ms.erase(peer_id)
	_ping_sent_ms.erase(peer_id)
	if not is_host():
		return
	roster.erase(peer_id)
	_allowed_colors.erase(peer_id)
	_map_votes.erase(peer_id)
	_chat_last_ms.erase(peer_id)
	_broadcast_roster(peer_id)
	roster_changed.emit()


## Host: measure smoothed RTT to each connected client for lag compensation.
func _send_rtt_pings() -> void:
	_ping_seq += 1
	var now := Time.get_ticks_msec()
	for peer in _open_peers():
		_ping_sent_ms[peer] = {"seq": _ping_seq, "ms": now}
		_rtt_ping.rpc_id(peer, _ping_seq, float(peer_rtt_ms.get(peer, 0.0)))


@rpc("authority", "call_remote", "unreliable")
func _rtt_ping(seq: int, measured_rtt: float) -> void:
	local_rtt_ms = measured_rtt
	if mode == Mode.CLIENT and is_online():
		_rtt_pong.rpc_id(1, seq)


@rpc("any_peer", "call_remote", "unreliable")
func _rtt_pong(seq: int) -> void:
	if not is_host():
		return
	var peer := multiplayer.get_remote_sender_id()
	var sent: Variant = _ping_sent_ms.get(peer)
	if not sent is Dictionary or int(sent.seq) != seq:
		return
	var sample := clampf(float(Time.get_ticks_msec() - int(sent.ms)), 0.0, 1000.0)
	if peer_rtt_ms.has(peer):
		peer_rtt_ms[peer] = lerpf(float(peer_rtt_ms[peer]), sample, 0.3)
	else:
		peer_rtt_ms[peer] = sample


func get_peer_rtt_ms(peer_id: int) -> float:
	return float(peer_rtt_ms.get(peer_id, 0.0))


## Authoritative rewind window (ms) for a remote client's hitscan shot:
## half RTT plus ~33 ms (half of one 15 Hz enemy-sync interval), capped at 250 ms.
func get_rewind_ms(peer_id: int) -> int:
	if peer_id <= 1:
		return 0
	var rtt := get_peer_rtt_ms(peer_id)
	if rtt <= 0.0:
		return 50
	return clampi(roundi(rtt * 0.5 + 33.0), 0, LagComp.MAX_REWIND_MS)


func _on_connection_failed() -> void:
	if mode == Mode.OFFLINE:
		return
	leave()
	connection_failed.emit()


func _on_server_disconnected() -> void:
	if mode == Mode.OFFLINE:
		return
	leave()
	server_closed.emit()


@rpc("any_peer", "call_remote", "reliable")
func _hello(hello: String, protocol := 0) -> void:
	if not is_host():
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if is_thin_peer(peer_id):
		multiplayer.multiplayer_peer.disconnect_peer(peer_id)
		return
	var refusal := ""
	if protocol != PROTOCOL:
		refusal = "UPDATE REQUIRED (v%d, YOU HAVE v%d)" % [PROTOCOL, protocol]
	elif roster.size() >= MAX_PLAYERS:
		refusal = "SERVER FULL"
	if refusal != "":
		if _is_peer_open(peer_id):
			_reject.rpc_id(peer_id, refusal)
		# Let the reliable message go out before the peer is dropped.
		get_tree().create_timer(0.5).timeout.connect(func():
			if mode == Mode.HOST and peer_id in multiplayer.get_peers():
				multiplayer.multiplayer_peer.disconnect_peer(peer_id))
		return
	var data: Variant = JSON.parse_string(hello)
	if not data is Dictionary:
		return
	var player_name := clean_name(data.get("name"), 32)
	var color: Variant = data.get("color")
	var skin: Variant = data.get("skin")
	_allowed_colors[peer_id] = _color_list(data.get("colors"))
	roster[peer_id] = {"name": player_name if player_name != "" else "PLAYER", "ready": false}
	_assign_cosmetic(peer_id, int(color) if color is float else 0, int(skin) if skin is float else 0)
	_broadcast_roster()
	roster_changed.emit()
	# A run already in progress: send them in, and let GameManager catch up.
	if run_active and _is_peer_open(peer_id):
		_start_run.rpc_id(peer_id, run_map_id)
	peer_joined.emit(peer_id)


## Thin identities live in the roster only, never in the native transport.
func is_thin_peer(peer: int) -> bool:
	return thin_server != null and thin_server.input_for(peer) != null


func add_thin_player(peer: int, callsign: String) -> void:
	roster[peer] = {"name": callsign, "ready": false}
	_assign_cosmetic(peer, 0, 0)
	_broadcast_roster()
	roster_changed.emit()
	peer_joined.emit(peer)


## Host -> one client: you can't join, and why. The join screen shows it.
@rpc("authority", "call_remote", "reliable")
func _reject(reason: String) -> void:
	if mode != Mode.CLIENT:
		return
	leave()
	last_error = reason
	connection_failed.emit()


@rpc("authority", "call_remote", "reliable")
func _push_roster(new_roster: Dictionary, map_id: String, voting: bool, counts: Dictionary, my_vote: String) -> void:
	roster = new_roster
	lobby_map_id = map_id
	lobby_votes_enabled = voting
	lobby_vote_counts = counts
	lobby_my_vote = my_vote
	roster_changed.emit()


@rpc("any_peer", "call_remote", "reliable")
func _request_ready(value: bool) -> void:
	if not is_host():
		return
	set_ready_for_peer(multiplayer.get_remote_sender_id(), value)


func set_ready_for_peer(peer: int, value: bool) -> void:
	if is_host() and roster.has(peer):
		roster[peer]["ready"] = value
		_broadcast_roster()
		roster_changed.emit()


@rpc("any_peer", "call_remote", "reliable")
func _request_cosmetic(color: int, skin: int, unlocked: Array = []) -> void:
	if not is_host() or run_active:
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if roster.has(peer_id):
		_allowed_colors[peer_id] = _color_list(unlocked)
		_assign_cosmetic(peer_id, color, skin)
		_broadcast_roster()
		roster_changed.emit()


## Host: a client's unlocked-colour list, cleaned. Empty = no limit.
func _color_list(value: Variant) -> Array:
	var out := []
	if value is Array:
		for index: Variant in value:
			if (index is int or index is float) and int(index) >= 0 and int(index) < Cosmetics.COLORS.size():
				out.append(int(index))
	return out


@rpc("any_peer", "call_remote", "reliable")
func _request_name(new_name: String) -> void:
	if not is_host() or run_active:
		return
	var peer_id := multiplayer.get_remote_sender_id()
	var clean := clean_name(new_name)
	if clean != "" and roster.has(peer_id):
		roster[peer_id]["name"] = clean
		_broadcast_roster()
		roster_changed.emit()


@rpc("authority", "call_remote", "reliable")
func _start_run(map_id: String) -> void:
	if not Maps.is_available(map_id):
		_reject("UPDATE REQUIRED (%s)" % Maps.display_name(map_id))
		return
	run_map_id = map_id
	run_active = true
	run_started.emit()
