# Dedicated server

Native Godot multiplayer uses WebSockets (`WebSocketMultiplayerPeer`), so desktop and web builds can play together. The default cloud server is `wss://fallout.drew.place/` (`Net.CLOUD_URL`, joined with `Net.join_cloud()`).

## Run locally

```sh
godot --headless --path . --audio-driver Dummy -- --server [--port=7777] [--map pinecrest] [--thin-port=7780] [--thin-tcp-port=7781] [--heartbeat=/tmp/fallout-heartbeat]
```

The server is peer 1 but is not a player. It logs joins, leaves, and runs to stdout. A run starts once every connected player is READY in the lobby (or force-started). After the results screen, or when everyone leaves, it unloads the run and waits for the next one. Code: `game/dedicated_server.gd`.

Players vote for a map or RANDOM before starting. The server chooses the winner and breaks ties at random. With no votes, it uses `--map <id>`. The default is Pinecrest, including when the supplied map is unavailable.

Clients join from **CLOUD PLAY** on the title screen. **Settings > SERVER (WSS)** can point the client at any server, e.g. `ws://127.0.0.1:7777/` for a local instance.

## Open Protocol

Thin clients share the same lobby, run, and four-player limit as native clients.
Connect to Open Protocol over WebSocket on port 7780 or raw TCP on port 7781.
Set either port to 0 to disable that listener. Set `FALLOUT_THIN_JOIN_CODE`
to require a shared join code in the Open Protocol hello. `--thin-join-code=VALUE`
overrides the environment variable. Use a long random code (12+ characters). The
code applies only to the Open Protocol ports, not to the native port 7777.

Wrong join codes are logged and rate-limited per client address. If every
WebSocket client reaches the server through a reverse proxy, list the proxy's
address in `FALLOUT_TRUSTED_PROXIES` (comma-separated, or `--trusted-proxies=`)
so per-address limits don't treat all players as one client; a server-wide
limit still applies. Rate-limit connections at the proxy or firewall too:
Godot's listener keeps a short accept backlog, so a fast reconnect flood is best
dropped before it reaches the server.

Use a TLS-terminating reverse proxy for public WebSocket connections. Raw TCP is
plaintext, including the join code. Publish it only on a network where plaintext is
acceptable or place a suitable encrypted transport in front of it.

Run the Thin conformance client from the repository root:

    uv run tools/thin_client/fake_client.py
    uv run tools/thin_client/fake_client.py --enc bin
    uv run tools/thin_client/fake_client.py --transport tcp --enc bin

These checks start a run by default. Pass `--connect-only` to check just the lobby.
Set `FALLOUT_TELEMETRY_URL=http://127.0.0.1:1/` when running local game fixtures.
The protocol and examples are in the [Open Protocol specification](../docs/open-protocol.md).

## Docker

The build context is the repo root (BuildKit reads `server/Dockerfile.dockerignore`).

```sh
# ARM64 (default)
docker build -f server/Dockerfile -t fallout-server .

# AMD64 / x86_64
docker build -f server/Dockerfile --build-arg GODOT_ARCH=x86_64 -t fallout-server .

# Run locally with the native and Open Protocol listeners
docker run --rm -p 7777:7777 -p 7780:7780 -p 7781:7781 fallout-server
```

- The image downloads the official Godot 4.7.2 Linux binary (verifying the SHA512 checksum on `arm64`), builds the `.godot` import cache at build time, and runs as an unprivileged user under `tini`.
- **Liveness:** The server rewrites `/tmp/fallout-heartbeat` every 15 s, and the Docker `HEALTHCHECK` fails if the file is older than a minute.
- **Reverse proxy & TLS:** Browser builds served over HTTPS require `wss://`. In production, place a TLS-terminating reverse proxy in front of container ports `7777` and `7780` for the native and Open Protocol routes and forward WebSocket upgrade requests (`Upgrade: websocket`).
- **CI:** The **Dedicated server build** GitHub Actions workflow (`server-build.yml`) builds the container image and verifies both the healthcheck and WebSocket upgrade handshake.
- **Protocol compatibility:** Clients must match the server's `Net.PROTOCOL` version. Bump `Net.PROTOCOL` whenever an RPC or networked scene path changes; mismatched clients are turned away with a message.
