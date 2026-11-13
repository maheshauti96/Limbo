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

## Limbo Tasks (live Claude sessions)

A separate, small menu bar app in [tasks/main.swift](tasks/main.swift). It does not need the Go watcher.

```bash
make install-tasks     # build, install ~/Applications/Limbo Tasks.app, start at login, start now
make uninstall-tasks   # remove the app and the login item
make tasks             # build only -> bin/limbo-tasks
```

- **Menu bar:** a play symbol with the number of running sessions and a pause symbol with the number waiting for you. One template image, so it follows light and dark menu bars.
- **Panel:** click the item for a panel with two groups, Running and Your turn. Each row has a status dot (green = running, orange = finished in the last 30 minutes, grey ring = idle longer), the session title, its folder and how long it has been working or finished. Clicking a row opens that session in the Claude app (`claude://claude.ai/epitaxy/<id>`). Sessions started in a terminal are listed but can't be opened.
- **Start at login:** a checkbox in the panel. It writes or removes `~/Library/LaunchAgents/com.maheshauti.limbo-tasks.plist`, which has no KeepAlive, so Quit really quits.
- **Source:** only `~/.claude/sessions/<pid>.json`. It never reads the `*.key` files or any transcript.
- **Cost:** no polling. An FSEvents stream wakes it when a session file changes. The panel's views are built when it opens and released when it closes; the only timer is a 30-second tick for the time labels while the panel is open. Measured 13 MB and about 0% CPU with seven live sessions (2026-11-13).
- **Checking the design without the screen:** `limbo-tasks --snapshot out.png [--dark] [--sample]` renders the panel to a PNG.
- **Not yet:** sessions whose process has exited, progress text, and "your next step". Transcripts here run to 176 MB and the end-of-turn recap is often not in the last 400 KB, so reading them needs a proper design first.

## Signals

See [docs/signals.md](docs/signals.md) and [VERIFIED_SIGNALS.md](VERIFIED_SIGNALS.md).

## LaunchAgent (optional)

Example plist: [deploy/com.maheshauti.session-watcher.plist](deploy/com.maheshauti.session-watcher.plist) (commented; install manually on the Mac).

## Module

`github.com/maheshauti/session-watcher`
