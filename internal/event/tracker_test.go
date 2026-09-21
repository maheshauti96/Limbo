package event

import (
	"testing"

	"github.com/maheshauti/session-watcher/internal/obs"
)

func TestTracker_transitions(t *testing.T) {
	var got []Event
	tr := NewTracker(func(ev Event) error {
		got = append(got, ev)
		return nil
	})
	// stable timestamps for assertions
	n := 0
	tr.now = func(tool, label, state string) Event {
		n++
		return Event{Tool: tool, Label: label, State: state, TS: "t", Source: Source}
	}

	// idle
	if err := tr.Apply([]obs.Observation{{Tool: "cursor", Label: "Cursor", State: "idle"}}); err != nil {
		t.Fatal(err)
	}
	assertStates(t, got, []string{"idle"})

	// same idle — no emit
	got = nil
	if err := tr.Apply([]obs.Observation{{Tool: "cursor", Label: "Cursor", State: "idle"}}); err != nil {
		t.Fatal(err)
	}
	if len(got) != 0 {
		t.Fatalf("expected dedup, got %#v", got)
	}

	// become running worker
	got = nil
	if err := tr.Apply([]obs.Observation{{Tool: "cursor", Label: "alpha", State: "running"}}); err != nil {
		t.Fatal(err)
	}
	// Cursor disappears from active → finished; alpha → running
	assertHas(t, got, "cursor", "Cursor", "finished")
	assertHas(t, got, "cursor", "alpha", "running")

	// no Cursor → finish alpha, stay quiet on repeat
	got = nil
	if err := tr.Apply(nil); err != nil {
		t.Fatal(err)
	}
	assertHas(t, got, "cursor", "alpha", "finished")

	got = nil
	if err := tr.Apply(nil); err != nil {
		t.Fatal(err)
	}
	if len(got) != 0 {
		t.Fatalf("expected quiet after finished, got %#v", got)
	}
}

func TestTracker_multiTool(t *testing.T) {
	var got []Event
	tr := NewTracker(func(ev Event) error {
		got = append(got, ev)
		return nil
	})
	tr.now = func(tool, label, state string) Event {
		return Event{Tool: tool, Label: label, State: state, TS: "t", Source: Source}
	}

	if err := tr.Apply([]obs.Observation{
		{Tool: "cursor", Label: "Cursor", State: "idle"},
		{Tool: "claude", Label: "demo", State: "running"},
		{Tool: "codex", Label: "Codex", State: "idle"},
	}); err != nil {
		t.Fatal(err)
	}
	assertHas(t, got, "cursor", "Cursor", "idle")
	assertHas(t, got, "claude", "demo", "running")
	assertHas(t, got, "codex", "Codex", "idle")

	// Same label different tools stay independent
	got = nil
	if err := tr.Apply([]obs.Observation{
		{Tool: "cursor", Label: "demo", State: "running"},
		{Tool: "claude", Label: "demo", State: "idle"},
	}); err != nil {
		t.Fatal(err)
	}
	assertHas(t, got, "cursor", "Cursor", "finished")
	assertHas(t, got, "codex", "Codex", "finished")
	assertHas(t, got, "cursor", "demo", "running")
	assertHas(t, got, "claude", "demo", "idle")
}

func assertStates(t *testing.T, evs []Event, states []string) {
	t.Helper()
	if len(evs) != len(states) {
		t.Fatalf("len=%d want %d: %#v", len(evs), len(states), evs)
	}
	for i, s := range states {
		if evs[i].State != s {
			t.Fatalf("ev[%d].State=%s want %s", i, evs[i].State, s)
		}
		if evs[i].Source != Source {
			t.Fatalf("bad source: %#v", evs[i])
		}
	}
}

func assertHas(t *testing.T, evs []Event, tool, label, state string) {
	t.Helper()
	for _, e := range evs {
		if e.Tool == tool && e.Label == label && e.State == state {
			return
		}
	}
	t.Fatalf("missing {%s,%s,%s} in %#v", tool, label, state, evs)
}
