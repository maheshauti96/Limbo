package cursor

import (
	"database/sql"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/maheshauti/session-watcher/internal/obs"

	_ "modernc.org/sqlite"
)

func TestDetect_idleWithoutCloudAgents(t *testing.T) {
	tests := []struct {
		name string
		ps   string
		want []obs.Observation
	}{
		{name: "empty listing", ps: "", want: nil},
		{
			name: "unrelated processes only",
			ps: `
/usr/libexec/logd
/sbin/launchd
/Applications/Safari.app/Contents/MacOS/Safari
`,
			want: nil,
		},
		{
			name: "Cursor main by full path, idle",
			ps: `
/usr/libexec/logd
/Applications/Cursor.app/Contents/MacOS/Cursor
/Applications/Cursor.app/Contents/Frameworks/Cursor Helper.app/Contents/MacOS/Cursor Helper
`,
			want: []obs.Observation{{Tool: Tool, Label: "Cursor", State: "idle"}},
		},
		{
			name: "Cursor main by basename only (pgrep -x Cursor)",
			ps: `
Cursor
/usr/bin/ssh-agent
`,
			want: []obs.Observation{{Tool: Tool, Label: "Cursor", State: "idle"}},
		},
		{
			name: "Cursor main with leading PID column",
			ps: `
  100 /usr/libexec/logd
  200 /Applications/Cursor.app/Contents/MacOS/Cursor
`,
			want: []obs.Observation{{Tool: Tool, Label: "Cursor", State: "idle"}},
		},
		{
			name: "helpers alone are not a session",
			ps: `
/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (GPU).app/Contents/MacOS/Cursor Helper (GPU)
/Applications/Cursor.app/Contents/Frameworks/Cursor Helper.app/Contents/MacOS/Cursor Helper
`,
			want: nil,
		},
		{
			name: "private worker start does NOT make busy",
			ps: `
/Applications/Cursor.app/Contents/MacOS/Cursor
/Users/maheshauti/.cursor/bin/cursor-agent --label cursor.private_worker.abc worker start --name my-session --worker-dir /tmp/w1 --api-key sk-secret
`,
			want: []obs.Observation{{Tool: Tool, Label: "Cursor", State: "idle"}},
		},
		{
			name: "worker without Cursor main is ignored",
			ps: `
cursor-agent worker start --name orphan --worker-dir /tmp/o
`,
			want: nil,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := Detect(DetectOptions{Listing: tt.ps})
			if !obsEqual(got, tt.want) {
				t.Fatalf("Detect() = %#v, want %#v", got, tt.want)
			}
		})
	}
}

func TestDetect_cloudAgents(t *testing.T) {
	root := t.TempDir()
	now := time.Date(2026, 9, 16, 17, 0, 0, 0, time.UTC)
	listing := "/Applications/Cursor.app/Contents/MacOS/Cursor\n"

	// Busy agent (wal mtime 5 min ago)
	busyDir := filepath.Join(root, "hash-busy")
	writeWorkspace(t, busyDir,
		`{"folder":"vscode-remote://anysphere.cursor-retrieval/background-composer/bc-a934bf65-1111-2222-3333-444444444444"}`,
		"state.vscdb-wal", now.Add(-5*time.Minute))

	// Idle agent (wal mtime 2h ago, still within 48h)
	idleDir := filepath.Join(root, "hash-idle")
	writeWorkspace(t, idleDir,
		`{"folder":"file:///Users/maheshauti/.cursor/background-composer/bc-deadbeef-aaaa-bbbb-cccc-ddddeeeeffff"}`,
		"state.vscdb-wal", now.Add(-2*time.Hour))

	// Stale (>48h) — excluded
	staleDir := filepath.Join(root, "hash-stale")
	writeWorkspace(t, staleDir,
		`{"folder":"file:///tmp/background-composer/bc-cccccccc-0000-0000-0000-000000000000"}`,
		"state.vscdb-wal", now.Add(-50*time.Hour))

	// Non-composer workspace — ignored
	otherDir := filepath.Join(root, "hash-other")
	writeWorkspace(t, otherDir,
		`{"folder":"file:///Users/maheshauti/src/app"}`,
		"state.vscdb-wal", now.Add(-1*time.Minute))

	// URL-encoded folder URI
	encDir := filepath.Join(root, "hash-enc")
	writeWorkspace(t, encDir,
		`{"folder":"file:///Users/foo/%2Ecursor/background-composer/bc-11223344-abcd-ef00-1111-222233334444"}`,
		"state.vscdb", now.Add(-10*time.Minute)) // no wal → use vscdb; busy (10 < 15)

	got := Detect(DetectOptions{Listing: listing, WorkspaceStorage: root, Now: now})
	want := []obs.Observation{
		{Tool: Tool, Label: "bc-11223344", State: "running"},
		{Tool: Tool, Label: "bc-a934bf65", State: "running"},
		{Tool: Tool, Label: "bc-deadbeef", State: "idle"},
	}
	if !obsEqual(got, want) {
		t.Fatalf("got %#v\nwant %#v", got, want)
	}
}

func TestDetect_cloudAgents_dedupPreferNewest(t *testing.T) {
	root := t.TempDir()
	now := time.Date(2026, 9, 16, 17, 0, 0, 0, time.UTC)
	listing := "/Applications/Cursor.app/Contents/MacOS/Cursor\n"

	// Same bc id in agent + workspace folders; older is idle-ish, newer is busy
	older := filepath.Join(root, "ws-older")
	writeWorkspace(t, older,
		`{"folder":"file:///tmp/background-composer/bc-aabbccdd-0000-0000-0000-000000000001/workspace"}`,
		"state.vscdb-wal", now.Add(-30*time.Minute))

	newer := filepath.Join(root, "ws-newer")
	writeWorkspace(t, newer,
		`{"folder":"file:///tmp/background-composer/bc-aabbccdd-0000-0000-0000-000000000001/agent"}`,
		"state.vscdb-wal", now.Add(-2*time.Minute))

	got := Detect(DetectOptions{Listing: listing, WorkspaceStorage: root, Now: now})
	want := []obs.Observation{{Tool: Tool, Label: "bc-aabbccdd", State: "running"}}
	if !obsEqual(got, want) {
		t.Fatalf("got %#v want %#v", got, want)
	}
}

func TestDetect_cloudAgents_noMainIgnoresStorage(t *testing.T) {
	root := t.TempDir()
	now := time.Date(2026, 9, 16, 17, 0, 0, 0, time.UTC)
	writeWorkspace(t, filepath.Join(root, "h"),
		`{"folder":"file:///tmp/background-composer/bc-aaaaaaaa-0000-0000-0000-000000000000"}`,
		"state.vscdb-wal", now.Add(-1*time.Minute))
	got := Detect(DetectOptions{Listing: "/usr/bin/true\n", WorkspaceStorage: root, Now: now})
	if got != nil {
		t.Fatalf("got %#v", got)
	}
}

func TestExtractBCLabel(t *testing.T) {
	cases := []struct {
		in, want string
		ok       bool
	}{
		{"file:///x/background-composer/bc-a934bf65-1111-2222-3333-444444444444", "bc-a934bf65", true},
		{"file:///x/background-composer/bc-DEADBEEFcafe", "bc-deadbeef", true},
		{"file:///x/nope/bc-a934bf65", "", false},
		{"file:///x/background-composer/no-bc", "", false},
		{"file:///Users/foo/%2Ecursor/background-composer/bc-11223344-abcd", "bc-11223344", true},
		{"", "", false},
	}
	for _, c := range cases {
		got, ok := extractBCLabel(c.in)
		if ok != c.ok || got != c.want {
			t.Errorf("extractBCLabel(%q)=(%q,%v) want (%q,%v)", c.in, got, ok, c.want, c.ok)
		}
	}
}

func writeWorkspace(t *testing.T, dir, workspaceJSON, dbName string, mtime time.Time) {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "workspace.json"), []byte(workspaceJSON), 0o644); err != nil {
		t.Fatal(err)
	}
	dbPath := filepath.Join(dir, dbName)
	if err := os.WriteFile(dbPath, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(dbPath, mtime, mtime); err != nil {
		t.Fatal(err)
	}
}

func TestRedactArgv(t *testing.T) {
	tests := []struct {
		in, want string
	}{
		{
			in:   "cursor-agent worker start --name x --api-key sk-live-SECRET --worker-dir /tmp/w",
			want: "cursor-agent worker start --name x --api-key *** --worker-dir /tmp/w",
		},
		{
			in:   "cursor-agent worker start --token=abc123 --name y",
			want: "cursor-agent worker start --token=*** --name y",
		},
		{
			in:   "cursor-agent worker start --name safe",
			want: "cursor-agent worker start --name safe",
		},
	}
	for _, tt := range tests {
		got := RedactArgv(tt.in)
		if got != tt.want {
			t.Errorf("RedactArgv(%q)=\n%q\nwant\n%q", tt.in, got, tt.want)
		}
		if strings.Contains(got, "SECRET") || strings.Contains(got, "abc123") {
			t.Errorf("secret leaked in %q", got)
		}
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

func TestDetect_conversationSearch(t *testing.T) {
	now := time.Date(2026, 9, 16, 17, 45, 0, 0, time.UTC)
	listing := "/Applications/Cursor.app/Contents/MacOS/Cursor\n"
	dbPath := writeConversationSearchDB(t, []convRow{
		{
			id:        "bc-00000000-0000-4000-8000-000000000004",
			source:    "cloud-cache",
			title:     "FE+BE",
			updatedAt: now.Add(-30 * time.Second).UnixMilli(),
			archived:  0,
		},
		{
			id:        "bc-7bc94b48-aaaa-bbbb-cccc-ddddeeeeffff",
			source:    "cloud-cache",
			title:     "Identified general issue",
			updatedAt: now.Add(-30 * time.Minute).UnixMilli(),
			archived:  0,
		},
		{
			id:        "bc-oldold00-0000-0000-0000-000000000000",
			source:    "cloud-cache",
			title:     "Ancient agent",
			updatedAt: now.Add(-72 * time.Hour).UnixMilli(), // 3 days — dropped
			archived:  0,
		},
		{
			id:        "bc-archived1-0000-0000-0000-000000000000",
			source:    "cloud-cache",
			title:     "Archived",
			updatedAt: now.Add(-1 * time.Minute).UnixMilli(),
			archived:  1,
		},
		{
			id:        "not-a-bc",
			source:    "cloud-cache",
			title:     "Other",
			updatedAt: now.Add(-1 * time.Minute).UnixMilli(),
			archived:  0,
		},
	})

	// workspaceStorage would falsely show idle for FE+BE (wal 18m stale) — must not be used
	wsRoot := t.TempDir()
	writeWorkspace(t, filepath.Join(wsRoot, "hash-febe"),
		`{"folder":"file:///tmp/background-composer/bc-00000000-0000-4000-8000-000000000004"}`,
		"state.vscdb-wal", now.Add(-18*time.Minute))

	got := Detect(DetectOptions{
		Listing:            listing,
		ConversationSearch: dbPath,
		WorkspaceStorage:   wsRoot,
		Now:                now,
	})
	want := []obs.Observation{
		{Tool: Tool, Label: "FE+BE", State: "running"},
		{Tool: Tool, Label: "Identified general issue", State: "idle"},
	}
	if !obsEqual(got, want) {
		t.Fatalf("got %#v\nwant %#v", got, want)
	}
}

func TestDetect_conversationSearch_emptyTitleFallback(t *testing.T) {
	now := time.Date(2026, 9, 16, 17, 45, 0, 0, time.UTC)
	listing := "/Applications/Cursor.app/Contents/MacOS/Cursor\n"
	dbPath := writeConversationSearchDB(t, []convRow{
		{
			id:        "bc-abcdef01-2222-3333-4444-555555555555",
			source:    "cloud-cache",
			title:     "   ",
			updatedAt: now.Add(-30 * time.Second).UnixMilli(),
			archived:  0,
		},
	})
	got := Detect(DetectOptions{
		Listing:            listing,
		ConversationSearch: dbPath,
		Now:                now,
	})
	want := []obs.Observation{{Tool: Tool, Label: "bc-abcdef01", State: "running"}}
	if !obsEqual(got, want) {
		t.Fatalf("got %#v want %#v", got, want)
	}
}

func TestDetect_conversationSearch_emptyReadableIsIdle(t *testing.T) {
	now := time.Date(2026, 9, 16, 17, 45, 0, 0, time.UTC)
	listing := "/Applications/Cursor.app/Contents/MacOS/Cursor\n"
	dbPath := writeConversationSearchDB(t, nil)

	// workspaceStorage has a busy agent — must NOT be used when CS is readable empty
	wsRoot := t.TempDir()
	writeWorkspace(t, filepath.Join(wsRoot, "h"),
		`{"folder":"file:///tmp/background-composer/bc-aaaaaaaa-0000-0000-0000-000000000000"}`,
		"state.vscdb-wal", now.Add(-1*time.Minute))

	got := Detect(DetectOptions{
		Listing:            listing,
		ConversationSearch: dbPath,
		WorkspaceStorage:   wsRoot,
		Now:                now,
	})
	want := []obs.Observation{{Tool: Tool, Label: "Cursor", State: "idle"}}
	if !obsEqual(got, want) {
		t.Fatalf("got %#v want %#v", got, want)
	}
}

func TestDetect_conversationSearch_missingFallsBackToWorkspace(t *testing.T) {
	now := time.Date(2026, 9, 16, 17, 0, 0, 0, time.UTC)
	listing := "/Applications/Cursor.app/Contents/MacOS/Cursor\n"
	wsRoot := t.TempDir()
	writeWorkspace(t, filepath.Join(wsRoot, "hash-busy"),
		`{"folder":"file:///tmp/background-composer/bc-a934bf65-1111-2222-3333-444444444444"}`,
		"state.vscdb-wal", now.Add(-5*time.Minute))

	got := Detect(DetectOptions{
		Listing:            listing,
		ConversationSearch: filepath.Join(t.TempDir(), "no-such-conversation-search.db"),
		WorkspaceStorage:   wsRoot,
		Now:                now,
	})
	want := []obs.Observation{{Tool: Tool, Label: "bc-a934bf65", State: "running"}}
	if !obsEqual(got, want) {
		t.Fatalf("got %#v want %#v", got, want)
	}
}

func TestDetect_conversationSearchEmptyPath_usesWorkspaceStorage(t *testing.T) {
	// Existing behavior: ConversationSearch "" → workspaceStorage tests still apply.
	root := t.TempDir()
	now := time.Date(2026, 9, 16, 17, 0, 0, 0, time.UTC)
	listing := "/Applications/Cursor.app/Contents/MacOS/Cursor\n"
	writeWorkspace(t, filepath.Join(root, "hash-busy"),
		`{"folder":"file:///tmp/background-composer/bc-a934bf65-1111-2222-3333-444444444444"}`,
		"state.vscdb-wal", now.Add(-5*time.Minute))
	got := Detect(DetectOptions{Listing: listing, WorkspaceStorage: root, Now: now})
	want := []obs.Observation{{Tool: Tool, Label: "bc-a934bf65", State: "running"}}
	if !obsEqual(got, want) {
		t.Fatalf("got %#v want %#v", got, want)
	}
}

type convRow struct {
	id, source, title string
	updatedAt         int64
	archived          int
}

func writeConversationSearchDB(t *testing.T, rows []convRow) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "conversation-search.db")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if _, err := db.Exec(`
CREATE TABLE conversations (
  id TEXT PRIMARY KEY,
  source TEXT,
  title TEXT,
  updated_at INTEGER,
  is_archived INTEGER
);`); err != nil {
		t.Fatal(err)
	}
	for _, r := range rows {
		if _, err := db.Exec(
			`INSERT INTO conversations (id, source, title, updated_at, is_archived) VALUES (?, ?, ?, ?, ?)`,
			r.id, r.source, r.title, r.updatedAt, r.archived,
		); err != nil {
			t.Fatal(err)
		}
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	return path
}
