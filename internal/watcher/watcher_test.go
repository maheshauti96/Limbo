package watcher

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/maheshauti/session-watcher/internal/event"
)

func TestRunner_Once_writesStateAndTransitions(t *testing.T) {
	dir := t.TempDir()
	statePath := filepath.Join(dir, "state.json")
	logPath := filepath.Join(dir, "events.jsonl")
	t.Setenv("SESSION_WATCHER_LOG", logPath)

	claudeDir := filepath.Join(dir, "claude-sessions")
	if err := os.MkdirAll(claudeDir, 0o755); err != nil {
		t.Fatal(err)
	}
	session := `{
  "pid": 555001,
  "sessionId": "watchertest123456",
  "cwd": "/tmp/wproj",
  "name": "w-claude",
  "status": "busy"
}`
	if err := os.WriteFile(filepath.Join(claudeDir, "s.json"), []byte(session), 0o644); err != nil {
		t.Fatal(err)
	}

	grokFile := filepath.Join(dir, "active_sessions.json")
	if err := os.WriteFile(grokFile, []byte(`[{"session_id":"gggggggghhhhhhhh","pid":555002,"cwd":"/tmp/g","opened_at":"2026-09-16T10:00:00Z"}]`), 0o644); err != nil {
		t.Fatal(err)
	}

	listing := `
/Applications/Cursor.app/Contents/MacOS/Cursor
/Applications/ChatGPT.app/Contents/Resources/codex app-server
`
	var emitted []event.Event
	tr := event.NewTracker(func(ev event.Event) error {
		emitted = append(emitted, ev)
		return nil
	})

	codexLocks := filepath.Join(dir, "codex-locks")
	if err := os.MkdirAll(codexLocks, 0o755); err != nil {
		t.Fatal(err)
	}
	r := &Runner{
		List:                   func() (string, error) { return listing, nil },
		Tracker:                tr,
		ClaudeDir:              claudeDir,
		ClaudeProjects:         filepath.Join(dir, "claude-projects"),
		GrokFile:               grokFile,
		GrokSessionsDir:        filepath.Join(dir, "grok-sessions"),
		StatePath:              statePath,
		CursorWorkspaceStorage:   filepath.Join(dir, "cursor-ws"),
		CursorConversationSearch: filepath.Join(dir, "no-conversation-search.db"),
		CodexLocksDir:          codexLocks,
		CodexGlobalState:       filepath.Join(dir, "no-codex-global.json"),
		CodexSessionIndex:      filepath.Join(dir, "no-codex-index.jsonl"),
		Alive:                  func(pid int) bool { return pid == 555001 || pid == 555002 },
	}
	if err := r.Once(); err != nil {
		t.Fatal(err)
	}

	data, err := os.ReadFile(statePath)
	if err != nil {
		t.Fatal(err)
	}
	var sf event.StateFile
	if err := json.Unmarshal(data, &sf); err != nil {
		t.Fatal(err)
	}
	if len(sf.Sessions) != 4 {
		t.Fatalf("state sessions=%d data=%s", len(sf.Sessions), data)
	}
	tools := map[string]bool{}
	for _, s := range sf.Sessions {
		tools[s.Tool] = true
		if s.State == "finished" {
			t.Fatalf("finished in state: %#v", s)
		}
	}
	for _, want := range []string{"cursor", "claude", "grok", "codex"} {
		if !tools[want] {
			t.Fatalf("missing tool %s in %#v", want, sf.Sessions)
		}
	}

	if len(emitted) < 4 {
		t.Fatalf("emitted=%#v", emitted)
	}

	// Second once — no new transitions
	n := len(emitted)
	if err := r.Once(); err != nil {
		t.Fatal(err)
	}
	if len(emitted) != n {
		t.Fatalf("expected dedup, got extra %#v", emitted[n:])
	}
}

func TestRunner_detectAll_empty(t *testing.T) {
	empty := t.TempDir()
	r := &Runner{
		List:                   func() (string, error) { return "", nil },
		ClaudeDir:              filepath.Join(empty, "missing"),
		ClaudeProjects:         filepath.Join(empty, "missing-projects"),
		GrokFile:               filepath.Join(empty, "missing.json"),
		CursorWorkspaceStorage: filepath.Join(empty, "cursor-ws"),
		CodexLocksDir:          filepath.Join(empty, "codex-locks"),
		CodexGlobalState:       filepath.Join(empty, "no-global.json"),
		CodexSessionIndex:      filepath.Join(empty, "no-index.jsonl"),
		Alive:                  func(int) bool { return false },
	}
	got := r.detectAll("")
	if len(got) != 0 {
		t.Fatalf("got %#v", got)
	}
}
