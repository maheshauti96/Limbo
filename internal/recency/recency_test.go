package recency

import (
	"testing"
	"time"
)

func TestRecent(t *testing.T) {
	now := time.Date(2026, 9, 16, 12, 0, 0, 0, time.UTC)
	if !Recent(now.Add(-47*time.Hour), now) {
		t.Fatal("47h should pass")
	}
	if Recent(now.Add(-49*time.Hour), now) {
		t.Fatal("49h should fail")
	}
	if Recent(time.Time{}, now) {
		t.Fatal("zero should fail")
	}
}
