# Verified signals (session-watcher)

Copy of [VERIFIED_SIGNALS.md](../VERIFIED_SIGNALS.md) for docs browsing.

Verified on Maheshs-MacBook-Pro.local (2026-09-16 IST). User: maheshauti. HOME: `/Users/maheshauti`.

## Observation model

Every live sighting is `{tool, label, state}` with `state` ∈ `running`|`idle`.
(Legacy synonym: Claude JSON still uses `busy`; detectors emit `running`. Tray accepts `busy` as running during transition.)
The tracker dedups on `(tool, label)` and emits `finished` when a pair disappears.

## Cursor (`tool`: `cursor`)

| Signal | Meaning |
|--------|---------|
| `/Applications/Cursor.app/Contents/MacOS/Cursor` (or exact `Cursor`) | Main present |
| Helpers alone | **Not** a session |
| `cursor-agent` + `worker start` (private workers) | **Not** running — ignore |
| **Primary:** `globalStorage/conversation-search.db` `conversations` (`source=cloud-cache`, `id` LIKE `bc-%`, `is_archived=0`) | Cloud agents + titles |
| `updated_at` (unix ms) ≤48h | Include agent |
| Same `updated_at` ≤**2m** (`ActivityWindow`) | `running`; else `idle` |
| Label = trimmed `title`, else `bc-` + first 8 hex of id; dedup by full bc id | Cloud-agent label |
| **Fallback:** `workspaceStorage/*/workspace.json` + `state.vscdb(-wal)` mtime (only if conversation-search missing/unreadable) | Legacy cloud-agent scan |
| Fallback BusyWindow ≤15m | `running` (wal often stale during Working — do not prefer) |
| `cloudAgentRepository.agents.*` status | **Do not** use |
| `--api-key` / `--token` | Never log (redact) |

Mapping: no main → absent; main, no cloud agents → `idle`/`Cursor`; main + cloud agents → per agent label.

## Claude (`tool`: `claude`)

| Signal | Meaning |
|--------|---------|
| `~/.claude/sessions/*.json` | Session records |
| Fields `pid`, `sessionId`, `cwd`, `name`, `status` | Verified shape |
| `pid` alive (Signal(0) or listing PID) | Live session |
| `status` busy\|idle (Claude JSON) | Emit `running`\|`idle` |
| `name` → basename(cwd) → sessionId[:8] | Label |
| Last `type=user` / `message.role=user` in projects jsonl ≤48h | Recency filter |
| ProjectsDir set + jsonl missing | **Keep** (pid live) |
| jsonl exists + last user >48h | **Drop** |
| `*.key`, `.credentials.json` | **Never read** |
| Claude.app alone | **Not** a coding session |

## Grok-build (`tool`: `grok`)

| Signal | Meaning |
|--------|---------|
| `~/.grok/active_sessions.json` array | Active sessions |
| `{session_id, pid, cwd, opened_at}` | Verified shape |
| `pid` alive | Live session (not enough for `running`) |
| `~/.grok/sessions/<PathEscape(cwd)>/<session_id>/events.jsonl` | Turn signals |
| Last `turn_started` | State `running` |
| Last `turn_ended` / missing events | State `idle` |
| `summary.json` `generated_title` / `session_summary` | Preferred label |
| `opened_at` **or** `last_active_at` within 48h | Recency filter |
| basename(cwd) → session_id[:8] | Label fallback |
| Grok Bot.app alone | **Not** a grok-build session |

## Codex (`tool`: `codex`)

| Signal | Meaning |
|--------|---------|
| `~/.codex/thread-writer-locks/{thread-id}.lock` held (`LOCK_EX` flock) | Running thread |
| Skip `.coordination.lock` | Not a thread lock |
| `thread-titles` → `session_index` `thread_name`; **no** short-id fallback | User-thread label |
| Unlabeled / guardian_review / auto-review prompt-title | **Skip** (subagent, not a user thread) |
| No held locks + `/Applications/ChatGPT.app/Contents/Resources/codex` + `app-server` | Idle Codex |
| `session_index.jsonl` mtime alone | **Do not** use for running |
| Window titles / `auth.json` | **Do not** scrape / read |

## Outputs

- **events.jsonl** — transition log (`running`\|`idle`\|`finished`)
- **state.json** — current live set for the tray (`updated` + `sessions[]`)

Paths: see README. Override with `$SESSION_WATCHER_LOG` / `$SESSION_WATCHER_STATE`.
