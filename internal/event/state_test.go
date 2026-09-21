package event

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/maheshauti/session-watcher/internal/obs"
)

func TestResolveStatePath_env(t *testing.T) {
	t.Setenv("SESSION_WATCHER_STATE", "/tmp/sw-test-state.json")
	if got := ResolveStatePath(); got != "/tmp/sw-test-state.json" {
		t.Fatalf("got %q", got)
	}
}

func TestWriteState_atomicLiveOnly(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "state.json")
	t.Setenv("SESSION_WATCHER_STATE", path)

	obsList := []obs.Observation{
		{Tool: "cursor", Label: "Cursor", State: "idle"},
		{Tool: "claude", Label: "demo", State: "running"},
	}
	if err := WriteState("", obsList); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var sf StateFile
	if err := json.Unmarshal(data, &sf); err != nil {
		t.Fatal(err)
	}
	if sf.Updated == "" {
		t.Fatal("missing updated")
	}
	if len(sf.Sessions) != 2 {
		t.Fatalf("sessions=%d", len(sf.Sessions))
	}
	for _, s := range sf.Sessions {
		if s.State == "finished" {
			t.Fatalf("finished in snapshot: %#v", s)
		}
		if s.TS == "" || s.Tool == "" || s.Label == "" {
			t.Fatalf("incomplete: %#v", s)
		}
	}

	// Empty live set still writes valid JSON
	if err := WriteState(path, nil); err != nil {
		t.Fatal(err)
	}
	data, err = os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(data, &sf); err != nil {
		t.Fatal(err)
	}
	if sf.Sessions == nil {
		// accept null or empty; normalize
		sf.Sessions = []StateSession{}
	}
	if len(sf.Sessions) != 0 {
		t.Fatalf("want empty sessions, got %#v", sf.Sessions)
	}
}
