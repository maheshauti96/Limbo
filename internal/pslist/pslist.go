// Package pslist obtains process command lines for detection.
package pslist

import (
	"bytes"
	"fmt"
	"os/exec"
	"runtime"
)

// Lister returns a multi-line process listing.
// Prefer `pid=,command=` / `pid=,args=` so Claude/Grok can fall back to
// ListingHasPID when Signal(0) is inconclusive.
type Lister func() (string, error)

// Default runs `ps` appropriate for the OS and returns pid + command lines.
func Default() (string, error) {
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "darwin":
		// Full command line with PID; verified signals match on path / argv tokens.
		cmd = exec.Command("ps", "-ax", "-o", "pid=,command=")
	default:
		// Linux (box tests / CI): still usable; macOS app paths won't match.
		cmd = exec.Command("ps", "-ax", "-o", "pid=,args=")
	}
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return "", fmt.Errorf("ps: %w (%s)", err, stderr.String())
	}
	return stdout.String(), nil
}
