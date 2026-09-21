// Package grok detects grok-build sessions from ~/.grok/active_sessions.json
// using only verified signals (see VERIFIED_SIGNALS.md / docs/signals.md).
package grok

import (
	"bufio"
	"encoding/json"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/maheshauti/session-watcher/internal/obs"
	"github.com/maheshauti/session-watcher/internal/proc"
	"github.com/maheshauti/session-watcher/internal/recency"
)

const Tool = "grok"

const maxLabelRunes = 80

// activeSession is one element of ~/.grok/active_sessions.json.
type activeSession struct {
	SessionID string `json:"session_id"`
	PID       int    `json:"pid"`
	Cwd       string `json:"cwd"`
	OpenedAt  string `json:"opened_at"`
}

// summaryFile is the optional ~/.grok/sessions/.../summary.json shape.
type summaryFile struct {
	GeneratedTitle string `json:"generated_title"`
	SessionSummary string `json:"session_summary"`
	LastActiveAt   string `json:"last_active_at"`
}

// DetectOptions configures grok-build detection.
type DetectOptions struct {
	ActiveFile  string // path to active_sessions.json
	SessionsDir string // ~/.grok/sessions (events.jsonl + summary.json); empty → DefaultSessionsDir when ActiveFile is defaulted by caller, or skip events/summary when unset in tests that only pass ActiveFile
	Listing     string
	Alive       func(pid int) bool
	Now         time.Time
}

// DefaultActiveFile returns ~/.grok/active_sessions.json.
func DefaultActiveFile() string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return ""
	}
	return filepath.Join(home, ".grok", "active_sessions.json")
}

// DefaultSessionsDir returns ~/.grok/sessions.
func DefaultSessionsDir() string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return ""
	}
	return filepath.Join(home, ".grok", "sessions")
}

// Detect returns live grok-build observations.
// Pid alive ≠ running: scan events.jsonl for last turn_started / turn_ended.
// Missing events.jsonl → idle if pid live.
func Detect(opts DetectOptions) []obs.Observation {
	file := opts.ActiveFile
	if file == "" {
		return nil
	}
	alive := opts.Alive
	if alive == nil {
		listing := opts.Listing
		alive = func(pid int) bool { return proc.Alive(pid, listing) }
	}
	sessionsDir := opts.SessionsDir

	raw, err := os.ReadFile(file)
	if err != nil {
		return nil
	}
	var sessions []activeSession
	if err := json.Unmarshal(raw, &sessions); err != nil {
		return nil
	}

	now := opts.Now
	if now.IsZero() {
		now = time.Now()
	}

	var out []obs.Observation
	seen := make(map[string]struct{})
	for _, s := range sessions {
		if !alive(s.PID) {
			continue
		}
		sessionPath := resolveSessionDir(sessionsDir, s.Cwd, s.SessionID)
		summary := readSummary(sessionPath)

		if !recentEnough(s, summary, now) {
			continue
		}
		label := sessionLabel(s, summary)
		if label == "" {
			continue
		}
		if _, ok := seen[label]; ok {
			continue
		}
		seen[label] = struct{}{}

		state := "idle"
		if turnRunning(sessionPath) {
			state = "running"
		}
		out = append(out, obs.Observation{Tool: Tool, Label: label, State: state})
	}
	return out
}

func recentEnough(s activeSession, summary summaryFile, now time.Time) bool {
	var candidates []time.Time
	if t, ok := parseTime(s.OpenedAt); ok {
		candidates = append(candidates, t)
	}
	if t, ok := parseTime(summary.LastActiveAt); ok {
		candidates = append(candidates, t)
	}
	if len(candidates) == 0 {
		// No parseable timestamps → keep (pid live), same spirit as missing events.
		return true
	}
	for _, t := range candidates {
		if recency.Recent(t, now) {
			return true
		}
	}
	return false
}

func parseTime(s string) (time.Time, bool) {
	s = strings.TrimSpace(s)
	if s == "" {
		return time.Time{}, false
	}
	for _, layout := range []string{time.RFC3339Nano, time.RFC3339} {
		if t, err := time.Parse(layout, s); err == nil {
			return t, true
		}
	}
	return time.Time{}, false
}

// encodeCwdForSessionsDir matches on-disk encoding under ~/.grok/sessions:
// prefer url.PathEscape ( / → %2F ); also try ReplaceAll("/", "%2F") if different.
func encodeCwdForSessionsDir(cwd string) []string {
	cwd = strings.TrimSpace(cwd)
	if cwd == "" {
		return nil
	}
	escaped := url.PathEscape(cwd)
	slashOnly := strings.ReplaceAll(cwd, "/", "%2F")
	out := []string{escaped}
	if slashOnly != escaped {
		out = append(out, slashOnly)
	}
	return out
}

func resolveSessionDir(sessionsDir, cwd, sessionID string) string {
	sessionsDir = strings.TrimSpace(sessionsDir)
	sessionID = strings.TrimSpace(sessionID)
	if sessionsDir == "" || sessionID == "" {
		return ""
	}
	for _, enc := range encodeCwdForSessionsDir(cwd) {
		p := filepath.Join(sessionsDir, enc, sessionID)
		if st, err := os.Stat(p); err == nil && st.IsDir() {
			return p
		}
	}
	// Prefer PathEscape path even if missing (for events/summary open attempts).
	encs := encodeCwdForSessionsDir(cwd)
	if len(encs) == 0 {
		return filepath.Join(sessionsDir, sessionID)
	}
	return filepath.Join(sessionsDir, encs[0], sessionID)
}

func readSummary(sessionPath string) summaryFile {
	if sessionPath == "" {
		return summaryFile{}
	}
	raw, err := os.ReadFile(filepath.Join(sessionPath, "summary.json"))
	if err != nil {
		return summaryFile{}
	}
	var sf summaryFile
	_ = json.Unmarshal(raw, &sf)
	return sf
}

// turnRunning scans events.jsonl from the end for the last turn_started or turn_ended.
// Last turn_started → running; turn_ended or none/missing file → idle.
func turnRunning(sessionPath string) bool {
	if sessionPath == "" {
		return false
	}
	path := filepath.Join(sessionPath, "events.jsonl")
	f, err := os.Open(path)
	if err != nil {
		return false
	}
	defer f.Close()

	var last string
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		var row struct {
			Type string `json:"type"`
		}
		if err := json.Unmarshal([]byte(line), &row); err != nil {
			continue
		}
		t := strings.TrimSpace(row.Type)
		if t == "turn_started" || t == "turn_ended" {
			last = t
		}
	}
	return last == "turn_started"
}

func sessionLabel(s activeSession, summary summaryFile) string {
	if t := strings.TrimSpace(summary.GeneratedTitle); t != "" {
		return truncateLabel(t)
	}
	if t := strings.TrimSpace(summary.SessionSummary); t != "" {
		return truncateLabel(t)
	}
	if cwd := strings.TrimSpace(s.Cwd); cwd != "" {
		base := path.Base(cwd)
		if base != "" && base != "." && base != "/" {
			return truncateLabel(base)
		}
	}
	id := strings.TrimSpace(s.SessionID)
	if len(id) >= 8 {
		return id[:8]
	}
	return id
}

func truncateLabel(s string) string {
	s = strings.TrimSpace(s)
	if s == "" {
		return s
	}
	if utf8.RuneCountInString(s) <= maxLabelRunes {
		return s
	}
	runes := []rune(s)
	return string(runes[:maxLabelRunes-1]) + "…"
}
