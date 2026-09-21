package event

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// Event is the exact JSONL schema for session-watcher m1.
type Event struct {
	Tool   string `json:"tool"`
	Label  string `json:"label"`
	State  string `json:"state"` // busy | idle | finished
	TS     string `json:"ts"`    // ISO-8601
	Source string `json:"source"`
}

const Source = "session-watcher"

// New builds an Event with current UTC timestamp in ISO-8601 / RFC3339.
func New(tool, label, state string) Event {
	return Event{
		Tool:   tool,
		Label:  label,
		State:  state,
		TS:     time.Now().UTC().Format(time.RFC3339),
		Source: Source,
	}
}

// Emitter writes JSONL to stdout and appends to a log file.
type Emitter struct {
	mu      sync.Mutex
	logPath string
	stdout  *os.File
}

// ResolveLogPath chooses the events.jsonl destination:
//  1. $SESSION_WATCHER_LOG if set
//  2. ~/Library/Logs/session-watcher/events.jsonl if ~/Library exists
//  3. ./events.jsonl fallback (Linux box / missing Library)
func ResolveLogPath() string {
	if p := os.Getenv("SESSION_WATCHER_LOG"); p != "" {
		return p
	}
	home, err := os.UserHomeDir()
	if err == nil {
		library := filepath.Join(home, "Library")
		if st, err := os.Stat(library); err == nil && st.IsDir() {
			return filepath.Join(library, "Logs", "session-watcher", "events.jsonl")
		}
	}
	return "events.jsonl"
}

// NewEmitter creates an emitter writing to stdout and ResolveLogPath().
func NewEmitter() (*Emitter, error) {
	path := ResolveLogPath()
	dir := filepath.Dir(path)
	if dir == "" {
		dir = "."
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		path = "events.jsonl"
	}
	return &Emitter{logPath: path, stdout: os.Stdout}, nil
}

// LogPath returns the active log file path.
func (e *Emitter) LogPath() string { return e.logPath }

// Emit marshals one event as a JSON line to stdout and the log file.
func (e *Emitter) Emit(ev Event) error {
	e.mu.Lock()
	defer e.mu.Unlock()

	b, err := json.Marshal(ev)
	if err != nil {
		return err
	}
	line := append(b, '\n')

	if _, err := e.stdout.Write(line); err != nil {
		return fmt.Errorf("stdout: %w", err)
	}

	f, err := os.OpenFile(e.logPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return fmt.Errorf("open log %s: %w", e.logPath, err)
	}
	defer f.Close()
	if _, err := f.Write(line); err != nil {
		return fmt.Errorf("write log: %w", err)
	}
	return nil
}
