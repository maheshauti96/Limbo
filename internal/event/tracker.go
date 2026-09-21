package event

import "github.com/maheshauti/session-watcher/internal/obs"

// key is (tool, label) for dedup.
type key struct {
	tool  string
	label string
}

// Tracker emits only on state transitions per (tool, label).
type Tracker struct {
	last map[key]string // last emitted state
	emit func(Event) error
	now  func(tool, label, state string) Event // injectable for tests
}

// NewTracker wraps an emit function with transition dedup.
func NewTracker(emitFn func(Event) error) *Tracker {
	return &Tracker{
		last: make(map[key]string),
		emit: emitFn,
		now:  New,
	}
}

// Apply compares active observations to prior state and emits transitions.
// Missing prior labels get state "finished". New/changed states emit as-is.
func (t *Tracker) Apply(observations []obs.Observation) error {
	active := make(map[key]string, len(observations))
	for _, o := range observations {
		k := key{tool: o.Tool, label: o.Label}
		active[k] = o.State
	}

	// Finish labels that disappeared
	for k, prev := range t.last {
		if prev == "finished" {
			continue
		}
		if _, ok := active[k]; !ok {
			if err := t.emitTransition(k, "finished"); err != nil {
				return err
			}
		}
	}

	// Emit new or changed active states
	for k, state := range active {
		prev, ok := t.last[k]
		if ok && prev == state {
			continue
		}
		if err := t.emitTransition(k, state); err != nil {
			return err
		}
	}
	return nil
}

func (t *Tracker) emitTransition(k key, state string) error {
	ev := t.now(k.tool, k.label, state)
	if err := t.emit(ev); err != nil {
		return err
	}
	t.last[k] = state
	// After finished, keep the key so we stay quiet (won't re-emit finished)
	// until a new non-finished state appears — Apply skips re-finish when prev==finished
	return nil
}
