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
| Ready for review | The summary says `review_ready`, and you have not opened the session in Claude since its turn ended (the record's `lastFocusedAt`, which Claude sets each time the session comes into view). Once you have, it counts as done. A session that finishes while you are already looking at it stays here until it next comes into view. |
| Done | Anything else from the last 7 days, collapsed. |
| In a terminal | Idle sessions started in a terminal. They have no summary, so they never count as your turn. Collapsed. |

**Background work:** a session between turns that still has background tasks running (commands Claude left running, monitors) shows as running, with "2 background tasks running" as its status, not as done or ready for review; one asking you something still needs you. Limbo counts the tasks' output files (…/<session>/tasks/<id>.output) held open by the session's own child shells: a few system calls per idle session, no process started. A finished task wakes its session, which updates its record, so the row changes without polling.

**Keep on top:** the pin button in the panel header opens a small window with the running sessions, the ones waiting for you or ready for review, and ones finished in the last 2 hours. A question or summary under a row shows in full, wrapping onto more lines (in the menu bar panel too); a running session's status stays on one line, so the row does not jump as it changes. It stays above other windows, including full-screen videos and games, on every Space, and never takes keyboard focus. Drag it by its header; the position and whether it was showing are remembered across launches. Resize it from any edge or corner (the resize cursor shows in a thin band inside the border): a side edge changes only the width, so the height keeps fitting the rows; the top or bottom edge, or a corner, sets the height too, and then every row in the chosen time range shows in a scrolling list. The size is remembered. Right-click the header for Fit to Content (the height follows the rows again) or Default Size (300 points wide). Rows that open a session ask for the pointing hand (SwiftUI's link pointer). In the menu bar panel it shows, since opening the panel makes Limbo Tasks the frontmost app. In this window it usually does not: macOS shows cursor changes only from the frontmost app, and this window never makes Limbo Tasks frontmost so it never takes keyboard focus from a game or video. The resize cursors do show: while the pointer is on an edge (or dragging one) the app turns on the window server's private SetsCursorInBackground setting, and turns it off again, after putting the arrow back, when the pointer leaves (checked 2026-11-16 with another app in front; an earlier check that found it had no effect was wrong). **Waiting on you:** when a session's latest turn ended with a question in its next-step box (the box under Claude's last message, with its buttons), the window shows it as a card at the top: the session, the question and the same buttons. Up to 3 cards show, newest first; any more stay rows with the question as their second line. By default each button opens that session in Claude, where you answer: Claude offers no way for another app to send an answer (its session links carry no message, and it runs no local API). With **Answer from Cards** on (right-click the window's header; it asks for the Accessibility permission), a button answers for you instead: Limbo Tasks opens the session in Claude, waits for its next-step box, and presses the button through macOS Accessibility only when the question on screen matches the card word for word, the button right after it has exactly that label, Claude's page address shows that exact session (another session can ask the very same question, such as "Commit and push this change?"), and the button stays the same element for a moment (a tenth of a second when Claude already shows the session, half a second after switching to it). It counts the answer as sent only when the box's buttons go away or the session's transcript gains your message, presses once more only when the transcript shows nothing arrived, and then puts the window you were in back in front (through Accessibility, so macOS also switches back to its Space; a plain request from a background app to open another can be ignored), and checks that it is. A display that Claude's full-screen Space took over goes back to the Space it showed: Limbo notes each display's Space and front window at the click and raises that window again (the window server's current-Space call is private, read through dlsym; without it nothing is restored). The steps of the last answer, without message text, are in `~/Library/Caches/com.maheshauti.limbo-tasks.answer.log`. On any doubt it presses nothing, leaves the session open in Claude, and says why on the card for a few seconds. Claude acts on a press only while its window is visible: behind other windows, or on a hidden full-screen Space, its page is paused. So if Claude already shows that session and some of its window is on screen (say, on another display), the press happens in the background and nothing moves. Otherwise Claude comes to the front (its session link always brings it forward, even when opened in the background; a full-screen Claude means a slide to its Space), the press happens, and the window you were in comes back. Answers happen without Claude moving only while some of its window is on screen: a full-screen Claude on a Space you aren't looking at has to come forward for a moment. A background press that does not land falls back to that. If you were reading another session in Claude, Claude goes back to it after the answer. Claude's window builds its accessibility tree only around an answer: from when the pointer reaches a card (so the tree is ready by the click) until 12 seconds after. Reading the window takes about 0.15 s, and the transcript is checked every 0.1 s after a press; the answer log gives each step's time since the click. The buttons show an arrow when they only open the session. A question disappears once you send anything to that session. Rows and cards with a reply have a speech-bubble button on the right: it shows the session's latest reply in place (about a dozen lines; code blocks left out, links to local files shown as their name), with Open in Claude for the rest. This comes from the tail of each recent session's transcript (the next-step box is saved there), read only while this window or the panel is showing, and again only when that transcript changes (a stat per session when its record changes, and every 30 s). A menu in its header sets how far back it shows sessions waiting for you: last hour, 4 hours, 24 hours (default), 3 days or 7 days; running sessions always show, and sessions older than the choice are simply not shown (widen the choice to see them). Close it with its x or the pin again. Its header shows the counts as chips (2 running, 1 needs you, 1 to review); click one to list only those sessions ("Showing 1 of 5 · Show all" underneath), click it again to show everything. When the window is too narrow the chips shrink to a mark and a number. While the window glows amber (needs you) or green (all finished), a Got it button in the header stops the glow without opening anything. Each state has its own mark, told apart by shape as well as colour: a turning blue ring (running), an hourglass (running but quiet), an exclamation (needs you), an eye (ready for review) and a check (finished); and every time uses one short style ("4m 12s" ticking for running sessions, "6m", "18h", "now" for the rest). While a running glow moves, a soft band behind the text keeps it readable. Double-click the header's empty middle (or right-click the header, Shrink to Pill) to shrink the window to a pill with just the counts and the glow; double-click the pill to expand it. It stays in its corner when it shrinks. In light mode the glow colours are deepened and the greys and marks darkened so they pass contrast; with Increase Contrast on, the moving glow becomes a steady 2-point ring in the same colour, the border turns solid and text gets brighter and bolder; with Reduce Transparency on, the window has a solid background. Measured while showing: about 30 MB and 0.16 s of CPU per minute (vs 14 MB hidden). While any session runs, colour comes in from the window's edges, behind the rows and with no border line; it disappears the moment no session runs, so the end of the work is easy to notice, even from the corner of your eye. The sparkle menu in the window's header picks the effect: Aurora drift (default: red, coral and rose turning slowly around the edges, once every 4 s), Ember breath (an edge glow that brightens and dims every 2.4 s), Corner bloom (light blooming from each corner in turn), Tide sweep (a wash of colour sweeping across over a faint edge glow), Rising warmth (warmth rising from the bottom edge), Heartbeat (two beats and a rest), Random (a different effect every 5 seconds, cross-fading), or No glow; and the colour: red (default), orange, rose or green. A new choice plays for 4 seconds even when nothing runs, so you can see it. Two more signals, each with an on/off switch in the same menu (both on by default): when the last running session stops, a green glow sweeps across the window and then the whole window stays green (a translucent green behind the rows, a little stronger at the edges, breathing slowly) until a session runs again or you open a session from the panel or this window, so finished work does not go unnoticed; and while a session that started waiting for you in the last hour has not been opened since (from the panel, this window or the Claude app), a slow amber breath replaces the running glow, because it needs action. Opening that session, the session moving on, or the hour passing ends it. With Reduce Motion on, each effect is a steady glow and Random keeps one. The effects are Core Animation layers (edge images a few kilobytes in size that stretch to any window size, plus gradient layers), animated at 15-30 fps by the window server, so the app does no work per frame: a profile of the app with Aurora running found its main thread busy in 15 of about 7,000 samples, all of it the once-a-second stopwatch. Random switching every 5 seconds used 7 ms of CPU in 17 s (`--glow-cycle`). Running rows show what the session is doing now, like the Claude app's status line (the current command's description, the file being edited, "Thinking"), and in this window a running clock. That comes from the last 256 KB of the session's transcript, re-read at most once a second when the file changes, and only while the panel or this window is showing: with both closed no transcript is opened. A running session that has written nothing for 10 minutes (its transcript, its agents' transcripts under `<session>/subagents` and its workflow files under `<session>/workflows`, the last two checked every 30 s) shows an amber hourglass instead of the turning ring and "No output for 12 min" before what it was last doing: it may be stuck, or in one long command. Measured with this window showing and two sessions running: 0.2% of a core (mostly the seconds clocks) and 27 MB; with it hidden, 0%. Running rows have a turning blue ring (blue so it never reads as the green of finished) and, in this window, a light band sweeping across their status line, like Claude's own "Thinking"; finished ones a green check. Both are Core Animation animations (the ring's arc turns once a second; the band is a gradient mask moving over a brighter copy of the text), animated at 15-30 fps by the window server, so the app does no work per frame. With Reduce Motion on, the ring and the text hold still. WindowServer CPU could not be pinned on the window: across 2026-11-15 runs its own baseline swung between ~16% and ~46% of a core with the screen content, the pulse, blur, shadow and window level each changed it by at most 1-2 points, and in some runs showing any always-on-top window coincided with WindowServer roughly doubling, in others it made no difference. Games that take over the display in exclusive full-screen mode can still cover it.

Archived sessions are hidden. Clicking a row opens it in the Claude app (`claude://claude.ai/epitaxy/<id>`); terminal sessions can't be opened from here.

**Not detectable:** a permission prompt in the middle of a turn. No file on disk records it, so that session shows as Running.

**Sources:** only `~/.claude/sessions/<pid>.json` and `~/Library/Application Support/Claude/claude-code-sessions/<account>/<org>/local_<id>.json`, the latter decoded into a few named fields. It never opens the `*.key` files, transcripts, or other files in those folders (`waiting-input/` holds queued input under the same file names and is skipped by path).

**Cost:** no polling. One FSEvents stream wakes it when a session file changes and only changed files are re-read, on a utility-priority queue. Measured on 2026-11-13 with 55 session records: 0.2 s of CPU at launch, 18 MB before the panel is first opened, 28-31 MB after (one panel is kept and reused; building a new panel per open leaked about 8 MB each time). The first open briefly peaks near 85 MB for about a second. The clock for "3 min ago" labels runs only while the panel is open.

**Checks without the screen:**

```bash
limbo-tasks --dump                                  # group, age and title per row, plus counts
limbo-tasks --snapshot out.png [--dark] [--sample] [--expand] [--rows N]
limbo-tasks --snapshot out.png --floating [--glow aurora|ember|corners|tide|rise|heartbeat] [--tint red|orange|rose|green] [--phase 1.5]
limbo-tasks --snapshot out.png --floating --attention | --flash | --done [--phase 0.7]   # amber glow, green flash, green window
limbo-tasks --glow-cycle 16                         # Random in an offscreen window: effect each second, then CPU used
limbo-tasks --snapshot out.png --floating --size 440x260 | 440xauto              # the keep-on-top window at a size
limbo-tasks --snapshot out.png --floating [--mini] [--filter running|needsYou|review] [--contrast] [--solid]
limbo-tasks --gesture-check                         # chips, close, double-click to the pill and back, glow kept (off screen)
limbo-tasks --self-test                             # glow decisions, needs-you and quiet rules, agent files, resize math
limbo-tasks --bench-panel 20 [--fresh] [--real]     # memory across panel open/close cycles
kill -USR1 $(pgrep -x limbo-tasks)                  # counts only -> ~/Library/Caches/com.maheshauti.limbo-tasks.stats.json,
                                                    # a picture of the menu bar button -> ...limbo-tasks.menubar.png,
                                                    # and the glow's state (effect, active, animating, size) -> ...limbo-tasks.glow.json
```

## Signals

See [docs/signals.md](docs/signals.md) and [VERIFIED_SIGNALS.md](VERIFIED_SIGNALS.md).

## LaunchAgent (optional)

Example plist: [deploy/com.maheshauti.session-watcher.plist](deploy/com.maheshauti.session-watcher.plist) (commented; install manually on the Mac).

## Module

`github.com/maheshauti/session-watcher`
