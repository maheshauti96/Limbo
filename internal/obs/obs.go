// Package obs defines the shared live-session observation type.
package obs

// Observation is one live session sighting for the current poll.
// Finished is never an observation — the tracker emits finished when a
// (tool, label) pair disappears from the active set.
type Observation struct {
	Tool  string // cursor | claude | grok | codex
	Label string
	State string // busy | idle
}
