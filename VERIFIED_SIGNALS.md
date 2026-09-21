# Verified on Maheshs-MacBook-Pro.local (2026-09-16 IST)

User: maheshauti
HOME: /Users/maheshauti

## Cursor

Process:
- Main binary running: `/Applications/Cursor.app/Contents/MacOS/Cursor` (pgrep -x Cursor / this path)
- Helper processes under Cursor.app (do not treat helpers alone as a session)

Private workers (NOT user-active):
- Long-lived `cursor-agent … worker start` with `--label cursor.private_worker…` sit at ~0% CPU for hours
- Verified 2026-09-16: these are **false running** — do **not** emit running from private `worker start` processes
- NEVER log `--api-key` or any argv secrets (redact if argv is logged)

Cloud agents (user-active threads) — primary: conversation-search.db (verified 2026-09-16 ~17:45 IST):
- Path: `~/Library/Application Support/Cursor/User/globalStorage/conversation-search.db` (+ `-wal`/`-shm`)
- Table `conversations`: `source='cloud-cache'`, `id` LIKE `bc-%`, `is_archived=0`, `updated_at` within 48h (`recency.Window`; unix **milliseconds**)
- Label: trimmed `title` if non-empty, else `bc-` + first 8 hex chars of id
- State: `running` if `updated_at` within **2 minutes** (`ActivityWindow`); else `idle`
- Dedup by full bc id; sort by label
- Read-only: copy db+wal+shm to temp; never write the live DB. Never use `cloudAgentRepository.agents.*` `status`/`workflowStatus` (all were `2` even for archived)

Fallback only (conversation-search missing/unreadable):
- Scan `~/Library/Application Support/Cursor/User/workspaceStorage/*/workspace.json`
- `folder` URI (URL-decoded) must contain `background-composer` and a `bc-` id
- Include only if `state.vscdb-wal` mtime (or `state.vscdb` if no wal) is within 48h
- Label: `bc-` + first 8 hex chars of the bc uuid
- State: `running` if DB mtime within **15 minutes** (`BusyWindow`); else `idle`
- **Note:** wal mtime often does **not** update during cloud-agent work (FE+BE wal was 18m stale while IDE Working) — hence conversation-search is primary

State mapping:
- no Cursor main process → emit `finished` once when transitioning from present→absent; otherwise stay quiet
- Cursor main present, no cloud-agent observations → `idle` (label `Cursor`)
- Cursor main present + ≥1 cloud agent → one observation per agent (running|idle as above)
- stuck/waiting: not mapped (no verified signal yet)

Do **not** use workspaceStorage alone for running when conversation-search is available.
Agent transcripts under `~/.cursor/projects/*/agent-transcripts/**/*.jsonl` are often stale — do not use mtime alone for running.

## Claude

Files (only):
- Read `~/.claude/sessions/*.json`
- Forever skip `*.key`, `.credentials.json`, `credentials.json`, and other non-session files
- JSON fields observed: `pid`, `sessionId`, `cwd`, `name`, `status` (`busy`|`idle`) — Claude still stores `busy`; limbo emits `running`

Liveness:
- Session is live only if `pid` is currently alive (`os.FindProcess` + `Signal(0)` / kill(pid,0), with process-listing PID column as fallback)

Label: `name` if non-empty, else basename(`cwd`), else `sessionId[:8]`

State: map Claude JSON `busy` → emitted `running`; `idle` → `idle`; ignore unknown statuses

Do **not** treat Claude.app alone as a coding session.

Recency (2026-09-16): hide Claude sessions whose last `type=user` / `message.role=user` event in `~/.claude/projects/<cwd-encoded>/<sessionId>.jsonl` is older than 48h (Brand Mentions last user 2026-09-09 while the process was still idle-open). If ProjectsDir is set and the jsonl is missing → keep (pid live). If jsonl exists and last user >48h → drop.

## Grok-build (`tool`: `grok`)

Files (only):
- Read `~/.grok/active_sessions.json` — array of `{session_id, pid, cwd, opened_at}`
- Session dir: `~/.grok/sessions/<url-PathEscape(cwd)>/<session_id>/` (fallback: replace `/` with `%2F` if PathEscape differs)
- `events.jsonl` types: `turn_started` / `turn_ended`
- Optional `summary.json`: `generated_title`, `session_summary`, `last_active_at`

Liveness: `pid` alive (same as Claude). **Pid alive ≠ running.**

State rule (verified 2026-09-16):
- Scan `events.jsonl` from the end for the last `turn_started` or `turn_ended`
- Last is `turn_started` → emitted state `running`
- Last is `turn_ended`, none, or missing `events.jsonl` → `idle` (do not invent running)

Label: `summary.json` `generated_title` or `session_summary`, else basename(`cwd`), else `session_id[:8]` (truncate long titles)

Recency: keep if `opened_at` **or** `summary.json` `last_active_at` is within 48h (`recency.Window`); whichever parseable and recent wins. No timestamps → keep (pid live).

Do **not** treat Grok Bot.app alone as a grok-build session.

## Codex

Running (thread-writer flock):
- Dir: `~/.codex/thread-writer-locks/`
- Files: `{thread-id}.lock` (often empty). Skip `.coordination.lock`.
- Running iff another process holds an exclusive flock (`LOCK_EX|LOCK_NB` fails with `EWOULDBLOCK` / `EAGAIN`).
- Verified 2026-09-16: `codex` pid 2813 held **two** locks while the UI showed **one** Working thread (`CRSR BQ Data Gap Check (4)` / `01a07c5a-…`). The extra lock `01a0a9e9-…` is a **guardian auto-review subagent** (`state_5.sqlite` `threads.thread_source=guardian_review`, `model=codex-auto-review`, no `name`, title is the review prompt dump). Skip it.

Label (in order):
1. `thread-titles.titles[thread-id]` from `~/.codex/.codex-global-state.json` (or flat `thread-titles[thread-id]`)
2. else `thread_name` for matching `id` in `~/.codex/session_index.jsonl` (last line wins)
3. **no short-id fallback** — unlabeled locks are subagents, not user threads
4. Reject titles >120 chars or containing `codex agent history whose request action` / `>>> transcript start`

Do **not** treat `state_5.sqlite` `thread_source=guardian_review` / `source.subagent` rows as user sessions.

Idle:
- No held locks, but process listing contains `/Applications/ChatGPT.app/Contents/Resources/codex` **and** `app-server`
- → Observation `{tool:codex, label:"Codex", state:idle}`

Absent: neither held locks nor verified app-server → nil

Do **not** invent running from `session_index.jsonl` mtime alone (often days old).
Do **not** scrape window titles.
Never read `auth.json` / secrets.


## Snapshot + events (tray)

On every poll (`once` / each `watch` tick):
- Write live set atomically to `~/Library/Application Support/session-watcher/state.json`
  (or `$SESSION_WATCHER_STATE`, or `./state.json` if no `~/Library`)
- Append transitions to `events.jsonl` (`finished` when a `(tool,label)` disappears)

`state.json` sessions = **current live observations only** (no finished rows).

## Forever policy

- No webhooks / HTTP server
- No secrets in logs or state files (redact argv; never read credential/key files)
