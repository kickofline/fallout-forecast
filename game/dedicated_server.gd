extends Node
## Headless dedicated server. Net adds this as its child when the game is
## launched with `-- --server` (see server/README.md):
##
##   godot --headless --path . --audio-driver Dummy -- --server [--port=7777] [--map pinecrest] [--heartbeat=/tmp/fallout-heartbeat]
##
## The server is peer 1 but not a player: Net.host(port, false) leaves it out
## of the roster, so players(), player_count() and the lose check only see the
## clients. Between runs there is no current scene at all; clients sit in their
## own lobby screens. The run starts when every connected player is READY, and
## after the results (or when everyone leaves) the server unloads the run and
## waits again.

## After run_finished: main.gd shows clients the results 4.5 s later.
const RESULTS_DELAY := 5.0
const HEARTBEAT_EVERY := 15.0
const STATUS_EVERY := 300.0

var _port := 7777
var _thin_port := 7780
var _thin_tcp_port := 7781
var _thin_join_code := ""
var _trusted_proxies := PackedStringArray()
var _default_map := Maps.DEFAULT_ID
var _heartbeat_path := ""
var _heartbeat_left := 0.0
var _status_left := STATUS_EVERY
var _in_run := false
var _run_serial := 0


func _ready() -> void:
	_port = Net.PORT
	_thin_join_code = OS.get_environment("FALLOUT_THIN_JOIN_CODE")
	_trusted_proxies = _address_list(OS.get_environment("FALLOUT_TRUSTED_PROXIES"))
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		var arg: String = args[i]
		if arg.begins_with("--port="):
			_port = int(arg.get_slice("=", 1))
		elif arg.begins_with("--thin-port="):
			_thin_port = _port_value(arg)
		elif arg.begins_with("--thin-tcp-port="):
			_thin_tcp_port = _port_value(arg)
		elif arg.begins_with("--thin-join-code="):
			_thin_join_code = arg.trim_prefix("--thin-join-code=")
		elif arg.begins_with("--trusted-proxies="):
			_trusted_proxies = _address_list(arg.trim_prefix("--trusted-proxies="))
		elif arg.begins_with("--heartbeat="):
			_heartbeat_path = arg.get_slice("=", 1)
		elif arg == "--map" and i + 1 < args.size():
			_default_map = args[i + 1]
		elif arg.begins_with("--map="):
			_default_map = arg.get_slice("=", 1)
	if not Maps.is_available(_default_map):
		_log("map %s unavailable, defaulting to %s" % [_default_map, Maps.DEFAULT_ID])
		_default_map = Maps.DEFAULT_ID
	# Keep simulating with no window focus and no frame-rate cap from vsync.
	Engine.max_fps = 60
	_start.call_deferred()


func _address_list(value: String) -> PackedStringArray:
	var out := PackedStringArray()
	for part in value.split(",", false):
		if not part.strip_edges().is_empty():
			out.append(part.strip_edges())
	return out


func _port_value(arg: String) -> int:
	var value := arg.get_slice("=", 1)
	return value.to_int() if value.is_valid_int() else -1


func _start() -> void:
	var err := Net.host(_port, false, _default_map)
	if err != OK:
		_log("ERROR could not open WebSocket port %d (error %d)" % [_port, err])
		get_tree().quit(1)
		return
	# The title screen is the project's main scene; the server never shows it.
	if get_tree().current_scene:
		get_tree().unload_current_scene()
	multiplayer.peer_connected.connect(func(id): _log("peer %d connected" % id))
	multiplayer.peer_disconnected.connect(_on_peer_left)
	Net.peer_joined.connect(_on_peer_joined)
	Net.roster_changed.connect(_on_roster_changed)
	Net.force_start_requested.connect(_on_force_start)
	GameManager.run_finished.connect(_on_run_finished)
	_log("listening for WebSocket (ws://) on TCP %d (protocol v%d, max %d players)" % [_port, Net.PROTOCOL, Net.MAX_PLAYERS])
	_log("default map: %s" % _default_map)
	if not _start_thin_server():
		get_tree().quit(1)
		return
	_beat()


func _start_thin_server() -> bool:
	if _thin_port < 0 or _thin_port > 65535 or _thin_tcp_port < 0 or _thin_tcp_port > 65535:
		_log("ERROR invalid Open Protocol port")
		return false
	if _thin_port == 0 and _thin_tcp_port == 0:
		return true
	var service := Node.new()
	service.name = "ThinServer"
	service.set_script(load("res://game/thin_server.gd"))
	if service.get_script() == null:
		service.free()
		return false
	add_child(service)
	var err: Error = service.listen(_thin_port, _thin_tcp_port, _thin_join_code, _trusted_proxies)
	if err != OK:
		_log("ERROR could not open Open Protocol listeners (%s)" % error_string(err))
		return false
	Net.thin_server = service
	_log("Open Protocol listeners: WebSocket %d, raw TCP %d (0 disabled)" % [_thin_port, _thin_tcp_port])
	if _thin_join_code.is_empty():
		_log("Open Protocol has no join code: any client can join")
	else:
		if _thin_join_code.length() < 12:
			_log("WARNING the Open Protocol join code is shorter than 12 characters; use a long random code")
		_log("Open Protocol join code set (it does not apply to the native port %d)" % _port)
	if not _trusted_proxies.is_empty():
		_log("Open Protocol per-address limits skip trusted proxies: %s" % ", ".join(_trusted_proxies))
	return true


func _process(delta: float) -> void:
	_heartbeat_left -= delta
	if _heartbeat_left <= 0.0:
		_beat()
	_status_left -= delta
	if _status_left <= 0.0:
		_status_left = STATUS_EVERY
		_log("status: %d player(s), %s" % [Net.roster.size(), _state_text()])


func _on_peer_joined(peer_id: int) -> void:
	_log("player joined: %d \"%s\" (%d/%d)%s" % [peer_id, _name(peer_id), Net.roster.size(),
		Net.MAX_PLAYERS, ", sent into the run in progress" if _in_run else ""])


func _on_peer_left(peer_id: int) -> void:
	_log("peer %d disconnected (%d player(s) left)" % [peer_id, Net.roster.size()])


func _on_roster_changed() -> void:
	if _in_run:
		if Net.roster.is_empty():
			_log("everyone left: abandoning the run")
			_reset()
		return
	if Net.roster.is_empty():
		return
	for info in Net.roster.values():
		if not bool(info.get("ready", false)):
			return
	_start_run.call_deferred()


func _on_force_start(by: String) -> void:
	if _in_run or Net.roster.is_empty():
		return
	_log("%s forced the start" % by)
	_start_run.call_deferred()


func _start_run() -> void:
	if _in_run or Net.roster.is_empty():
		return
	_in_run = true
	_run_serial += 1
	# Everyone is un-READY afterwards, so the next run waits for the lobby.
	for peer_id in Net.roster:
		Net.roster[peer_id]["ready"] = false
	Net._broadcast_roster()
	Net.request_start()
	_log("run %d starting on %s with %d player(s): %s" % [_run_serial, Net.run_map_id, Net.roster.size(), ", ".join(_names())])
	var serial := _run_serial
	await get_tree().create_timer(SceneLoader.MAP_REVEAL_SECONDS).timeout
	if _in_run and serial == _run_serial:
		var err := get_tree().change_scene_to_file(Maps.RUN_SCENE)
		if err != OK:
			_log("ERROR could not start run %d (error %d)" % [serial, err])
			_reset()


func _on_run_finished(won: bool, results: Dictionary) -> void:
	if not _in_run:
		return
	# Nobody joins a finished run; they wait in the lobby for the next one.
	Net.end_run()
	_log("run %d finished: %s, %d wave(s)" % [_run_serial, "WON" if won else "LOST", int(results.get("waves", 0))])
	var serial := _run_serial
	get_tree().create_timer(RESULTS_DELAY).timeout.connect(func():
		if _in_run and serial == _run_serial:
			_reset())


## Back to idle: no scene, no weather, no run state. Same cleanup as main._end.
func _reset() -> void:
	_in_run = false
	Net.end_run()
	GameManager.run_active = false
	GameManager.finished = true
	GameManager.mutations.reset_run()
	WeatherManager.stop()
	if get_tree().current_scene:
		get_tree().unload_current_scene()
	if Net.thin_server:
		Net.thin_server.lobby_reset()
	_log("idle: waiting for players to ready up (%d connected)" % Net.roster.size())
	# Anyone who readied up during the results screen.
	_on_roster_changed.call_deferred()


## Liveness for Docker: the file's mtime proves the main loop is turning.
func _beat() -> void:
	_heartbeat_left = HEARTBEAT_EVERY
	if _heartbeat_path == "":
		return
	var f := FileAccess.open(_heartbeat_path, FileAccess.WRITE)
	if f:
		f.store_line("%d %d %s" % [Time.get_unix_time_from_system(), Net.roster.size(), _state_text()])


func _state_text() -> String:
	return "in run %d" % _run_serial if _in_run else "idle"


func _name(peer_id: int) -> String:
	return str(Net.roster.get(peer_id, {}).get("name", "?"))


func _names() -> Array:
	var out := []
	for peer_id in Net.roster:
		out.append(_name(peer_id))
	return out


func _log(text: String) -> void:
	print("[%s] [server] %s" % [Time.get_datetime_string_from_system(true), text])
