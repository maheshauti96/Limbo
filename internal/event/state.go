package event

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/maheshauti/session-watcher/internal/obs"
)

// StateFile is the tray snapshot written on every Once().
// sessions is the CURRENT live set only (no finished rows).
type StateFile struct {
	Updated  string         `json:"updated"`
	Sessions []StateSession `json:"sessions"`
}

// StateSession is one live session row in state.json.
type StateSession struct {
	Tool  string `json:"tool"`
	Label string `json:"label"`
	State string `json:"state"`
	TS    string `json:"ts"`
}

// ResolveStatePath chooses the state.json destination:
//  1. $SESSION_WATCHER_STATE if set
//  2. ~/Library/Application Support/session-watcher/state.json if ~/Library exists
//  3. ./state.json fallback
func ResolveStatePath() string {
	if p := os.Getenv("SESSION_WATCHER_STATE"); p != "" {
		return p
	}
	home, err := os.UserHomeDir()
	if err == nil {
		library := filepath.Join(home, "Library")
		if st, err := os.Stat(library); err == nil && st.IsDir() {
			return filepath.Join(library, "Application Support", "session-watcher", "state.json")
		}
	}
	return "state.json"
}

// WriteState atomically writes the live observation snapshot to path
// (temp file in the same directory + rename). If path is empty, uses ResolveStatePath().
func WriteState(path string, observations []obs.Observation) error {
	if path == "" {
		path = ResolveStatePath()
	}
	now := time.Now().UTC().Format(time.RFC3339)
	sessions := make([]StateSession, 0, len(observations))
	for _, o := range observations {
		sessions = append(sessions, StateSession{
			Tool:  o.Tool,
			Label: o.Label,
			State: o.State,
			TS:    now,
		})
	}
	sf := StateFile{Updated: now, Sessions: sessions}
	b, err := json.Marshal(sf)
	if err != nil {
		return err
	}
	b = append(b, '\n')

	dir := filepath.Dir(path)
	if dir == "" {
		dir = "."
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		// Fall back to cwd if Application Support path fails
		path = "state.json"
		dir = "."
	}

	tmp, err := os.CreateTemp(dir, "state-*.json.tmp")
	if err != nil {
		return fmt.Errorf("create temp state: %w", err)
	}
	tmpName := tmp.Name()
	cleanup := true
	defer func() {
		if cleanup {
			_ = os.Remove(tmpName)
		}
	}()

	if _, err := tmp.Write(b); err != nil {
		_ = tmp.Close()
		return fmt.Errorf("write temp state: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("close temp state: %w", err)
	}
	if err := os.Rename(tmpName, path); err != nil {
		return fmt.Errorf("rename state: %w", err)
	}
	cleanup = false
	return nil
}
