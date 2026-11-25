# AGENTS.md

Read [CLAUDE.md](CLAUDE.md) for the full project architecture, Godot 4.7.2 commands, and coding rules.

## Standing Rules (Required for All Agents)

1. **Log every protocol change in [`docs/open-protocol/CHANGELOG.md`](docs/open-protocol/CHANGELOG.md):**
   - Any change to `Net.PROTOCOL`, Open Protocol `VERSION`, any `@rpc` signature / node path / transfer mode / payload, any Thin or Full wire message / binary layout / Variant mapping / error string / limit / timeout, or any game-data ID or level marker name used by external clients **MUST** include a new entry at the top of `docs/open-protocol/CHANGELOG.md` in the same commit or PR.
   - Follow the template in `CHANGELOG.md` and list concrete **Client action** steps for both Thin and Full clients so external client agents can update their ports cleanly without diffing the entire Godot codebase.
   - Update affected spec files (`docs/open-protocol/spec-*.md`, `KNOWN_ISSUES.md`) and regenerate `open-protocol-schema.json` / `rpc-catalog.md` / `game-data.json` / `level-markers.json` when RPCs or catalogs change.
2. **Bump `Net.PROTOCOL` in `game/net.gd`** whenever an RPC signature, replicated payload, or networked node path changes.
3. **Commit `.uid` files** alongside new scripts/resources, and keep all public repo files infrastructure-agnostic (no private hostnames, internal IPs, dashboards, UUIDs, or secrets).
4. **Building an external client?** Start at [`docs/open-protocol/AGENTS.md`](docs/open-protocol/AGENTS.md) and check [`docs/open-protocol/CHANGELOG.md`](docs/open-protocol/CHANGELOG.md) for recent changes.
