package claude

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/maheshauti/session-watcher/internal/obs"
)

func TestDetect_table(t *testing.T) {
	dir := t.TempDir()

	write := func(name, body string) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	write("live-busy.json", `{
  "pid": 111001,
  "sessionId": "abcdef0123456789",
  "cwd": "/Users/maheshauti/src/demo",
  "name": "demo-busy",
  "status": "busy"
}`)
	write("live-idle.json", `{
  "pid": 111002,
  "sessionId": "deadbeef99999999",
  "cwd": "/Users/maheshauti/src/other",
  "name": "",
  "status": "idle"
}`)
	write("dead.json", `{
  "pid": 111003,
  "sessionId": "deaddeaddeaddead",
  "cwd": "/tmp/gone",
  "name": "gone",
  "status": "busy"
}`)
	write("unknown-status.json", `{
  "pid": 111001,
  "sessionId": "unkunkunkunkunk1",
  "cwd": "/tmp/u",
  "name": "unk",
  "status": "thinking"
}`)
	write("no-name-short-id.json", `{
  "pid": 111001,
  "sessionId": "short",
  "cwd": "",
  "name": "",
  "status": "idle"
}`)
	write("label-from-id.json", `{
  "pid": 111004,
  "sessionId": "12345678abcdefgh",
  "cwd": "",
  "name": "",
  "status": "busy"
}`)
	// Forever skipped:
	write("secret.key", `{"pid":111001,"sessionId":"keykeykeykeykey1","status":"busy","name":"from-key"}`)
	write(".credentials.json", `{"token":"SECRET_SHOULD_NOT_BE_READ"}`)
	write("credentials.json", `{"token":"SECRET2"}`)
	write("notes.txt", `not json`)

	aliveSet := map[int]bool{111001: true, 111002: true, 111004: true}
	alive := func(pid int) bool { return aliveSet[pid] }

	got := Detect(DetectOptions{SessionsDir: dir, Alive: alive})
	want := []obs.Observation{
		{Tool: Tool, Label: "demo-busy", State: "running"},
		{Tool: Tool, Label: "other", State: "idle"}, // basename(cwd)
		{Tool: Tool, Label: "short", State: "idle"},
		{Tool: Tool, Label: "12345678", State: "running"},
	}
	if !obsEqualUnordered(got, want) {
		t.Fatalf("got %#v\nwant %#v", got, want)
	}

	// Ensure we never opened credentials by checking file still only has token
	// (we just assert Detect didn't return a label from .key)
	for _, o := range got {
		if o.Label == "from-key" {
			t.Fatal("read *.key file")
		}
	}
}

func TestDetect_skipsMissingDir(t *testing.T) {
	got := Detect(DetectOptions{SessionsDir: filepath.Join(t.TempDir(), "nope"), Alive: func(int) bool { return true }})
	if got != nil {
		t.Fatalf("got %#v", got)
	}
}

func TestDetect_listingFallback(t *testing.T) {
	dir := t.TempDir()
	body := `{
  "pid": 222001,
  "sessionId": "listfall00123456",
  "cwd": "/tmp/proj",
  "name": "via-listing",
  "status": "busy"
}`
	if err := os.WriteFile(filepath.Join(dir, "s.json"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	// No custom Alive → proc.Alive; fake pid dead via signal, live via listing.
	listing := "222001 /some/claude/process\n"
	got := Detect(DetectOptions{SessionsDir: dir, Listing: listing})
	if len(got) != 1 || got[0].Label != "via-listing" || got[0].State != "running" {
		t.Fatalf("got %#v", got)
	}
}

func TestIsSafeSessionJSON(t *testing.T) {
	cases := map[string]bool{
		"abc.json":           true,
		"foo.JSON":           true,
		"x.key":              false,
		"session.key":        false,
		".credentials.json":  false,
		"credentials.json":   false,
		".hidden.json":       false,
		"readme.txt":         false,
	}
	for name, want := range cases {
		if got := isSafeSessionJSON(name); got != want {
			t.Errorf("isSafeSessionJSON(%q)=%v want %v", name, got, want)
		}
	}
}

func obsEqualUnordered(a, b []obs.Observation) bool {
	if len(a) != len(b) {
		return false
	}
	used := make([]bool, len(b))
	for _, x := range a {
		found := false
		for i, y := range b {
			if used[i] {
				continue
			}
			if x == y {
				used[i] = true
				found = true
				break
			}
		}
		if !found {
			return false
		}
	}
	return true
}


func TestDetect_recency48h(t *testing.T) {
	sessions := t.TempDir()
	projects := t.TempDir()
	now := time.Date(2026, 9, 16, 17, 0, 0, 0, time.UTC)
	proj := filepath.Join(projects, "-Users-maheshauti-Documents")
	if err := os.MkdirAll(proj, 0o755); err != nil {
		t.Fatal(err)
	}
	writeJSONL := func(id string, userISO string) {
		t.Helper()
		body := `{"type":"user","timestamp":"` + userISO + `","message":{"role":"user"}}` + "\n"
		if err := os.WriteFile(filepath.Join(proj, id+".jsonl"), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	writeSess := func(file, id, name string, pid int) {
		t.Helper()
		body := fmt.Sprintf(`{"pid":%d,"sessionId":"%s","cwd":"/Users/maheshauti/Documents","name":"%s","status":"idle"}`, pid, id, name)
		if err := os.WriteFile(filepath.Join(sessions, file), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	writeSess("old.json", "oldoldoldoldold1", "Brand Mentions", 21)
	writeSess("new.json", "newnewnewnewnew1", "Taxonomy engine - Latest", 22)
	writeJSONL("oldoldoldoldold1", "2026-09-09T22:17:44.444Z")
	writeJSONL("newnewnewnewnew1", "2026-09-16T16:45:28.198Z")

	alive := func(pid int) bool { return pid == 21 || pid == 22 }
	got := Detect(DetectOptions{SessionsDir: sessions, ProjectsDir: projects, Alive: alive, Now: now})
	if len(got) != 1 || got[0].Label != "Taxonomy engine - Latest" {
		t.Fatalf("want only recent thread, got %#v", got)
	}
}


func TestDetect_missingJSONL_keepsLive(t *testing.T) {
	sessions := t.TempDir()
	projects := t.TempDir() // empty — no jsonl
	now := time.Date(2026, 9, 16, 17, 0, 0, 0, time.UTC)
	body := `{"pid":31,"sessionId":"missmissmissmiss1","cwd":"/Users/maheshauti/Documents","name":"No History Yet","status":"idle"}`
	if err := os.WriteFile(filepath.Join(sessions, "m.json"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	alive := func(pid int) bool { return pid == 31 }
	got := Detect(DetectOptions{SessionsDir: sessions, ProjectsDir: projects, Alive: alive, Now: now})
	if len(got) != 1 || got[0].Label != "No History Yet" {
		t.Fatalf("missing jsonl should keep live session, got %#v", got)
	}
}
