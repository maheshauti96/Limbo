// Package cursor detects Cursor IDE session state from process listings
// and cloud-agent signals using only verified signals
// (see VERIFIED_SIGNALS.md / docs/signals.md).
package cursor

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
	"unicode"

	"github.com/maheshauti/session-watcher/internal/obs"
	"github.com/maheshauti/session-watcher/internal/recency"

	_ "modernc.org/sqlite" // pure-Go SQLite (zero CGO)
)

const Tool = "cursor"

// Verified main binary path (boundary-matched; must not match "Cursor Helper").
const mainBinaryPath = "/Applications/Cursor.app/Contents/MacOS/Cursor"

// BusyWindow: workspaceStorage fallback — state.vscdb(-wal) mtime within this → running.
const BusyWindow = 15 * time.Minute

// ActivityWindow: conversation-search.db updated_at within this → running.
// Verified 2026-09-16: workspaceStorage wal does not update during cloud-agent work;
// conversation-search updated_at does (~1.6m while IDE Working).
const ActivityWindow = 2 * time.Minute

// DetectOptions configures Cursor detection (paths / clock injectable for tests).
type DetectOptions struct {
	// Listing is a process listing (e.g. `ps -ax -o pid=,command=`).
	Listing string
	// ConversationSearch is the path to conversation-search.db (plus -wal/-shm siblings).
	// Empty → skip and use WorkspaceStorage fallback (keeps old tests working).
	// Unreadable/missing when set → fall back to WorkspaceStorage.
	ConversationSearch string
	// WorkspaceStorage is ~/Library/Application Support/Cursor/User/workspaceStorage.
	// Used only when ConversationSearch is empty or unreadable.
	WorkspaceStorage string
	// Now is injectable clock for recency / busy tests. Zero → time.Now.
	Now time.Time
}

// DefaultWorkspaceStorage returns the verified macOS Cursor workspaceStorage path.
func DefaultWorkspaceStorage() string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return ""
	}
	return filepath.Join(home, "Library", "Application Support", "Cursor", "User", "workspaceStorage")
}

// DefaultConversationSearch returns the verified macOS conversation-search.db path.
func DefaultConversationSearch() string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return ""
	}
	return filepath.Join(home, "Library", "Application Support", "Cursor", "User", "globalStorage", "conversation-search.db")
}

// Detect returns live Cursor observations.
//
// Mapping (verified 2026-09-16):
//   - no Cursor main → empty
//   - Cursor main + conversation-search cloud-cache → running/idle per title (2m ActivityWindow)
//   - ConversationSearch empty/unreadable → workspaceStorage fallback (15m BusyWindow)
//   - Cursor main, no recent cloud agents → idle label "Cursor"
func Detect(opts DetectOptions) []obs.Observation {
	lines := splitLines(opts.Listing)
	if !cursorMainPresent(lines) {
		return nil
	}

	now := opts.Now
	if now.IsZero() {
		now = time.Now()
	}

	if opts.ConversationSearch != "" {
		agents, ok := findCloudAgentsFromConversationSearch(opts.ConversationSearch, now)
		if ok {
			if len(agents) == 0 {
				return []obs.Observation{{Tool: Tool, Label: "Cursor", State: "idle"}}
			}
			return agents
		}
		// unreadable → fall through to workspaceStorage
	}

	agents := findCloudAgents(opts.WorkspaceStorage, now)
	if len(agents) == 0 {
		return []obs.Observation{{Tool: Tool, Label: "Cursor", State: "idle"}}
	}
	return agents
}

// cursorMainPresent checks for the verified main Cursor process.
// Signals: path /Applications/Cursor.app/Contents/MacOS/Cursor (as a complete
// argv token — not "Cursor Helper"), or a line that is exactly "Cursor"
// (pgrep -x Cursor).
func cursorMainPresent(lines []string) bool {
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		if line == "Cursor" || fieldsTailIsCursor(line) {
			return true
		}
		if hasMainBinary(line) {
			return true
		}
	}
	return false
}

func fieldsTailIsCursor(line string) bool {
	fields := strings.Fields(line)
	if len(fields) == 1 && fields[0] == "Cursor" {
		return true
	}
	return len(fields) == 2 && isAllDigits(fields[0]) && fields[1] == "Cursor"
}

func isAllDigits(s string) bool {
	if s == "" {
		return false
	}
	for _, c := range s {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

func hasMainBinary(line string) bool {
	idx := strings.Index(line, mainBinaryPath)
	if idx < 0 {
		return false
	}
	after := idx + len(mainBinaryPath)
	if after == len(line) {
		return true
	}
	c := line[after]
	return c == ' ' || c == '\t'
}

type workspaceFile struct {
	Folder string `json:"folder"`
}

type cloudAgent struct {
	label string
	mtime time.Time
	state string
}

// findCloudAgentsFromConversationSearch reads cloud-cache rows from conversation-search.db.
// ok=false means path missing/unreadable (caller should fall back to workspaceStorage).
// ok=true with empty slice means readable but no recent agents → idle Cursor.
func findCloudAgentsFromConversationSearch(dbPath string, now time.Time) ([]obs.Observation, bool) {
	if dbPath == "" {
		return nil, false
	}
	if _, err := os.Stat(dbPath); err != nil {
		return nil, false
	}

	tmpDir, err := os.MkdirTemp("", "session-watcher-cursor-cs-*")
	if err != nil {
		return nil, false
	}
	defer os.RemoveAll(tmpDir)

	base := filepath.Base(dbPath)
	dstDB := filepath.Join(tmpDir, base)
	if err := copyFile(dbPath, dstDB); err != nil {
		return nil, false
	}
	// Copy WAL/SHM if present so we see live writes.
	for _, suf := range []string{"-wal", "-shm"} {
		src := dbPath + suf
		if st, err := os.Stat(src); err == nil && !st.IsDir() {
			_ = copyFile(src, dstDB+suf)
		}
	}

	dsn := fmt.Sprintf("file:%s?mode=ro", filepath.ToSlash(dstDB))
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, false
	}
	defer db.Close()

	cutoffMs := now.Add(-recency.Window).UnixMilli()
	rows, err := db.Query(`
		SELECT id, title, updated_at
		FROM conversations
		WHERE source = 'cloud-cache'
		  AND id LIKE 'bc-%'
		  AND is_archived = 0
		  AND updated_at >= ?
	`, cutoffMs)
	if err != nil {
		return nil, false
	}
	defer rows.Close()

	type row struct {
		id        string
		label     string
		updatedAt time.Time
		state     string
	}
	best := map[string]row{} // full bc id → newest
	for rows.Next() {
		var id, title string
		var updatedAtMs int64
		if err := rows.Scan(&id, &title, &updatedAtMs); err != nil {
			continue
		}
		id = strings.TrimSpace(id)
		if !strings.HasPrefix(id, "bc-") {
			continue
		}
		updatedAt := time.UnixMilli(updatedAtMs)
		if !recency.Recent(updatedAt, now) {
			continue
		}
		label := strings.TrimSpace(title)
		if label == "" {
			label = bcShortLabel(id)
		}
		state := "idle"
		age := now.Sub(updatedAt)
		if age >= 0 && age <= ActivityWindow {
			state = "running"
		}
		prev, exists := best[id]
		if exists && !updatedAt.After(prev.updatedAt) {
			continue
		}
		best[id] = row{id: id, label: label, updatedAt: updatedAt, state: state}
	}
	if err := rows.Err(); err != nil {
		return nil, false
	}

	if len(best) == 0 {
		return nil, true
	}
	list := make([]row, 0, len(best))
	for _, r := range best {
		list = append(list, r)
	}
	sort.Slice(list, func(i, j int) bool {
		if list[i].label != list[j].label {
			return list[i].label < list[j].label
		}
		return list[i].id < list[j].id
	})
	out := make([]obs.Observation, 0, len(list))
	for _, r := range list {
		out = append(out, obs.Observation{Tool: Tool, Label: r.label, State: r.state})
	}
	return out, true
}

// bcShortLabel returns "bc-" + first 8 hex digits of a full bc-<uuid> id.
func bcShortLabel(id string) string {
	rest := strings.TrimPrefix(id, "bc-")
	var hex []rune
	for _, r := range rest {
		if unicode.Is(unicode.ASCII_Hex_Digit, r) {
			hex = append(hex, unicode.ToLower(r))
			if len(hex) >= 8 {
				break
			}
			continue
		}
		if r == '-' {
			continue
		}
		break
	}
	if len(hex) < 8 {
		return id // best effort
	}
	return "bc-" + string(hex[:8])
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(dst, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	defer out.Close()
	_, err = io.Copy(out, in)
	if err != nil {
		return err
	}
	return out.Close()
}

// findCloudAgents scans workspaceStorage/*/workspace.json for background-composer
// folders with a bc-* id, filtered by state DB mtime within recency.Window.
// Fallback when conversation-search.db is missing/unreadable.
func findCloudAgents(storageRoot string, now time.Time) []obs.Observation {
	if storageRoot == "" {
		return nil
	}
	entries, err := os.ReadDir(storageRoot)
	if err != nil {
		return nil
	}

	best := map[string]cloudAgent{} // bc id (label) → newest mtime
	for _, ent := range entries {
		if !ent.IsDir() {
			continue
		}
		dir := filepath.Join(storageRoot, ent.Name())
		raw, err := os.ReadFile(filepath.Join(dir, "workspace.json"))
		if err != nil {
			continue
		}
		var wf workspaceFile
		if err := json.Unmarshal(raw, &wf); err != nil {
			continue
		}
		label, ok := extractBCLabel(wf.Folder)
		if !ok {
			continue
		}
		mtime, ok := stateDBMtime(dir)
		if !ok {
			continue
		}
		if !recency.Recent(mtime, now) {
			continue
		}
		state := "idle"
		if now.Sub(mtime) >= 0 && now.Sub(mtime) <= BusyWindow {
			state = "running"
		}
		prev, exists := best[label]
		if exists && !mtime.After(prev.mtime) {
			continue
		}
		best[label] = cloudAgent{label: label, mtime: mtime, state: state}
	}

	if len(best) == 0 {
		return nil
	}
	labels := make([]string, 0, len(best))
	for l := range best {
		labels = append(labels, l)
	}
	sort.Strings(labels)
	out := make([]obs.Observation, 0, len(labels))
	for _, l := range labels {
		a := best[l]
		out = append(out, obs.Observation{Tool: Tool, Label: a.label, State: a.state})
	}
	return out
}

func stateDBMtime(dir string) (time.Time, bool) {
	wal := filepath.Join(dir, "state.vscdb-wal")
	if st, err := os.Stat(wal); err == nil && !st.IsDir() {
		return st.ModTime(), true
	}
	db := filepath.Join(dir, "state.vscdb")
	if st, err := os.Stat(db); err == nil && !st.IsDir() {
		return st.ModTime(), true
	}
	return time.Time{}, false
}

// extractBCLabel URL-decodes folder URI and returns label "bc-" + first 8 hex
// chars of the bc uuid when the URI contains background-composer and bc-.
func extractBCLabel(folderURI string) (string, bool) {
	folderURI = strings.TrimSpace(folderURI)
	if folderURI == "" {
		return "", false
	}
	decoded := folderURI
	if d, err := url.QueryUnescape(folderURI); err == nil {
		decoded = d
	}
	if !strings.Contains(decoded, "background-composer") {
		return "", false
	}
	idx := strings.Index(decoded, "bc-")
	if idx < 0 {
		return "", false
	}
	rest := decoded[idx+3:]
	var hex []rune
	for _, r := range rest {
		if unicode.Is(unicode.ASCII_Hex_Digit, r) {
			hex = append(hex, unicode.ToLower(r))
			if len(hex) >= 8 {
				break
			}
			continue
		}
		if r == '-' {
			continue // uuid hyphens
		}
		break
	}
	if len(hex) < 8 {
		return "", false
	}
	return "bc-" + string(hex[:8]), true
}

// isSecretFlag reports whether a single argv token is a secret-bearing flag
// (--api-key, --token, or flag=value forms). Case-insensitive name match.
func isSecretFlag(tok string) (flagName string, inlineValue bool, ok bool) {
	if !strings.HasPrefix(tok, "-") {
		return "", false, false
	}
	name := tok
	inline := false
	if i := strings.IndexByte(tok, '='); i >= 0 {
		name = tok[:i]
		inline = true
	}
	lower := strings.ToLower(name)
	switch lower {
	case "--api-key", "-api-key", "--token", "-token":
		return name, inline, true
	}
	if strings.Contains(lower, "api-key") || strings.HasSuffix(lower, "-token") {
		return name, inline, true
	}
	return "", false, false
}

// RedactArgv returns cmdline with values of secret flags replaced by ***.
// Forever policy: never log raw --api-key / --token values.
func RedactArgv(cmdline string) string {
	fields := strings.Fields(cmdline)
	if len(fields) == 0 {
		return cmdline
	}
	out := make([]string, 0, len(fields))
	for i := 0; i < len(fields); i++ {
		f := fields[i]
		if name, inline, ok := isSecretFlag(f); ok {
			if inline {
				out = append(out, name+"=***")
			} else {
				out = append(out, f)
				if i+1 < len(fields) {
					out = append(out, "***")
					i++
				}
			}
			continue
		}
		out = append(out, f)
	}
	return strings.Join(out, " ")
}

func splitLines(s string) []string {
	s = strings.ReplaceAll(s, "\r\n", "\n")
	s = strings.ReplaceAll(s, "\r", "\n")
	return strings.Split(s, "\n")
}
