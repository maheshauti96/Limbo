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

## Limbo Tasks (Claude sessions, grouped by what they need from you)

A separate, small menu bar app in [tasks/main.swift](tasks/main.swift). It does not need the Go watcher.

```bash
make install-tasks     # build, install ~/Applications/Limbo Tasks.app, start at login, start now
make uninstall-tasks   # remove the app and the login item
make tasks             # build only -> bin/limbo-tasks
```

**Menu bar:** the Claude mark with the number of sessions running, then a speech bubble with the number waiting for you (last 3 days); a check mark when neither. While sessions run, the mark turns once every 3 s. It is taken at run time from the installed Claude app's own menu bar icon (nothing copied here) and rotated by Core Animation, so the app does no work per frame: measured 0.0% app CPU and +0.1 points of WindowServer CPU, against about 5% of a core for swapping pre-drawn frames 8 times a second. It stops while the screens sleep or are locked and stays still with Reduce Motion on. Everything else is one template image, so it follows light and dark menu bars.

**Panel groups**, first rule that matches wins:

| Group | Rule |
|---|---|
| Running | The session's live process says `busy` (`~/.claude/sessions/<pid>.json`). |
| Your turn | The Claude app's own end-of-turn summary (`postTurnSummary` in the session's `local_<id>.json`) is current and says `blocked`, `need_input` or `failed`. The row shows what it needs from you. Questions older than 3 days fold under "older"; older than 7 days drop off. |
| Just finished | The turn has ended but the app has not written its summary yet (usually seconds). |
| Ready for review | The summary says `review_ready`. |
| Done | Anything else from the last 7 days, collapsed. |
| In a terminal | Idle sessions started in a terminal. They have no summary, so they never count as your turn. Collapsed. |

**Keep on top:** the pin button in the panel header opens a small window with the running sessions, the ones waiting for you or ready for review, and ones finished in the last 30 minutes, one line each. It stays above other windows, including full-screen videos and games, on every Space, and never takes keyboard focus. Drag it by its header; the position and whether it was showing are remembered across launches. A menu in its header sets how far back it shows sessions waiting for you: last hour, 4 hours, 24 hours (default), 3 days or 7 days; running sessions always show, and a footer counts the ones hidden as older. Close it with its x or the pin again. Measured while showing: about 30 MB and 0.16 s of CPU per minute (vs 14 MB hidden). Running rows show what the session is doing now, like the Claude app's status line (the current command's description, the file being edited, "Thinking"), and in this window a running clock. That comes from the last 256 KB of the session's transcript, re-read at most once a second when the file changes, and only while the panel or this window is showing: with both closed no transcript is opened. Measured with this window showing and two sessions running: 0.2% of a core (mostly the seconds clocks) and 27 MB; with it hidden, 0%. Running rows have a pulsing green dot and finished ones a green check; the pulse is a Core Animation animation, so the app does no work per frame. WindowServer CPU could not be pinned on the window: across 2026-11-15 runs its own baseline swung between ~16% and ~46% of a core with the screen content, the pulse, blur, shadow and window level each changed it by at most 1-2 points, and in some runs showing any always-on-top window coincided with WindowServer roughly doubling, in others it made no difference. Games that take over the display in exclusive full-screen mode can still cover it.

Archived sessions are hidden. Clicking a row opens it in the Claude app (`claude://claude.ai/epitaxy/<id>`); terminal sessions can't be opened from here.

**Not detectable:** a permission prompt in the middle of a turn. No file on disk records it, so that session shows as Running.

**Sources:** only `~/.claude/sessions/<pid>.json` and `~/Library/Application Support/Claude/claude-code-sessions/<account>/<org>/local_<id>.json`, the latter decoded into a few named fields. It never opens the `*.key` files, transcripts, or other files in those folders (`waiting-input/` holds queued input under the same file names and is skipped by path).

**Cost:** no polling. One FSEvents stream wakes it when a session file changes and only changed files are re-read, on a utility-priority queue. Measured on 2026-11-13 with 55 session records: 0.2 s of CPU at launch, 18 MB before the panel is first opened, 28-31 MB after (one panel is kept and reused; building a new panel per open leaked about 8 MB each time). The first open briefly peaks near 85 MB for about a second. The clock for "3 min ago" labels runs only while the panel is open.

**Checks without the screen:**

```bash
limbo-tasks --dump                                  # group, age and title per row, plus counts
limbo-tasks --snapshot out.png [--dark] [--sample] [--expand] [--rows N]
limbo-tasks --bench-panel 20 [--fresh] [--real]     # memory across panel open/close cycles
kill -USR1 $(pgrep -x limbo-tasks)                  # counts only -> ~/Library/Caches/com.maheshauti.limbo-tasks.stats.json,
                                                    # plus a picture of the menu bar button -> ...limbo-tasks.menubar.png
```

## Signals

See [docs/signals.md](docs/signals.md) and [VERIFIED_SIGNALS.md](VERIFIED_SIGNALS.md).

## LaunchAgent (optional)

Example plist: [deploy/com.maheshauti.session-watcher.plist](deploy/com.maheshauti.session-watcher.plist) (commented; install manually on the Mac).

## Module

`github.com/maheshauti/session-watcher`
