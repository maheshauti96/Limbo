# Limbo

macOS menu-bar board for Cursor, Claude, Grok, and Codex sessions.

A local Go watcher reads verified Mac signals and writes a JSON snapshot. The tray reads that file. No webhooks. No HTTP. No secrets in logs or files.

The watcher binary is still `session-watcher`.

## Build

```bash
make build
# → bin/session-watcher  (darwin/arm64)
```

Or:

```bash
GOOS=darwin GOARCH=arm64 go build -o bin/session-watcher ./cmd/session-watcher
```

## Test

```bash
make test
# or: go test ./...
```

Tests inject fixture paths and process listings — they never hit a real home directory.

## Run

```bash
# single snapshot
./bin/session-watcher once

# poll every 5s (default); override with -interval
./bin/session-watcher watch
./bin/session-watcher watch -interval 2s
```

### Outputs

**1. Transition log** (`events.jsonl`) — one JSON line per `(tool,label)` state change, also printed to stdout:

```json
{"tool":"cursor","label":"Cursor","state":"idle","ts":"2026-09-16T10:00:00Z","source":"session-watcher"}
```

| Field | Values |
|-------|--------|
| `tool` | `cursor` \| `claude` \| `grok` \| `codex` |
| `label` | Tool-specific (see signals docs) |
| `state` | `running` \| `idle` \| `finished` |
| `ts` | RFC3339 UTC |
| `source` | `session-watcher` |

**Log path:** `~/Library/Logs/session-watcher/events.jsonl`  
Fallbacks: `$SESSION_WATCHER_LOG`, or `./events.jsonl` if `~/Library` is missing.

**2. Tray snapshot** (`state.json`) — rewritten atomically on every `once` / watch tick with the **current live set only** (no finished rows):

```json
{"updated":"2026-09-16T10:00:00Z","sessions":[{"tool":"cursor","label":"Cursor","state":"idle","ts":"2026-09-16T10:00:00Z"}]}
```

**State path:** `~/Library/Application Support/session-watcher/state.json`  
Fallbacks: `$SESSION_WATCHER_STATE`, or `./state.json` if `~/Library` is missing.

The tray app should read `state.json` (not scrape processes itself).

Dedup: emits only when `(tool, label)` state changes; disappeared → `finished` in the event log.

## Signals

See [docs/signals.md](docs/signals.md) and [VERIFIED_SIGNALS.md](VERIFIED_SIGNALS.md).

## LaunchAgent (optional)

Example plist: [deploy/com.maheshauti.session-watcher.plist](deploy/com.maheshauti.session-watcher.plist) (commented; install manually on the Mac).

## Module

`github.com/maheshauti/session-watcher`
