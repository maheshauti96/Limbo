// Package recency is the 48h "user was active" window for limbo.
package recency

import "time"

// Window is how far back a thread may have last user activity.
const Window = 48 * time.Hour

// Recent reports whether t is within Window of now.
func Recent(t, now time.Time) bool {
	if t.IsZero() {
		return false
	}
	if now.IsZero() {
		now = time.Now()
	}
	age := now.Sub(t)
	return age >= 0 && age <= Window
}
