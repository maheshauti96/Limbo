package grok

import (
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/maheshauti/session-watcher/internal/obs"
)

func TestDetect_table(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "active_sessions.json")
	sessionsDir := filepath.Join(dir, "sessions")

	body := `[
  {"session_id":"aaaaaaaa11111111","pid":333001,"cwd":"/Users/maheshauti/work/alpha","opened_at":"2026-09-16T10:00:00Z"},
  {"session_id":"bbbbbbbb22222222","pid":333002,"cwd":"","opened_at":"2026-09-16T10:01:00Z"},
  {"session_id":"cccccccc33333333","pid":333003,"cwd":"/tmp/dead","opened_at":"2026-09-16T10:02:00Z"}
]`
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}

	alive := func(pid int) bool { return pid == 333001 || pid == 333002 }

	got := Detect(DetectOptions{ActiveFile: path, SessionsDir: sessionsDir, Alive: alive})
	want := []obs.Observation{
		{Tool: Tool, Label: "alpha", State: "idle"},
		{Tool: Tool, Label: "bbbbbbbb", State: "idle"},
	}
	if !obsEqual(got, want) {
		t.Fatalf("got %#v want %#v", got, want)
	}
}

func TestDetect_missingFile(t *testing.T) {
	got := Detect(DetectOptions{ActiveFile: filepath.Join(t.TempDir(), "none.json"), Alive: func(int) bool { return true }})
	if got != nil {
		t.Fatalf("got %#v", got)
	}
}

func TestDetect_emptyArray(t *testing.T) {
	path := filepath.Join(t.TempDir(), "active_sessions.json")
	if err := os.WriteFile(path, []byte(`[]`), 0o644); err != nil {
		t.Fatal(err)
	}
	got := Detect(DetectOptions{ActiveFile: path, Alive: func(int) bool { return true }})
	if got != nil && len(got) != 0 {
		t.Fatalf("got %#v", got)
	}
}

func TestDetect_listingFallback(t *testing.T) {
	path := filepath.Join(t.TempDir(), "active_sessions.json")
	body := `[{"session_id":"dddddddd44444444","pid":444001,"cwd":"/tmp/gproj","opened_at":"2026-09-16T10:00:00Z"}]`
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	listing := "444001 /opt/grok/build\n"
	got := Detect(DetectOptions{ActiveFile: path, Listing: listing})
	if len(got) != 1 || got[0].Label != "gproj" || got[0].State != "idle" || got[0].Tool != Tool {
		t.Fatalf("got %#v", got)
	}
}

func TestDetect_ignoresGrokBotAppAlone(t *testing.T) {
	got := Detect(DetectOptions{
		ActiveFile: "",
		Listing:    "/Applications/Grok Bot.app/Contents/MacOS/Grok Bot\n",
	})
	if got != nil {
		t.Fatalf("got %#v", got)
	}
}

func obsEqual(a, b []obs.Observation) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func TestDetect_recency48h(t *testing.T) {
	path := filepath.Join(t.TempDir(), "active_sessions.json")
	body := `[
  {"session_id":"oldoldold1111111","pid":601,"cwd":"/tmp/old-g","opened_at":"2026-09-10T10:00:00Z"},
  {"session_id":"newnewnew2222222","pid":602,"cwd":"/tmp/new-g","opened_at":"2026-09-16T10:00:00Z"}
]`
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 9, 16, 17, 0, 0, 0, time.UTC)
	alive := func(pid int) bool { return pid == 601 || pid == 602 }
	got := Detect(DetectOptions{ActiveFile: path, Alive: alive, Now: now})
	if len(got) != 1 || got[0].Label != "new-g" {
		t.Fatalf("want only opened_at within 48h, got %#v", got)
	}
}

func writeGrokSession(t *testing.T, sessionsDir, cwd, sessionID, events, summary string) {
	t.Helper()
	enc := url.PathEscape(cwd)
	dir := filepath.Join(sessionsDir, enc, sessionID)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if events != "" {
		if err := os.WriteFile(filepath.Join(dir, "events.jsonl"), []byte(events), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if summary != "" {
		if err := os.WriteFile(filepath.Join(dir, "summary.json"), []byte(summary), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

func TestDetect_livePid_turnEnded_idle(t *testing.T) {
	dir := t.TempDir()
	active := filepath.Join(dir, "active_sessions.json")
	sessionsDir := filepath.Join(dir, "sessions")
	cwd := "/Users/maheshauti/work/alpha"
	sid := "aaaaaaaa11111111"
	body := `[{"session_id":"` + sid + `","pid":333001,"cwd":"` + cwd + `","opened_at":"2026-09-16T10:00:00Z"}]`
	if err := os.WriteFile(active, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	writeGrokSession(t, sessionsDir, cwd, sid,
		`{"type":"turn_started"}
{"type":"turn_ended"}
`,
		`{"generated_title":"Alpha Fix"}`)
	got := Detect(DetectOptions{
		ActiveFile:  active,
		SessionsDir: sessionsDir,
		Alive:       func(pid int) bool { return pid == 333001 },
	})
	if len(got) != 1 || got[0].State != "idle" || got[0].Label != "Alpha Fix" {
		t.Fatalf("want idle Alpha Fix, got %#v", got)
	}
}

func TestDetect_livePid_turnStarted_running(t *testing.T) {
	dir := t.TempDir()
	active := filepath.Join(dir, "active_sessions.json")
	sessionsDir := filepath.Join(dir, "sessions")
	cwd := "/Users/maheshauti/work/beta"
	sid := "bbbbbbbb22222222"
	body := `[{"session_id":"` + sid + `","pid":333002,"cwd":"` + cwd + `","opened_at":"2026-09-16T10:00:00Z"}]`
	if err := os.WriteFile(active, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	writeGrokSession(t, sessionsDir, cwd, sid,
		`{"type":"turn_ended"}
{"type":"turn_started"}
`,
		`{"session_summary":"Beta work in progress"}`)
	got := Detect(DetectOptions{
		ActiveFile:  active,
		SessionsDir: sessionsDir,
		Alive:       func(pid int) bool { return pid == 333002 },
	})
	if len(got) != 1 || got[0].State != "running" || got[0].Label != "Beta work in progress" {
		t.Fatalf("want running, got %#v", got)
	}
}

func TestDetect_livePid_noEventsFile_idle(t *testing.T) {
	dir := t.TempDir()
	active := filepath.Join(dir, "active_sessions.json")
	sessionsDir := filepath.Join(dir, "sessions")
	cwd := "/tmp/gproj"
	sid := "dddddddd44444444"
	body := `[{"session_id":"` + sid + `","pid":444001,"cwd":"` + cwd + `","opened_at":"2026-09-16T10:00:00Z"}]`
	if err := os.WriteFile(active, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	// Session dir exists with summary only — no events.jsonl
	writeGrokSession(t, sessionsDir, cwd, sid, "", `{"generated_title":"No Events"}`)
	got := Detect(DetectOptions{
		ActiveFile:  active,
		SessionsDir: sessionsDir,
		Alive:       func(pid int) bool { return pid == 444001 },
	})
	if len(got) != 1 || got[0].State != "idle" || got[0].Label != "No Events" {
		t.Fatalf("want idle when events missing, got %#v", got)
	}
}

func TestDetect_recency_viaSummaryLastActive(t *testing.T) {
	dir := t.TempDir()
	active := filepath.Join(dir, "active_sessions.json")
	sessionsDir := filepath.Join(dir, "sessions")
	cwd := "/tmp/revive"
	sid := "eeeeeeee55555555"
	// opened_at stale, but summary last_active_at recent → keep
	body := `[{"session_id":"` + sid + `","pid":555001,"cwd":"` + cwd + `","opened_at":"2026-09-10T10:00:00Z"}]`
	if err := os.WriteFile(active, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	writeGrokSession(t, sessionsDir, cwd, sid,
		`{"type":"turn_ended"}
`,
		`{"generated_title":"Revived","last_active_at":"2026-09-16T12:00:00Z"}`)
	now := time.Date(2026, 9, 16, 17, 0, 0, 0, time.UTC)
	got := Detect(DetectOptions{
		ActiveFile:  active,
		SessionsDir: sessionsDir,
		Alive:       func(pid int) bool { return pid == 555001 },
		Now:         now,
	})
	if len(got) != 1 || got[0].Label != "Revived" || got[0].State != "idle" {
		t.Fatalf("want kept via last_active_at, got %#v", got)
	}
}

func TestEncodeCwd_pathEscapeMatchesSlashReplace(t *testing.T) {
	cwd := "/Users/maheshauti/work/alpha"
	encs := encodeCwdForSessionsDir(cwd)
	if len(encs) < 1 {
		t.Fatal("no encodings")
	}
	if !strings.Contains(encs[0], "%2F") {
		t.Fatalf("PathEscape should encode / as %%2F, got %q", encs[0])
	}
	slashOnly := strings.ReplaceAll(cwd, "/", "%2F")
	found := false
	for _, e := range encs {
		if e == slashOnly || e == url.PathEscape(cwd) {
			found = true
		}
	}
	if !found {
		t.Fatalf("encodings %#v missing PathEscape/slash variants", encs)
	}
}
