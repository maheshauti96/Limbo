package watcher

import (
	"time"

	"github.com/maheshauti/session-watcher/internal/claude"
	"github.com/maheshauti/session-watcher/internal/codex"
	"github.com/maheshauti/session-watcher/internal/cursor"
	"github.com/maheshauti/session-watcher/internal/event"
	"github.com/maheshauti/session-watcher/internal/grok"
	"github.com/maheshauti/session-watcher/internal/obs"
	"github.com/maheshauti/session-watcher/internal/pslist"
)

// Runner polls process + session files and emits transitions + tray snapshot.
type Runner struct {
	List      pslist.Lister
	Tracker   *event.Tracker
	ClaudeDir      string // empty → claude.DefaultSessionsDir()
	ClaudeProjects string // empty → claude.DefaultProjectsDir()
	GrokFile        string // empty → grok.DefaultActiveFile()
	GrokSessionsDir string // empty → grok.DefaultSessionsDir()
	StatePath       string // empty → event.ResolveStatePath()
	// CursorWorkspaceStorage overrides workspaceStorage (tests). Empty → default macOS path.
	CursorWorkspaceStorage string
	// CursorConversationSearch overrides conversation-search.db (tests). Empty → default macOS path.
	CursorConversationSearch string
	// Codex path overrides (tests). Empty → ~/.codex defaults.
	CodexLocksDir     string
	CodexGlobalState  string
	CodexSessionIndex string
	CodexHome         string
	// Alive overrides pid liveness for claude/grok (tests). Nil → proc.Alive via listing.
	Alive func(pid int) bool
	// Now overrides clock for recency filters (tests). Zero → time.Now inside detectors.
	Now time.Time
}

// Once takes a single snapshot, writes state.json, and applies transitions.
func (r *Runner) Once() error {
	listing, err := r.List()
	if err != nil {
		return err
	}
	all := r.detectAll(listing)
	if err := event.WriteState(r.StatePath, all); err != nil {
		return err
	}
	return r.Tracker.Apply(all)
}

func (r *Runner) detectAll(listing string) []obs.Observation {
	var all []obs.Observation

	ws := r.CursorWorkspaceStorage
	if ws == "" {
		ws = cursor.DefaultWorkspaceStorage()
	}
	cs := r.CursorConversationSearch
	if cs == "" {
		cs = cursor.DefaultConversationSearch()
	}
	all = append(all, cursor.Detect(cursor.DetectOptions{
		Listing:            listing,
		ConversationSearch: cs,
		WorkspaceStorage:   ws,
		Now:                r.Now,
	})...)

	all = append(all, codex.Detect(codex.DetectOptions{
		Listing:      listing,
		LocksDir:     r.CodexLocksDir,
		GlobalState:  r.CodexGlobalState,
		SessionIndex: r.CodexSessionIndex,
		Home:         r.CodexHome,
	})...)

	claudeDir := r.ClaudeDir
	if claudeDir == "" {
		claudeDir = claude.DefaultSessionsDir()
	}
	projects := r.ClaudeProjects
	if projects == "" {
		projects = claude.DefaultProjectsDir()
	}
	all = append(all, claude.Detect(claude.DetectOptions{
		SessionsDir: claudeDir,
		ProjectsDir: projects,
		Listing:     listing,
		Alive:       r.Alive,
		Now:         r.Now,
	})...)

	grokFile := r.GrokFile
	if grokFile == "" {
		grokFile = grok.DefaultActiveFile()
	}
	grokSessions := r.GrokSessionsDir
	if grokSessions == "" {
		grokSessions = grok.DefaultSessionsDir()
	}
	all = append(all, grok.Detect(grok.DetectOptions{
		ActiveFile:  grokFile,
		SessionsDir: grokSessions,
		Listing:     listing,
		Alive:       r.Alive,
		Now:         r.Now,
	})...)

	return all
}

// Watch polls every interval until stop is closed (or forever if stop is nil).
func (r *Runner) Watch(interval time.Duration, stop <-chan struct{}) error {
	if interval <= 0 {
		interval = 5 * time.Second
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	if err := r.Once(); err != nil {
		return err
	}
	for {
		select {
		case <-stop:
			return nil
		case <-ticker.C:
			if err := r.Once(); err != nil {
				return err
			}
		}
	}
}
