extends RefCounted
## Entry hook for the Open Protocol Full tier.
##
## Called by game/thin_server.gd when a client sends {"t":"hello","v":1,"tier":"full",...}
## after common validation (protocol version, optional join code, encoding).
## Hands the connection to the dedicated server's FullPeer adapter beneath SceneMultiplayer.

const FullPeer := preload("res://game/open_protocol/full_peer.gd")


static func accept(conn: RefCounted, hello: Dictionary) -> bool:
	var peer := FullPeer.get_active()
	if peer == null:
		conn.close("unavailable", "Full tier server is not active", 1011)
		return false
	peer.add_full_peer(conn, hello)
	return true
