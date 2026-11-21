<p align="center"><img src="docs/images/limbo-logo.svg" width="112" alt="Limbo logo: blue, amber and green sessions circling a white centre"></p>

<h1 align="center">Limbo</h1>

<p align="center">macOS menu-bar board for Cursor, Claude, Grok, and Codex sessions.</p>

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

### The problem

With several Claude Code sessions going at once, the Claude desktop app tells you that one has finished, or is waiting for your answer, with nothing more than a small grey dot next to its name in the sidebar. The dot is easy to miss in a long list, and it doesn't say whether the session needs you, finished, or only has new output. So you end up hopping from one session to the next just to see which ones have news, and the one that has been waiting for you sits unnoticed.

<p align="center"><img src="docs/images/limbo-tasks/claude-sidebar-dot.gif" width="370" alt="Claude's sidebar: small grey dots appear next to three sessions, the only sign that they have news"><br><sub>Claude's sidebar (example names): the grey dot is the only sign that a session has news.</sub></p>

### What Limbo Tasks does

A small, separate menu bar app in [tasks/main.swift](tasks/main.swift) that shows every Claude Code session in the Claude desktop app by what it needs from you: what is running and what it is doing, what is waiting for your answer (with Claude's own buttons, so you can answer from it), what is ready for review and what just finished. A window that stays on top shows it at a glance, and its edge glows amber when a session needs you and green when everything has finished, so you can stay in one task and still notice the others. It does not need the Go watcher. All screenshots below use the app's built-in sample sessions (`--sample`).

<p align="center"><img src="docs/images/limbo-tasks/window.png" width="392" alt="The keep-on-top window: Waiting on you cards, then Running, Ready for review, Finished and On hold sections"></p>

```bash
make install-tasks     # build, install ~/Applications/Limbo Tasks.app, start at login, start now
make uninstall-tasks   # remove the app and the login item
make tasks             # build only -> bin/limbo-tasks
```

A stable signing identity keeps macOS's Accessibility permission (used by Answer from Cards) across rebuilds: put `SIGN = <certificate SHA-1>` in `local.mk`, which git ignores. Without it the app is signed ad hoc and macOS forgets the permission after every rebuild.

### Features

| | |
|---|---|
| **Menu bar** | The Claude mark with the number of sessions running and a speech bubble with the number waiting for you. |
| **Menu bar panel** | Every session from the last 7 days in groups: Running, Your turn, Just finished, Ready for review, Snoozed, On hold, Done, In a terminal. |
| **Keep-on-top window** | A small window above everything, full-screen apps included, that never takes the keyboard. |
| **Waiting on you cards** | A session's question and the buttons from Claude's next-step box, with its latest reply one click away. |
| **Answer from Cards** | Click a card's button and Limbo presses it in Claude for you, then puts your screens back. |
| **Tags** | On hold, Awaiting manual review, or your own; four tag styles. |
| **ChatGPT threads** | Codex threads in the ChatGPT app, running or just finished, beside Claude's sessions. |
| **Cursor threads** | Cursor's agent threads, running, waiting on you, or finished, beside Claude's sessions. |
| **Antigravity conversations** | Antigravity's agent conversations, running or finished, beside Claude's sessions. |
| **Snooze** | Put a session away for an hour, three hours or until tomorrow morning; it comes back by itself. |
| **Glows** | A calm rim while sessions run, amber when one needs you, green when everything finishes. |
| **Layouts** | List, Strip, Bar, Dots, Columns or Pill; the strip can take over while an app is full screen. |

#### Menu bar

<img src="docs/images/limbo-tasks/menubar.png" width="91" alt="Menu bar item: 2 running, 2 waiting">

The Claude mark with the number of sessions running, then a speech bubble with the number waiting for you (last 3 days); a check mark when neither. While sessions run, the mark turns once every 3 s (it holds still with Reduce Motion on and stops while the screens sleep). The mark is taken at run time from the installed Claude app's own menu bar icon, so nothing of Claude's is copied into this repo. Click it for the panel.

#### Menu bar panel

<img src="docs/images/limbo-tasks/panel.png" width="380" alt="The menu bar panel: Running, Your turn and Just finished groups">

Every session from the last 7 days, grouped by what it needs from you (the rules are under [Session states](#session-states)). Each row shows the session, what it is doing or asking, its folder (or the session that started it) and how long ago. Click a row to open it in Claude; the pin button opens the keep-on-top window. Done, In a terminal, On hold and questions older than 3 days fold away; Start at login and Quit are at the bottom.

#### Keep-on-top window

The pin in the panel opens a small window with the running sessions, the ones waiting for you or ready for review, and ones finished in the last 2 hours. It stays above other windows, full-screen videos and games included, on every Space, and never takes keyboard focus, so it never interrupts what you type.

- **Sections:** small capital headings with a count and a hairline: Waiting on you, Running, Needs you, Ready for review, Finished, Snoozed, On hold.
- **Look:** the system's glass background, like other macOS windows and alerts, darkened in Dark Mode the way Control Center's panels are (the blurred material before macOS 26), Apple's rounded system font, 16-point corners, a light blue backing behind running sessions, stronger titles for sessions still going, one line per finished session.
- **A mark per state,** told apart by shape as well as colour: a turning blue ring (running), an hourglass (running but nothing written for 10 minutes), an exclamation (needs you), an eye (ready for review), a check (finished), a moon (snoozed), a pause mark (on hold). Every time uses one short style: "4m 12s" ticking for running sessions, "6m", "18h", "now" for the rest.
- **Running sessions** show what they are doing now, like Claude's own status line ("Thinking", the command being run, the file being edited), with a light band sweeping across it. A session between turns that still has background tasks running shows "2 background tasks running" and counts as running.
- **Questions and summaries** show in full, wrapping onto more lines; a running status stays on one line so the row doesn't jump.
- **Count chips filter the list:** click "1 needs you" to list only those sessions, click again for everything.

<p><img src="docs/images/limbo-tasks/filter.png" width="332" alt="The window filtered to sessions that need you, with Showing 1 of 7 and Show all"></p>

- **Time range:** the "24 hr" menu sets how far back it shows sessions waiting for you (1 hour, 4 hours, 24 hours, 3 days, 7 days). Running sessions always show.
- **Size and place:** drag it by its header; resize it from any edge or corner (the resize cursor shows near the border). The position and size are remembered. Right-click the header for Fit to Content and Default Size.

#### Waiting on you cards and replies

When a session's latest turn ended with a question in Claude's next-step box (the box under its last message, with its buttons), the window shows it as a card at the top: the session, the question and the same buttons. Up to 3 cards show, newest first. By default each button opens that session in Claude, where you answer. A question goes away once you send anything to that session.

Rows and cards with a reply have a speech-bubble button: it shows the session's latest reply in place, with Open in Claude for the rest.

<p><img src="docs/images/limbo-tasks/reply.png" width="392" alt="A session's latest reply open under its row"></p>

#### Answer from Cards

Turn it on from the window header's right-click menu (it asks for the Accessibility permission). A card's buttons then answer for you: Limbo presses the same button in Claude.

- **Exact matches only:** it presses only when the question on screen matches the card word for word, the button right after it has exactly that label, Claude shows that exact session, and the button holds still for a moment. On any doubt it presses nothing, opens the session in Claude and says why on the card.
- **Confirmed:** an answer counts as sent only when the transcript gains your message or the box's buttons go away; it presses once more only when the transcript shows nothing arrived, so it never answers twice.
- **In the background when it can:** if Claude already shows that session somewhere on screen, the press happens and nothing moves. Otherwise Claude comes forward for about a second or two (it ignores presses while its window is hidden), and then the window you were in comes back, along with any display that Claude's full-screen Space took over.
- **Fast:** Limbo starts reading Claude's window when the pointer reaches a card, so it is ready by the click. Measured with Claude hidden: the press landed 1.7 to 2 seconds after the click, Claude's own switch included. With Claude already showing the session there is no switch, so it should take about half a second.

#### Tags

Right-click any session (in the window, the panel or on a card) to tag it: **On hold**, **Awaiting manual review**, or your own with **New Tag…** (up to 30 characters). **Remove Tags** clears them.

- **On hold** moves the session to its own On hold section, dimmed with a pause mark. It no longer counts as needing you or ready for review, in the header or the menu bar, and never starts a glow. A running session on hold still shows as running and goes on hold when it stops.
- **Other tags** are labels: under the title, or beside it on a finished row when the whole title fits.
- **Tag style** (right-click the window's header): Outline (default), Filled, Dot and label, or Coloured text.

<table>
<tr><td><b>Outline</b><br><img src="docs/images/limbo-tasks/tag-outline.png" width="392" alt="Outline tags"></td><td><b>Filled</b><br><img src="docs/images/limbo-tasks/tag-filled.png" width="392" alt="Filled tags"></td></tr>
<tr><td><b>Dot and label</b><br><img src="docs/images/limbo-tasks/tag-dot.png" width="392" alt="Dot and label tags"></td><td><b>Coloured text</b><br><img src="docs/images/limbo-tasks/tag-text.png" width="392" alt="Coloured text tags"></td></tr>
</table>

Tags stay until you remove them or archive the session in Claude. They live in Limbo's own settings, so they show only in Limbo; sessions started in a terminal can't be tagged. Typing a new tag opens a small box by the pointer, the one time Limbo takes the keyboard, and the app you were in gets it back on Return or Esc.

#### Which app

Every row starts with the icon of the app its session or thread is in (Claude, ChatGPT, Cursor or Antigravity), with its state on the icon's bottom-right corner, cut out of the icon: the turning blue ring while it runs, a still amber ring once it has written nothing for 10 minutes, the amber "!" when it needs you, a blue dot for review, a green tick when it's done, and a moon or pause sign, with the icon faded, when it's snoozed or on hold. The icons are the installed apps' own, read from macOS (no app's logo is kept in this repo); if an app isn't installed, its rows show the state mark alone. VoiceOver says which app ("…, in Cursor").

#### ChatGPT threads

Codex threads open in the ChatGPT app show beside Claude's sessions, led by ChatGPT's icon: running ones with what they're doing ("Thinking", "Running a command", "Editing files"), and finished ones once their turn ends ("Stopped" when you stopped it). Click one to open it in ChatGPT.

- They are read only while the keep-on-top window or the menu bar panel shows, and the menu bar's counts stay Claude's.
- Only threads you started: Codex's own agents, reviewers and voice sessions are left out. Ordinary ChatGPT chats aren't on disk in a readable form, so they can't show.
- A thread waiting for your approval shows as running: Codex doesn't write that down, the same as Claude's mid-turn permission prompts.
- They can't be tagged or snoozed.

#### Cursor threads

Cursor's agent threads from the last week show, led by Cursor's icon, while Cursor is running: running ones with what Cursor says under them in its own list ("Read Makefile, build.sh", "Edited settings.ts"), ones waiting on you ("Waiting for your approval", "Plan ready to review"), and finished ones from when their run ended. Click one to switch to Cursor: Cursor has no link to one of its own threads (its agent link finds only cloud agents), so it opens wherever you left it.

- They are read only while the keep-on-top window or the menu bar panel shows, and the menu bar's counts stay Claude's.
- Archived threads, subagents' threads and unsent drafts are left out.
- A run that began before Cursor last started was cut short, so it shows as finished.
- They can't be tagged or snoozed.

#### Antigravity conversations

Antigravity's agent conversations from the last week show, led by Antigravity's icon, while Antigravity is running: running ones from your last message, and finished ones from when they last changed ("Stopped" when you stopped one). Click one to switch to Antigravity: its links are its own window's and aren't published, so it opens wherever you left it.

- They are read only while the keep-on-top window or the menu bar panel shows, and the menu bar's counts stay Claude's.
- Subagents' conversations are left out.
- A run whose last change came before Antigravity last started was cut short, so it shows as finished.
- A conversation waiting for your approval shows as running: Antigravity's list doesn't say so.
- They can't be tagged or snoozed.

#### Snooze

Snooze a session that needs you (or is ready for review, or asked you something) when you don't want to deal with it yet: **For 1 Hour**, **For 3 Hours** or **Until Tomorrow Morning** (9:00). Pick it from the session's right-click menu, anywhere it shows, or from the **Snooze 1h 3h Tomorrow** buttons under a card in the strip, the bar and the dots.

- A snoozed session moves to its own Snoozed section, dimmed with a moon and when it wakes ("Until 8:02 PM"). It no longer counts as needing you, in the header or the menu bar, and never starts a glow. The strip, the bar and the dots show a moon with how many are snoozed; its menu wakes one, or all, or opens one in Claude.
- It wakes on its own at that time, back where it was; one that needs you glows amber again, as if it had just asked. It wakes early if the session moves on: you answer it, or it ends another turn. **Wake Now** in its right-click menu brings it back at once.
- Snoozes live in Limbo's own settings, like tags; sessions started in a terminal can't be snoozed.

#### Glows

The window's edge tells you the state from the corner of your eye. The sparkle menu in its header picks the effect and colour.

<table>
<tr><td><b>Needs you</b><br><img src="docs/images/limbo-tasks/needs-you.png" width="332" alt="Amber rim: a session needs you"></td><td><b>All finished</b><br><img src="docs/images/limbo-tasks/all-finished.png" width="332" alt="Green rim and an All finished chip"></td></tr>
<tr><td><b>Aurora drift</b> (one of the other effects)<br><img src="docs/images/limbo-tasks/aurora.png" width="332" alt="Aurora drift glow"></td><td><b>Pill</b><br><img src="docs/images/limbo-tasks/pill.png" width="175" alt="The window shrunk to a pill with its counts"></td></tr>
</table>

- **Calm rim** (default, shown at the top): while a session runs, a thin ring and a top edge in the glow colour breathe slowly, with nothing moving behind the text.
- **Needs you:** while a session that started waiting for you in the last hour has not been opened (from Limbo or in Claude), the rim turns amber. A Got it button stops it without opening anything.
- **All finished:** when the last running session stops, the rim turns green until a session runs again or you open one. The green "All finished" chip in the header is its Got it.
- **Other effects:** Aurora drift, Ember breath, Corner bloom, Tide sweep, Rising warmth, Heartbeat, Random (a new one every 5 seconds) or No glow, in red, orange, rose or green. A new choice plays for 4 seconds so you can see it. The amber and green signals each have an on/off switch in the same menu.
- **Pill:** double-click the header's empty middle (or right-click it, Shrink to Pill) to shrink the window to just its counts and glow; double-click the pill to expand it.

#### Layouts

The layout button in the window's header (and the right-click menu of the layouts without a header) picks the window's shape. The horizontal ones fit in the black bar above or below a widescreen movie, so they never cover what you're watching:

- **List** (default): the window above.
- **Strip:** one line of chips, one per session (running, waiting, then ready for review, at most six), with how long ago, and finished ones as a count. Point at a chip for its card (its question and buttons, or its row) underneath, or above it in the lower half of the screen; click to open it.
- **Bar:** a thin bar across the whole bottom of the screen, with what running sessions are doing and the first tag of the others. Cards open above it.
- **Dots:** the smallest: one mark per session, in groups. Point at one for its card.
- **Columns:** wide and short, with Running, Needs you and Finished side by side; drag its sides to resize it.
- **Pill:** just the counts.

Double-click the Limbo mark (or the bar's empty part) to go back to the list. **Strip while an app is full screen**, in the same menu, swaps the list or the columns for the strip whenever an app is full screen on the window's display, and puts your layout back when it leaves full screen; pick a layout while full screen and it stays until then. The app is taken to be full screen when its display shows a full-screen Space (or a window covers the whole display, as a game's does), so it works for videos in a browser or a player alike.

#### Light mode and accessibility

<img src="docs/images/limbo-tasks/light.png" width="392" alt="The window in light mode">

In light mode the glow colours are deepened and the greys darkened so they pass contrast. With Increase Contrast on, the glow becomes a steady 2-point ring, borders turn solid and text gets bolder. With Reduce Motion on, the ring, the status band and every glow hold still. With Reduce Transparency on, the window has a solid background. Rows and buttons have VoiceOver labels.

### How it works

#### Session states

Panel groups, first rule that matches wins:

| Group | Rule |
|---|---|
| Running | The session's live process says `busy` (`~/.claude/sessions/<pid>.json`), or it is between turns with background tasks still running. |
| Your turn | The Claude app's own end-of-turn summary (`postTurnSummary` in the session's `local_<id>.json`) is current and says `blocked`, `need_input` or `failed`, or the session stopped with an error in the last 7 days. The row shows what it needs from you. Questions older than 3 days fold under "older"; older than 7 days drop off. |
| Just finished | The turn has ended but the app has not written its summary yet (usually seconds). |
| Ready for review | The summary says `review_ready`, and you have not opened the session in Claude since its turn ended (the record's `lastFocusedAt`, which Claude sets each time the session comes into view). Once you have, it counts as done. A session that finishes while you are already looking at it stays here until it next comes into view. |
| Snoozed | You snoozed it, and its time hasn't come and it hasn't moved on since (and it is not running). |
| On hold | You tagged it On hold (and it is not running). |
| Done | Anything else from the last 7 days, collapsed. |
| In a terminal | Idle sessions started in a terminal. They have no summary, so they never count as your turn. Collapsed. |

Archived sessions are hidden. Clicking a row opens it in the Claude app (`claude://claude.ai/epitaxy/<id>`); terminal sessions can't be opened from here. **Not detectable:** a permission prompt in the middle of a turn. No file on disk records it, so that session shows as Running.

#### What it reads

- `~/.claude/sessions/<pid>.json`: the live Claude Code processes.
- `~/Library/Application Support/Claude/claude-code-sessions/<account>/<org>/local_<id>.json`: each desktop session's record, decoded into a few named fields (title, folder, turn times, end-of-turn summary, `lastFocusedAt`); the rest of the file is never kept. `waiting-input/` (queued input under the same file names) is skipped by path.
- The last 256 KB of each recent session's transcript (`~/.claude/projects/<folder>/<id>.jsonl`), only while the panel or the window is showing: what a running session is doing now, how its latest turn ended (the next-step box's question and buttons) and its latest reply. Re-read at most once a second while a session runs, and otherwise only when that transcript changes.
- Background tasks: the session's own child shells (via `libproc`). A Bash command left running holds a file ending `.output` under `<session>/tasks/` open; a monitor streams to Claude instead, so it counts as a shell Claude started (its command sources one of Claude's `~/.claude/shell-snapshots/`) that holds no such file. File names, and whether a shell's command has that marker; never file contents, and nothing else of the command.
- A running session that has written nothing for 10 minutes (its transcript, its agents' transcripts under `<session>/subagents`, its workflow files under `<session>/workflows`) gets the hourglass and "No output for 12 min": it may be stuck, or in one long command.
- ChatGPT's Codex threads, only while the panel or the window is showing: which rollout files (`~/.codex/sessions/…/rollout-…-<id>.jsonl`) the ChatGPT app's Codex server holds open (via `libproc`, every 2 s), the first 16 KB of each once (its folder, and whether you started it), then only the lines it gains, checking the start of each for a turn starting or ending and the kind of step. Names come from `~/.codex/session_index.jsonl`, read again only when it changes. It looks for ChatGPT's Codex server every 10 s while none is running, and every 30 s otherwise. On this Mac a check with nothing new takes under 0.1 ms, looking for the server about 2 ms, and the first read of two open threads about 110 ms (`--codex-bench`).
- Cursor's agent threads, only while the panel or the window is showing and Cursor is running: a stat every 2 s of Cursor's state database (`~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`) and its write-ahead log, and, only when one of them changed (about every 15 s while Cursor works), one indexed query on its small list of threads (`composerHeaders`: name, folder, the line Cursor shows under it, whether a run is going or waits for approval). The database is opened read-only and closed straight after each query, so no read is left open while Cursor writes. Conversations themselves are never read. It looks for Cursor every 10 s while it isn't running, and every 30 s otherwise. On this Mac a tick with nothing new takes about 0.004 ms and a read of the list about 0.2 ms (`--cursor-bench`).
- Antigravity's agent conversations, only while the panel or the window is showing and Antigravity is running: a stat every 2 s of its list of conversations (`~/.gemini/antigravity/conversation_summaries.db`) and that database's write-ahead log, and, only when one of them changed, one query on it (title, folder, run status, when it last changed and when you last wrote). It's opened read-only and closed straight after; when Antigravity has the database closed, its log is gone and the file itself is current, so it's read then as a snapshot that takes no lock. Conversations themselves are never read. On this Mac a tick with nothing new takes about 0.003 ms and a read about 0.3 ms (`--antigravity-bench`).
- It never opens the `*.key` files, and never changes Claude's, ChatGPT's, Cursor's or Antigravity's files.

Limbo's own settings (tags, glow, tag style, window size and place, time range) are in its defaults domain, `com.maheshauti.limbo-tasks`; tags are kept by session id under `sessionTags`, snoozes under `sessionSnoozes`.

#### Answer from Cards, step by step

1. Limbo turns on Claude's accessibility tree (Chromium builds it only when asked) from when the pointer reaches a card until 12 seconds after the last answer, and turns it off again at quit.
2. On a click it notes the app and window you were in and what each display shows.
3. If Claude shows that session and some of its window is on screen, it presses there. Otherwise it opens the session through its link (which brings Claude forward) and waits until Claude has been in front for a second, since Claude ignores a press made sooner after switching.
4. It finds the newest copy of the question that has the button right after it, waits until that button stays the same element (a tenth of a second when Claude already showed the session), and presses it.
5. It checks the transcript every 0.1 s for your message (or the buttons going away). Nothing in 1.5 s and the button still there: one more press.
6. It raises the window that was in front on any display Claude's full-screen Space took over (macOS then slides that display back), then the window you were in, through Accessibility, and checks that your app is in front. If you were reading another session in Claude, Claude goes back to it.

The steps of the last answer, with the time of each since the click and no message text, are in `~/Library/Caches/com.maheshauti.limbo-tasks.answer.log`. The current-Space and window-number calls are private and read through `dlsym`; without them the displays are left as they are.

#### Keyboard focus and the cursor

The window is a non-activating panel that can never become the key window, so it never takes the keyboard from a game or a video. macOS shows cursor changes only from the frontmost app, which this window never makes Limbo; the resize cursors still show because, while the pointer is on an edge, Limbo turns on the window server's private `SetsCursorInBackground` setting, and turns it off again (after putting the arrow back) when the pointer leaves. The New Tag box is a separate panel that can take the keyboard without making Limbo the app in front.

#### Cost

- **No polling.** One FSEvents stream wakes the app when a session file changes, and only changed files are re-read, on a utility-priority queue.
- **Animations run in the window server.** The menu bar mark, the running ring, the status band and every glow are Core Animation layers animated at 15-30 fps, so the app does no work per frame. A profile with Aurora running found its main thread busy in 15 of about 7,000 samples, all of it the once-a-second stopwatch.
- **Measured:** 0.2 s of CPU at launch with 55 session records; 18 MB before the panel is first opened, 28-31 MB after (one panel is kept and reused; building a new panel per open leaked about 8 MB each time). With the window showing and two sessions running: about 0.2% of a core and 27-30 MB; with it hidden, 0%. Random switching every 5 seconds used 7 ms of CPU in 17 s. WindowServer's own CPU swings too much with screen content to pin any change on the window.
- Games that take over the display in exclusive full-screen mode can still cover the window.

#### Checks without the screen

```bash
limbo-tasks --dump                                  # group, age and title per row, plus counts
limbo-tasks --snapshot out.png [--dark] [--sample] [--expand] [--rows N]
limbo-tasks --snapshot out.png --floating [--glow calm|aurora|ember|corners|tide|rise|heartbeat] [--tint red|orange|rose|green] [--phase 1.5]
limbo-tasks --snapshot out.png --floating --attention | --flash | --done [--phase 0.7]   # amber, green flash, all finished
limbo-tasks --snapshot out.png --floating --size 440x260 | 440xauto              # the keep-on-top window at a size
limbo-tasks --snapshot out.png --floating [--mini] [--filter running|needsYou|review] [--contrast] [--solid]
limbo-tasks --snapshot out.png --floating --layout strip|bar|dots|columns [--hover local_s1]   # --size 1400 for the bar's width
limbo-tasks --snapshot out.png --floating --response local_s7 [--live] [-tagStyle outline|filled|dot|text]
limbo-tasks --glow-cycle 16                         # Random in an offscreen window: effect each second, then CPU used
limbo-tasks --gesture-check                         # chips, cards, replies, snooze, the New Tag box, close, pill, layouts (off screen)
limbo-tasks --resize-check                          # dragging the edges, and never becoming the front app
limbo-tasks --self-test                             # states, tags, snoozes, glow decisions, cards, answers, background tasks, ChatGPT, Cursor and Antigravity threads
limbo-tasks --bench-panel 20 [--fresh] [--real]     # memory across panel open/close cycles
limbo-tasks --codex-bench                           # what reading ChatGPT's threads costs, on this Mac's open threads
limbo-tasks --cursor-bench                          # what reading Cursor's threads costs, on this Mac's Cursor
limbo-tasks --antigravity-bench                     # what reading Antigravity's conversations costs, on this Mac
kill -USR1 $(pgrep -x limbo-tasks)                  # counts only -> ~/Library/Caches/com.maheshauti.limbo-tasks.stats.json,
                                                    # a picture of the menu bar button -> ...limbo-tasks.menubar.png,
                                                    # and the glow's state (effect, active, animating, size) -> ...limbo-tasks.glow.json
```

The screenshots in this README are made with `--snapshot … --sample`; `-tagStyle` and `-runningGlow` set those settings for one run.

## Signals

See [docs/signals.md](docs/signals.md) and [VERIFIED_SIGNALS.md](VERIFIED_SIGNALS.md).

## LaunchAgent (optional)

Example plist: [deploy/com.maheshauti.session-watcher.plist](deploy/com.maheshauti.session-watcher.plist) (commented; install manually on the Mac).

## Module

`github.com/maheshauti/session-watcher`
