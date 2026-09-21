// Package claude detects Claude Code sessions from ~/.claude/sessions/*.json
// using only verified signals (see VERIFIED_SIGNALS.md / docs/signals.md).
package claude

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
	"path"
	"path/filepath"
	"strings"
	"time"

	"github.com/maheshauti/session-watcher/internal/obs"
	"github.com/maheshauti/session-watcher/internal/proc"
	"github.com/maheshauti/session-watcher/internal/recency"
)

const Tool = "claude"

// sessionFile is the verified JSON shape of ~/.claude/sessions/*.json.
// Never read *.key or .credentials.json.
type sessionFile struct {
	PID       int    `json:"pid"`
	SessionID string `json:"sessionId"`
	Cwd       string `json:"cwd"`
	Name      string `json:"name"`
	Status    string `json:"status"` // busy | idle
}

// DetectOptions configures Claude detection (paths / listing injectable for tests).
type DetectOptions struct {
	// SessionsDir is ~/.claude/sessions (required; empty → no observations).
	SessionsDir string
	// ProjectsDir is ~/.claude/projects (sessionId.jsonl). Empty → skip recency filter.
	ProjectsDir string
	// Listing is a process listing (preferably `ps -ax -o pid=,command=`).
	Listing string
	// Alive checks whether a pid is live. Nil → proc.Alive(pid, Listing).
	Alive func(pid int) bool
	// Now is injectable clock for recency tests. Zero → time.Now.
	Now time.Time
}

// DefaultSessionsDir returns ~/.claude/sessions.
func DefaultSessionsDir() string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return ""
	}
	return filepath.Join(home, ".claude", "sessions")
}

// Detect reads session JSON files and returns live Claude observations.
// Does not treat Claude.app alone as a coding session.
func Detect(opts DetectOptions) []obs.Observation {
	dir := opts.SessionsDir
	if dir == "" {
		return nil
	}
	alive := opts.Alive
	if alive == nil {
		listing := opts.Listing
		alive = func(pid int) bool { return proc.Alive(pid, listing) }
	}

	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}

	var out []obs.Observation
	seen := make(map[string]struct{})
	for _, ent := range entries {
		if ent.IsDir() {
			continue
		}
		name := ent.Name()
		if !isSafeSessionJSON(name) {
			continue
		}
		raw, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			continue
		}
		var sf sessionFile
		if err := json.Unmarshal(raw, &sf); err != nil {
			continue
		}
		status := strings.ToLower(strings.TrimSpace(sf.Status))
		if status != "busy" && status != "idle" {
			continue
		}
		state := status
		if state == "busy" {
			state = "running"
		}
		if !alive(sf.PID) {
			continue
		}
		label := sessionLabel(sf)
		if label == "" {
			continue
		}
		if opts.ProjectsDir != "" {
			last := lastUserAt(opts.ProjectsDir, sf.Cwd, sf.SessionID)
			if !last.IsZero() {
				now := opts.Now
				if now.IsZero() {
					now = time.Now()
				}
				if !recency.Recent(last, now) {
					continue
				}
			}
		}
		if _, ok := seen[label]; ok {
			continue
		}
		seen[label] = struct{}{}
		out = append(out, obs.Observation{Tool: Tool, Label: label, State: state})
	}
	return out
}

// isSafeSessionJSON allows only *.json and forever skips *.key and credentials.
func isSafeSessionJSON(name string) bool {
	lower := strings.ToLower(name)
	if strings.HasSuffix(lower, ".key") {
		return false
	}
	if lower == ".credentials.json" || lower == "credentials.json" {
		return false
	}
	if !strings.HasSuffix(lower, ".json") {
		return false
	}
	// Skip hidden files other than we already rejected credentials.
	if strings.HasPrefix(name, ".") {
		return false
	}
	return true
}

func sessionLabel(sf sessionFile) string {
	if n := strings.TrimSpace(sf.Name); n != "" {
		return n
	}
	if cwd := strings.TrimSpace(sf.Cwd); cwd != "" {
		base := path.Base(cwd)
		if base != "" && base != "." && base != "/" {
			return base
		}
	}
	id := strings.TrimSpace(sf.SessionID)
	if len(id) >= 8 {
		return id[:8]
	}
	return id
}


// DefaultProjectsDir returns ~/.claude/projects.
func DefaultProjectsDir() string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return ""
	}
	return filepath.Join(home, ".claude", "projects")
}

// cwdProjectDir encodes cwd the way Claude stores it: /Users/foo → -Users-foo
func cwdProjectDir(cwd string) string {
	cwd = strings.TrimSpace(cwd)
	if cwd == "" {
		return ""
	}
	return strings.ReplaceAll(cwd, "/", "-")
}

func lastUserAt(projectsDir, cwd, sessionID string) time.Time {
	sessionID = strings.TrimSpace(sessionID)
	if projectsDir == "" || sessionID == "" {
		return time.Time{}
	}
	var candidates []string
	if enc := cwdProjectDir(cwd); enc != "" {
		candidates = append(candidates, filepath.Join(projectsDir, enc, sessionID+".jsonl"))
	}
	// fallback: glob */{sessionId}.jsonl one level
	if matches, err := filepath.Glob(filepath.Join(projectsDir, "*", sessionID+".jsonl")); err == nil {
		candidates = append(candidates, matches...)
	}
	seen := map[string]struct{}{}
	var best time.Time
	for _, p := range candidates {
		if _, ok := seen[p]; ok {
			continue
		}
		seen[p] = struct{}{}
		if t := lastUserInJSONL(p); t.After(best) {
			best = t
		}
	}
	return best
}

func lastUserInJSONL(path string) time.Time {
	f, err := os.Open(path)
	if err != nil {
		return time.Time{}
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return time.Time{}
	}
	const maxTail = 1 << 20 // 1 MiB from EOF — last user events sit at the end
	size := st.Size()
	start := int64(0)
	if size > maxTail {
		start = size - maxTail
	}
	if _, err := f.Seek(start, io.SeekStart); err != nil {
		return time.Time{}
	}
	raw, err := io.ReadAll(f)
	if err != nil {
		return time.Time{}
	}
	if start > 0 {
		if i := bytes.IndexByte(raw, '\n'); i >= 0 {
			raw = raw[i+1:]
		}
	}
	var last time.Time
	for _, line := range bytes.Split(raw, []byte{'\n'}) {
		line = bytes.TrimSpace(line)
		if len(line) == 0 {
			continue
		}
		var row struct {
			Type      string          `json:"type"`
			Timestamp json.RawMessage `json:"timestamp"`
			Message   *struct {
				Role string `json:"role"`
			} `json:"message"`
		}
		if err := json.Unmarshal(line, &row); err != nil {
			continue
		}
		isUser := row.Type == "user" || (row.Message != nil && row.Message.Role == "user")
		if !isUser {
			continue
		}
		if ts, ok := parseTS(row.Timestamp); ok && ts.After(last) {
			last = ts
		}
	}
	return last
}

func parseTS(raw json.RawMessage) (time.Time, bool) {
	raw = bytes.TrimSpace(raw)
	if len(raw) == 0 || string(raw) == "null" {
		return time.Time{}, false
	}
	if raw[0] == '"' {
		var s string
		if err := json.Unmarshal(raw, &s); err != nil {
			return time.Time{}, false
		}
		for _, layout := range []string{time.RFC3339Nano, time.RFC3339} {
			if t, err := time.Parse(layout, s); err == nil {
				return t, true
			}
		}
		return time.Time{}, false
	}
	var n json.Number
	if err := json.Unmarshal(raw, &n); err != nil {
		return time.Time{}, false
	}
	f, err := n.Float64()
	if err != nil {
		return time.Time{}, false
	}
	if f > 1e12 {
		f = f / 1000
	}
	sec := int64(f)
	nsec := int64((f - float64(sec)) * 1e9)
	return time.Unix(sec, nsec), true
}
