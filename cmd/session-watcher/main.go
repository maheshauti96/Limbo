package main

import (
	"flag"
	"fmt"
	"os"
	"time"

	"github.com/maheshauti/session-watcher/internal/event"
	"github.com/maheshauti/session-watcher/internal/pslist"
	"github.com/maheshauti/session-watcher/internal/watcher"
)

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}

	cmd := os.Args[1]
	switch cmd {
	case "once":
		onceFlags := flag.NewFlagSet("once", flag.ExitOnError)
		_ = onceFlags.Parse(os.Args[2:])
		if err := runOnce(); err != nil {
			fmt.Fprintf(os.Stderr, "session-watcher once: %v\n", err)
			os.Exit(1)
		}
	case "watch":
		watchFlags := flag.NewFlagSet("watch", flag.ExitOnError)
		interval := watchFlags.Duration("interval", 250*time.Millisecond, "poll interval")
		_ = watchFlags.Parse(os.Args[2:])
		if err := runWatch(*interval); err != nil {
			fmt.Fprintf(os.Stderr, "session-watcher watch: %v\n", err)
			os.Exit(1)
		}
	case "help", "-h", "--help":
		usage()
	default:
		fmt.Fprintf(os.Stderr, "unknown command %q\n", cmd)
		usage()
		os.Exit(2)
	}
}

func usage() {
	fmt.Fprintf(os.Stderr, `session-watcher — local coding-session state for a macOS tray (no webhooks)

Usage:
  session-watcher once
  session-watcher watch [-interval 250ms]

Each poll:
  • Appends state transitions to events.jsonl (and stdout)
  • Atomically writes the live snapshot to state.json (tray reads this)

Tools: cursor, claude, grok, codex — see docs/signals.md

Schema (events.jsonl transition):
  {"tool":"...","label":"...","state":"running|idle|finished","ts":"RFC3339","source":"session-watcher"}

state.json (current live set only):
  {"updated":"RFC3339","sessions":[{"tool":"...","label":"...","state":"...","ts":"..."}]}

Paths:
  events: ~/Library/Logs/session-watcher/events.jsonl
          or $SESSION_WATCHER_LOG / ./events.jsonl
  state:  ~/Library/Application Support/session-watcher/state.json
          or $SESSION_WATCHER_STATE / ./state.json

No secrets in logs or files. No HTTP.
`)
}

func newRunner() (*watcher.Runner, error) {
	em, err := event.NewEmitter()
	if err != nil {
		return nil, err
	}
	tr := event.NewTracker(em.Emit)
	return &watcher.Runner{List: pslist.Default, Tracker: tr}, nil
}

func runOnce() error {
	r, err := newRunner()
	if err != nil {
		return err
	}
	return r.Once()
}

func runWatch(interval time.Duration) error {
	r, err := newRunner()
	if err != nil {
		return err
	}
	return r.Watch(interval, nil)
}
