package event

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestEventSchema(t *testing.T) {
	ev := New("cursor", "Cursor", "idle")
	b, err := json.Marshal(ev)
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]string
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatal(err)
	}
	for _, k := range []string{"tool", "label", "state", "ts", "source"} {
		if m[k] == "" {
			t.Errorf("missing or empty %q in %s", k, b)
		}
	}
	if m["source"] != "session-watcher" {
		t.Errorf("source=%q", m["source"])
	}
	if len(m) != 5 {
		t.Errorf("extra fields: %v", m)
	}
}

func TestResolveLogPath_env(t *testing.T) {
	t.Setenv("SESSION_WATCHER_LOG", "/tmp/sw-test-events.jsonl")
	if got := ResolveLogPath(); got != "/tmp/sw-test-events.jsonl" {
		t.Fatalf("got %q", got)
	}
}

func TestEmitter_writesJSONL(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "events.jsonl")
	t.Setenv("SESSION_WATCHER_LOG", path)

	em, err := NewEmitter()
	if err != nil {
		t.Fatal(err)
	}
	if em.LogPath() != path {
		t.Fatalf("LogPath=%q", em.LogPath())
	}

	// redirect stdout capture via pipe would be heavy; just check file append
	ev := Event{Tool: "cursor", Label: "Cursor", State: "idle", TS: "2026-09-16T00:00:00Z", Source: Source}
	if err := em.Emit(ev); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var decoded Event
	if err := json.Unmarshal(data[:len(data)-1], &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded != ev {
		t.Fatalf("got %#v want %#v", decoded, ev)
	}
}
