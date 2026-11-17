package codex

import (
	"os"
	"path/filepath"
	"syscall"
	"testing"

	"github.com/maheshauti/session-watcher/internal/obs"
)

const appServerPS = `
  500 /Applications/ChatGPT.app/Contents/MacOS/ChatGPT
  501 /Applications/ChatGPT.app/Contents/Resources/codex app-server --port 1234
`

func TestDetect_table_psOnly(t *testing.T) {
	emptyLocks := t.TempDir()
	tests := []struct {
		name string
		ps   string
		want []obs.Observation
	}{
		{
			name: "empty",
			ps:   "",
			want: nil,
		},
		{
			name: "chatgpt without codex app-server",
			ps: `
/Applications/ChatGPT.app/Contents/MacOS/ChatGPT
`,
			want: nil,
		},
		{
			name: "codex path without app-server",
			ps: `
/Applications/ChatGPT.app/Contents/Resources/codex --help
`,
			want: nil,
		},
		{
			name: "verified idle",
			ps:   appServerPS,
			want: []obs.Observation{{Tool: Tool, Label: "Codex", State: "idle"}},
		},
		{
			name: "app-server token mid-argv",
			ps:   `/Applications/ChatGPT.app/Contents/Resources/codex --verbose app-server`,
			want: []obs.Observation{{Tool: Tool, Label: "Codex", State: "idle"}},
		},
		{
			name: "unrelated codex string elsewhere is ignored",
			ps: `
/usr/bin/echo codex app-server
/tmp/not-chatgpt/codex app-server
`,
			want: nil,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := Detect(DetectOptions{
				Listing:  tt.ps,
				LocksDir: emptyLocks,
				// Nonexistent label sources
				GlobalState:  filepath.Join(emptyLocks, "no-global.json"),
				SessionIndex: filepath.Join(emptyLocks, "no-index.jsonl"),
			})
			if !obsEqual(got, tt.want) {
				t.Fatalf("got %#v want %#v", got, tt.want)
			}
		})
	}
}

func TestDetect_heldLock_busy(t *testing.T) {
	dir := t.TempDir()
	locks := filepath.Join(dir, "thread-writer-locks")
	if err := os.MkdirAll(locks, 0o755); err != nil {
		t.Fatal(err)
	}
	threadID := "01a0c0de-0000-7000-8000-000000000001"
	lockPath := filepath.Join(locks, threadID+".lock")
	if err := os.WriteFile(lockPath, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	// Skip coordination + unheld sibling
	if err := os.WriteFile(filepath.Join(locks, ".coordination.lock"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	unheldID := "01a0dead-0000-0000-0000-000000000000"
	if err := os.WriteFile(filepath.Join(locks, unheldID+".lock"), nil, 0o644); err != nil {
		t.Fatal(err)
	}

	global := filepath.Join(dir, ".codex-global-state.json")
	if err := os.WriteFile(global, []byte(`{
  "thread-titles": {
    "titles": {
      "01a0c0de-0000-7000-8000-000000000001": "Export check"
    },
    "order": ["01a0c0de-0000-7000-8000-000000000001"]
  }
}`), 0o644); err != nil {
		t.Fatal(err)
	}
	index := filepath.Join(dir, "session_index.jsonl")
	if err := os.WriteFile(index, []byte(
		`{"id":"01a0c0de-0000-7000-8000-000000000001","thread_name":"from-index-should-lose","updated_at":"2026-09-07T14:51:14Z"}`+"\n",
	), 0o644); err != nil {
		t.Fatal(err)
	}

	held, release := holdExclusiveLock(t, lockPath)
	defer release()
	_ = held

	got := Detect(DetectOptions{
		Listing:      appServerPS, // busy locks win over idle
		LocksDir:     locks,
		GlobalState:  global,
		SessionIndex: index,
	})
	want := []obs.Observation{{Tool: Tool, Label: "Export check", State: "running"}}
	if !obsEqual(got, want) {
		t.Fatalf("got %#v want %#v", got, want)
	}
}

func TestDetect_unheldLock_notBusy(t *testing.T) {
	dir := t.TempDir()
	locks := filepath.Join(dir, "locks")
	if err := os.MkdirAll(locks, 0o755); err != nil {
		t.Fatal(err)
	}
	id := "01a0a9e4-0000-7000-8000-000000000003"
	if err := os.WriteFile(filepath.Join(locks, id+".lock"), nil, 0o644); err != nil {
		t.Fatal(err)
	}

	got := Detect(DetectOptions{
		Listing:      "",
		LocksDir:     locks,
		GlobalState:  filepath.Join(dir, "missing-global.json"),
		SessionIndex: filepath.Join(dir, "missing-index.jsonl"),
	})
	if got != nil {
		t.Fatalf("unheld lock should not be busy, got %#v", got)
	}

	gotIdle := Detect(DetectOptions{
		Listing:      appServerPS,
		LocksDir:     locks,
		GlobalState:  filepath.Join(dir, "missing-global.json"),
		SessionIndex: filepath.Join(dir, "missing-index.jsonl"),
	})
	want := []obs.Observation{{Tool: Tool, Label: "Codex", State: "idle"}}
	if !obsEqual(gotIdle, want) {
		t.Fatalf("app-server + unheld lock → idle, got %#v", gotIdle)
	}
}

func TestDetect_appServerAlone_idle(t *testing.T) {
	dir := t.TempDir()
	got := Detect(DetectOptions{
		Listing:      appServerPS,
		LocksDir:     filepath.Join(dir, "empty-locks"),
		GlobalState:  filepath.Join(dir, "g.json"),
		SessionIndex: filepath.Join(dir, "i.jsonl"),
	})
	want := []obs.Observation{{Tool: Tool, Label: "Codex", State: "idle"}}
	if !obsEqual(got, want) {
		t.Fatalf("got %#v want %#v", got, want)
	}
}

func TestDetect_labelFallbacks(t *testing.T) {
	dir := t.TempDir()
	locks := filepath.Join(dir, "locks")
	if err := os.MkdirAll(locks, 0o755); err != nil {
		t.Fatal(err)
	}

	fromIndex := "01a0bbbb-1111-2222-3333-444444444444"
	fromShort := "01a0cccc-5555-6666-7777-888888888888"
	for _, id := range []string{fromIndex, fromShort} {
		p := filepath.Join(locks, id+".lock")
		if err := os.WriteFile(p, nil, 0o644); err != nil {
			t.Fatal(err)
		}
		_, release := holdExclusiveLock(t, p)
		defer release()
	}

	index := filepath.Join(dir, "session_index.jsonl")
	if err := os.WriteFile(index, []byte(
		`{"id":"01a0bbbb-1111-2222-3333-444444444444","thread_name":"Index Name"}`+"\n"+
			`{"id":"01a0bbbb-1111-2222-3333-444444444444","thread_name":"Index Name Latest"}`+"\n",
	), 0o644); err != nil {
		t.Fatal(err)
	}

	got := Detect(DetectOptions{
		Listing:      "",
		LocksDir:     locks,
		GlobalState:  filepath.Join(dir, "no-global.json"),
		SessionIndex: index,
	})
	want := []obs.Observation{
		{Tool: Tool, Label: "Index Name Latest", State: "running"},
	}
	if !obsEqualUnordered(got, want) {
		t.Fatalf("got %#v want %#v", got, want)
	}
}

func TestDetect_unlabeledGuardianLock_skipped(t *testing.T) {
	dir := t.TempDir()
	locks := filepath.Join(dir, "locks")
	if err := os.MkdirAll(locks, 0o755); err != nil {
		t.Fatal(err)
	}
	userID := "01a0c0de-0000-7000-8000-000000000001"
	guardID := "01a0a9e9-0000-7000-8000-000000000002"
	for _, id := range []string{userID, guardID} {
		p := filepath.Join(locks, id+".lock")
		if err := os.WriteFile(p, nil, 0o644); err != nil {
			t.Fatal(err)
		}
		_, release := holdExclusiveLock(t, p)
		defer release()
	}
	index := filepath.Join(dir, "session_index.jsonl")
	if err := os.WriteFile(index, []byte(
		`{"id":"01a0c0de-0000-7000-8000-000000000001","thread_name":"Nightly export check (4)"}`+"\n",
	), 0o644); err != nil {
		t.Fatal(err)
	}
	got := Detect(DetectOptions{
		Listing:      appServerPS,
		LocksDir:     locks,
		GlobalState:  filepath.Join(dir, "no-global.json"),
		SessionIndex: index,
	})
	want := []obs.Observation{{Tool: Tool, Label: "Nightly export check (4)", State: "running"}}
	if !obsEqual(got, want) {
		t.Fatalf("got %#v want %#v", got, want)
	}
}

func holdExclusiveLock(t *testing.T, path string) (*os.File, func()) {
	t.Helper()
	f, err := os.OpenFile(path, os.O_RDWR, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX); err != nil {
		f.Close()
		t.Fatalf("flock: %v", err)
	}
	return f, func() {
		_ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
		_ = f.Close()
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

func obsEqualUnordered(a, b []obs.Observation) bool {
	if len(a) != len(b) {
		return false
	}
	used := make([]bool, len(b))
	for _, x := range a {
		found := false
		for j, y := range b {
			if used[j] {
				continue
			}
			if x == y {
				used[j] = true
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
