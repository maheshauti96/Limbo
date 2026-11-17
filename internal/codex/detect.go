// Package codex detects Codex (ChatGPT app-server) from verified process + flock signals.
// See VERIFIED_SIGNALS.md / docs/signals.md.
package codex

import (
	"bufio"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"syscall"

	"github.com/maheshauti/session-watcher/internal/obs"
)

const Tool = "codex"

// Verified codex binary path fragment inside ChatGPT.app.
const codexPath = "/Applications/ChatGPT.app/Contents/Resources/codex"

const coordinationLock = ".coordination.lock"

// DetectOptions configures Codex detection (paths / listing injectable for tests).
type DetectOptions struct {
	// Listing is a process listing (e.g. `ps -ax -o pid=,command=`).
	Listing string
	// LocksDir is ~/.codex/thread-writer-locks. Empty → derive from Home or UserHomeDir.
	LocksDir string
	// GlobalState is ~/.codex/.codex-global-state.json (thread-titles). Empty → derive.
	GlobalState string
	// SessionIndex is ~/.codex/session_index.jsonl (id → thread_name). Empty → derive.
	SessionIndex string
	// Home overrides the home directory used for default paths. Empty → os.UserHomeDir.
	Home string
}

// Default paths under ~/.codex (never auth.json / secrets).
func defaultCodexPaths(home string) (locks, globalState, sessionIndex string) {
	if home == "" {
		var err error
		home, err = os.UserHomeDir()
		if err != nil || home == "" {
			return "", "", ""
		}
	}
	base := filepath.Join(home, ".codex")
	return filepath.Join(base, "thread-writer-locks"),
		filepath.Join(base, ".codex-global-state.json"),
		filepath.Join(base, "session_index.jsonl")
}

// Detect returns running observations for each held thread-writer lock, or a single
// idle "Codex" observation when the verified app-server is present with no held
// locks, or nil if neither.
func Detect(opts DetectOptions) []obs.Observation {
	locksDir := opts.LocksDir
	globalState := opts.GlobalState
	sessionIndex := opts.SessionIndex
	if locksDir == "" || globalState == "" || sessionIndex == "" {
		dLocks, dGlobal, dIndex := defaultCodexPaths(opts.Home)
		if locksDir == "" {
			locksDir = dLocks
		}
		if globalState == "" {
			globalState = dGlobal
		}
		if sessionIndex == "" {
			sessionIndex = dIndex
		}
	}

	busy := detectBusyLocks(locksDir, globalState, sessionIndex)
	if len(busy) > 0 {
		return busy
	}
	if appServerPresent(opts.Listing) {
		return []obs.Observation{{Tool: Tool, Label: "Codex", State: "idle"}}
	}
	return nil
}

func detectBusyLocks(locksDir, globalStatePath, sessionIndexPath string) []obs.Observation {
	if locksDir == "" {
		return nil
	}
	entries, err := os.ReadDir(locksDir)
	if err != nil {
		return nil
	}

	titles := loadThreadTitles(globalStatePath)
	indexNames := loadSessionIndexNames(sessionIndexPath)

	var out []obs.Observation
	seen := make(map[string]struct{})
	for _, ent := range entries {
		if ent.IsDir() {
			continue
		}
		name := ent.Name()
		if name == coordinationLock {
			continue
		}
		if !strings.HasSuffix(name, ".lock") {
			continue
		}
		threadID := strings.TrimSuffix(name, ".lock")
		if threadID == "" || strings.HasPrefix(threadID, ".") {
			continue
		}
		path := filepath.Join(locksDir, name)
		if !lockHeldByOther(path) {
			continue
		}
		label := threadLabel(threadID, titles, indexNames)
		if label == "" {
			continue
		}
		if _, ok := seen[label]; ok {
			continue
		}
		seen[label] = struct{}{}
		out = append(out, obs.Observation{Tool: Tool, Label: label, State: "running"})
	}
	return out
}

// lockHeldByOther reports whether another process holds an exclusive flock on path.
// Verified: LOCK_EX|LOCK_NB fails with EWOULDBLOCK/EAGAIN when codex holds the lock.
func lockHeldByOther(path string) bool {
	f, err := os.Open(path)
	if err != nil {
		return false
	}
	defer f.Close()

	err = syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
	if err == nil {
		_ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
		return false
	}
	if errors.Is(err, syscall.EWOULDBLOCK) || errors.Is(err, syscall.EAGAIN) {
		return true
	}
	return false
}

func threadLabel(threadID string, titles, indexNames map[string]string) string {
	if t := strings.TrimSpace(titles[threadID]); t != "" && userFacingTitle(t) {
		return t
	}
	if t := strings.TrimSpace(indexNames[threadID]); t != "" && userFacingTitle(t) {
		return t
	}
	// Unlabeled locks are not user threads. Verified 2026-09-16: guardian
	// auto-review subagents (thread_source=guardian_review, model
	// codex-auto-review) hold a flock with no title in thread-titles /
	// session_index while the parent user thread is Working. Do not emit
	// short ids — that duplicated the user's thread as 01a0a9e9.
	return ""
}

// userFacingTitle rejects guardian auto-review prompt dumps used as "title".
func userFacingTitle(t string) bool {
	if len(t) > 120 {
		return false
	}
	low := strings.ToLower(t)
	if strings.Contains(low, "codex agent history whose request action") {
		return false
	}
	if strings.Contains(low, ">>> transcript start") {
		return false
	}
	return true
}

// loadThreadTitles reads thread-titles from .codex-global-state.json.
// Shape verified: {"thread-titles":{"titles":{id:name},"order":[...]}}.
// Also accepts a flat id→title map under "thread-titles".
func loadThreadTitles(path string) map[string]string {
	out := make(map[string]string)
	if path == "" {
		return out
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return out
	}
	var root map[string]json.RawMessage
	if err := json.Unmarshal(raw, &root); err != nil {
		return out
	}
	ttRaw, ok := root["thread-titles"]
	if !ok {
		return out
	}
	// Nested {titles, order}
	var nested struct {
		Titles map[string]string `json:"titles"`
	}
	if err := json.Unmarshal(ttRaw, &nested); err == nil && nested.Titles != nil {
		for k, v := range nested.Titles {
			if strings.TrimSpace(v) != "" {
				out[k] = v
			}
		}
		return out
	}
	// Flat map
	var flat map[string]string
	if err := json.Unmarshal(ttRaw, &flat); err == nil {
		for k, v := range flat {
			if k == "titles" || k == "order" {
				continue
			}
			if strings.TrimSpace(v) != "" {
				out[k] = v
			}
		}
	}
	return out
}

// loadSessionIndexNames scans session_index.jsonl for id → thread_name (last wins).
func loadSessionIndexNames(path string) map[string]string {
	out := make(map[string]string)
	if path == "" {
		return out
	}
	f, err := os.Open(path)
	if err != nil {
		return out
	}
	defer f.Close()

	type row struct {
		ID         string `json:"id"`
		ThreadName string `json:"thread_name"`
	}
	sc := bufio.NewScanner(f)
	// session names can be long; raise token limit modestly
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		var r row
		if err := json.Unmarshal([]byte(line), &r); err != nil {
			continue
		}
		id := strings.TrimSpace(r.ID)
		name := strings.TrimSpace(r.ThreadName)
		if id == "" || name == "" {
			continue
		}
		out[id] = name
	}
	return out
}

func appServerPresent(psListing string) bool {
	for _, line := range splitLines(psListing) {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		if !strings.Contains(line, codexPath) {
			continue
		}
		if !containsToken(line, "app-server") {
			continue
		}
		return true
	}
	return false
}

func containsToken(cmdline, tok string) bool {
	for _, f := range strings.Fields(cmdline) {
		if f == tok {
			return true
		}
	}
	return strings.Contains(cmdline, tok)
}

func splitLines(s string) []string {
	s = strings.ReplaceAll(s, "\r\n", "\n")
	s = strings.ReplaceAll(s, "\r", "\n")
	return strings.Split(s, "\n")
}
