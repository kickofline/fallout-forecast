# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

**Fallout Forecast** (`fallout-forecast`): a 1–4 player co-op retro FPS set on Halloween night, 1987, built in **Godot 4.7.2** for CSCI 3103 by Sam and Drew.

- **Design doc:** `docs/design-doc.md` is a repo snapshot of the live doc (`https://claude.ai/artifact/NwyXaaPmhz2YVwNuYezedt`). Update the live doc when the connector is available and re-export `docs/design-doc.md` after notable changes.
- **Engine:** Godot 4.7.2 (Forward Plus / D3D12 on Windows desktop, Compatibility on Web, Jolt Physics). Keep desktop, web export templates, and server builds on the exact same Godot version.

## Workflow & Rules

- Commit `.uid` files alongside scripts and resources. `.godot/` is ignored.
- Bump `Net.PROTOCOL` in `game/net.gd` (currently `19`) whenever an RPC signature, replicated payload, or networked node path changes so mismatched clients are rejected cleanly instead of desyncing.
- **Standing rule — Protocol changelog (`docs/open-protocol/CHANGELOG.md`):** Whenever you change *anything* that affects the network or Open Protocol — `Net.PROTOCOL` or Open Protocol `VERSION`, any `@rpc` signature/node path/transfer mode/payload, any Thin or Full message/binary layout/Variant mapping/error string/limit/timeout, or any game-data ID/level marker used by external clients — you **MUST** add a newest-first entry at the top of `docs/open-protocol/CHANGELOG.md` in the same commit/PR following its template (including exact wire/RPC deltas and concrete **Client action** steps for Thin and Full clients). In the same change, update affected `docs/open-protocol/spec-*.md` / `KNOWN_ISSUES.md`, regenerate `docs/open-protocol/open-protocol-schema.json` (`tools/open_protocol/gen_schema.gd`), `rpc-catalog.md` (`tools/open_protocol/gen_rpc_catalog.py`), and `game-data.json` / `level-markers.json` (`tools/open_protocol/gen_reference.gd`) when RPCs or catalogs change, and mirror `docs/open-protocol/` to `kickofline/fallout-forecast-clients` when syncing client docs.
- Commit and push changes cleanly; keep throwaway test/capture scripts outside the repository.
- Keep READMEs, compose files, docs, and code comments infrastructure-agnostic (no private hostnames, deployment dashboards, internal UUIDs, or credentials).

## Commands

Use the Godot 4.7.2 console binary (`godot` below; quote repo paths since the workspace path may contain spaces).

- **Run the game:** `godot --path .` (entry scene is `res://ui/title.tscn`; the gameplay run scene is `res://main.tscn`).
- **Re-import & refresh global class cache:** `godot --headless --path . --import` — run after adding `class_name` scripts or new assets, and before headless `-s` scripts that rely on them.
- **Run a local dedicated server:** `godot --headless --path . --audio-driver Dummy -- --server [--port=7777] [--map pinecrest]` (see `server/README.md`). Point the client at `ws://127.0.0.1:7777/` under **Settings > SERVER (WSS)**.
- **Test Web material folding on desktop:** `FALLOUT_WEB_MATERIALS=1 godot --path .`
- **Run a scripted check:** `godot --path . --audio-driver Dummy -s <script.gd>` (extends `SceneTree`):
  - Use `_initialize()`, not `_init()`, because autoloads (`WeatherManager`, `Net`, `GameManager`, etc.) are not available in `_init()`.
  - Avoid referencing `class_name` types at compile time in `-s` scripts; use `load()` at runtime.
  - `Settings` loads `user://settings.cfg` on the first frame, so set `Settings.solo_map_id` *after* yielding a frame if driving a specific district.
  - Set `FALLOUT_TELEMETRY_URL=http://127.0.0.1:1/` during windowed test runs so synthetic sessions don't send production telemetry (headless runs skip telemetry unless `FALLOUT_TELEMETRY_FORCE=1`).
  - Headless runs cannot take screenshots (`get_image()` hangs). For screenshots, run without `--headless`, call `DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)` in `_initialize()` and after instancing the scene, set `Input.mouse_mode = Input.MOUSE_MODE_VISIBLE`, disable the player's `_unhandled_input`, and back up/restore `user://settings.cfg`.
- **CI & builds:** No unit-test framework yet. GitHub Actions runs desktop exports (`.github/workflows/native-builds.yml`), web export + Nginx verification (`.github/workflows/web-export.yml`), and dedicated server Docker + WebSocket handshake checks (`.github/workflows/server-build.yml`).

## Architecture

### Scene Flow & Autoloads
- **Scene flow:** `ui/title.tscn` → `ui/map_select.tscn` (solo) or `ui/lobby.tscn` (Cloud Play) → `SceneLoader` loading card → `main.tscn` → `ui/results.tscn` → back to lobby (online) or title.
- **Autoloads** (registered in `project.godot`): `Net`, `WeatherManager`, `Settings`, `Sound`, `RNG`, `GameManager`, `Playtest`, `MenuState`, `Preload`, `SceneLoader`, `Perf`, `Juice`, `Telemetry`.

### Networking (`game/net.gd`, `game/dedicated_server.gd`, `game/lag_comp.gd`)
- **Transport:** `WebSocketMultiplayerPeer` (TCP 7777) with `server_relay = false` everywhere so web and desktop cross-play. Multiplayer is dedicated-server **Cloud Play** only (`Net.CLOUD_URL = "wss://fallout.drew.place/"`, overridable in Settings); there is no player LAN hosting or server browser.
- **Authority check:** `Net.is_host()` ("offline, or server") is the single check the codebase asks — offline solo runs the exact same host code path. Never duplicate this check.
- **Dedicated server:** Peer `1` with no local player (`Net.dedicated = true`); handles lobby map voting (`--map` fallback) and resets between runs.
- **RPC rules:**
  - Autoloads and scene nodes keep authority `1` → host→client broadcasts use `@rpc("authority", "call_remote", ...)`.
  - Player nodes (`Players/P_<peer_id>`) have authority assigned to their owning peer *before* `add_child()` → RPCs on player nodes must be `@rpc("any_peer", ...)` with explicit `multiplayer.get_remote_sender_id()` validation so the host can relay on a client's behalf.
  - Clients cannot address each other directly; all client-to-client state routes `client → host → clients`.
- **Sync pattern:** Manual `_push_*` / `_apply_*` RPCs (no `MultiplayerSynchronizer` or `MultiplayerSpawner`). Player transforms sync at 20 Hz, infected positions batch at 20 Hz, and `LagComp` rewinds enemy/Turned capsules analytically against static world cover using per-peer smoothed RTT for client hitscan shots.
- **Late joiners:** `Net.run_peer_loaded` → `GameManager._on_run_peer_loaded` → `_sync_run_to_peer`.

### Core Gameplay Systems
- **`main.tscn` / `main.gd`:** Instantiates the chosen district from `Maps` (`game/maps.gd`) as `Level`, applies `WebMaterials` if active, installs `props/tree_shelter.gd`, `RunLoot`, `DeconShower`s, players, `Pings` (`game/ping_system.gd`), `StarterPicker`, `PauseMenu`, `JuiceHud`, `HitIndicator`, `Spectator`, `TeammateMarkers`, `PingHud`, and (in debug builds) `DevMenu`, then prepares navigation on a deferred physics frame.
- **`GameManager` (`game/game_manager.gd`):** Owns wave/run state, shared decon charges, player-count scaling, win/lose detection, and post-Cumulus **Endless Mode** (`awaiting_tape_choice` / `endless`). Hosts three child managers:
  - `MutationRoll` (`game/mutation_roll.gd`) — forecast-driven enemy wave modifier + 3-card player bio-mutation draft (`1`/`2`/`3` or D-pad; vote tally in co-op).
  - `CrateManager` (`game/crate_manager.gd`) — Marked airdrops land near the squad during Calm or early Drizzle. Sheltered three-bay vending stations (`crates/supply_station.gd`) rotate their scrap offers.
  - `FeatTracker` (`game/feat_tracker.gd`, definitions in `game/feats.gd`) — 31 achievements (3 hidden); 9 unlock suit colors or skins saved locally per player in `Settings`.
- **`WeatherManager` (`weather/weather_manager.gd`) & `weather/`:** Drives `Calm → Drizzle → Downpour (Acid Storm on Wave 5) → Clearing`, `storm_intensity` (0–1), `enemy_buff()`, `suit_loss_per_second()`, and `lightning_struck`. The mutation draft opens during Calm. Rain, fog (`weather_fx.gd`), lightning bolts/outlines (`lightning_fx.gd`), and puddles (`puddle.gd`) run locally on each client.
- **`Player` (`player/`):** Owning peer runs movement/look and reports `sheltered` and `in_puddle` to the host. `exposed = not sheltered or in_puddle` (layer 4 shelter areas, roof raycasts, tree canopies, Shield Domes, or raised Tarp; layer 5 puddles override stationary roof shelter). Full `ok` / `downed` / `turned` / `out` state machine with `revive_spot.gd`, solo self-revive, animated `player_model.gd`, and 10 suit colors × 5 skins (`player/cosmetics.gd`).
- **`Weapons & Inventory` (`weapons/`):** Authoritative 5-slot inventory (`run_loot.gd`, `item_catalog.gd`, `world_pickup.gd`, `weapon_holder.gd`, `weapon_combat.gd`, `gun_models.gd`, `item_models.gd`). 15 firearms (including 3 cursed guns in `weapons/cursed/` and legendary `disruptor`) plus 9 throwables/deployables/consumables (`Shield Dome`, `Frag Grenade`, `Umbrella Stand`, `Bleach Bomb`, `Bait Radio`, `Sandbag`, `Lightning Rod Spike`, `Med Tin`, `Suit Patch`). Owning clients play immediate hitscan muzzle/recoil feedback while the host resolves ammo, lag-compensated hits, tracers, and enemy flinch; projectiles (`projectile.gd`) simulate locally with host-only damage.
- **`Enemies` (`enemies/`):** `EnemyBase` advances along `NavigationAgent3D` path points manually (do not switch back to the agent's built-in waypoint advance). Subclasses override `choose_target`, `attack`, and `in_range_move`, tuned via `EnemyData` `.tres` files. `WavePlan` (`enemies/wave_plan.gd`) and `enemy_spawner.gd` orchestrate finite burst waves: Drip, Gutter, Mister, armored Hailstone, forecast specialists (`Sleet`, `Smog`, `Static`, `Thunderhead`, `Undertow`), Wave-3 miniboss `Cloudburst`, and Wave-5 boss `Cumulus` (`enemies/boss/boss_cumulus.gd`).

### Districts, Art, Retro & Web Constraints
- **Districts (`game/maps.gd`, `levels/`):**
  - `pinecrest` (`levels/pinecrest/level_pinecrest.tscn`) — downtown Main Street, restyled at runtime by `props/building_restyle.gd`, `pinecrest_houses.gd`, `pinecrest_shops.gd`, and `map_signs.gd` (Pinecrest-only).
  - `harbor` (`levels/harbor/level_harbor.tscn`) — tidal market, Fish Exchange, Cannery, Signal Walk (`tools/levels/build_harbor.gd`, `props/harbor/`).
  - `maple_hollow` (`levels/maple_hollow/level_maple_hollow.tscn`) — misty pine/maple forest, chapel, cemetery (`tools/levels/build_maple_hollow.gd`, `props/maple_hollow/`).
  - Systems locate level anchors by group: `player_spawn`, `enemy_spawn`, `drain_spawn`, `crate_spawn`, `decon_shower`, `boss_anchor`, `shelter` (layer 4 `Area3D`), `puddles` (layer 5 `Area3D`).
- **Assets:** Remapped Kenney CC0 kits in `assets/kenney/` (tint/layer-adjust via `props/model_style.gd` on model roots rather than editing `.glb` internals) plus 64×64 nearest-filtered world-triplanar textures in `assets/textures/`.
- **Retro & Web performance (`retro/`, `game/warmup.gd`, `props/static_batcher.gd`):**
  - Desktop `RetroScreen` applies a 240-line VHS post shader and swaps opaque `StandardMaterial3D`s to `ps1.gdshader` (vertex snap), skipping transparent/unshaded/emissive materials.
  - Web uses Compatibility mode, disables PS1/VHS world passes (keeps REC/timestamp OSD), folds materials (`retro/web_materials.gd`), batches static props (`props/static_batcher.gd`), skips dynamic gunshot `OmniLight3D`s, and warms surfaces behind `TUNING IN` (`game/warmup.gd`).
  - **Web gotchas:** Never toggle `Environment.fog_enabled` at runtime (recompiles all shaders; vary density instead), and do not use `ResourceLoader.load_threaded_request` for `main.tscn` from the title screen (deadlocks on web; use `SceneLoader`).
- **UI & Audio (`ui/`, `game/sound.gd`, `tools/audio/`):** 960×720 4:3 minimum canvas (expand stretch on widescreen), `VT323` font, panel-free HUD (`hud.gd`, `BroadcastUI`, `compass.gd`, `item_hotbar.gd`). Continuous adaptive synthwave score and synthesized SFX (`tools/audio/gen_*.py`; credits in `assets/audio/CREDITS.md`).

### Physics Layers & Debug Keys
- **Physics layers:** `1` world, `2` player, `3` enemy, `4` shelter, `5` puddle.
- **Debug keys** *(debug builds)*:
  - `F1` next storm phase · `F2` jump to Wave 5 · `F6` trigger lightning
  - `F3` / `F4` / `F5` spawn Drip / Gutter / Mister
  - `Shift+F3..F8` spawn Sleet / Hailstone / Undertow / Static / Smog / Thunderhead
  - `F8` toggle RetroScreen · `F9` toggle debug HUD · `F10` open Dev Menu · `F11` toggle fullscreen
