// Package proc provides process liveness helpers for session detectors.
package proc

import (
	"os"
	"strconv"
	"strings"
	"syscall"
)

// Alive reports whether pid refers to a live process.
// Primary check: os.FindProcess + Signal(0) (Unix kill(pid, 0)).
// Fallback: process listing line whose first field is the pid.
func Alive(pid int, listing string) bool {
	if pid <= 0 {
		return false
	}
	if signalAlive(pid) {
		return true
	}
	return ListingHasPID(listing, pid)
}

func signalAlive(pid int) bool {
	p, err := os.FindProcess(pid)
	if err != nil {
		return false
	}
	err = p.Signal(syscall.Signal(0))
	return err == nil
}

// ListingHasPID reports whether listing contains a process line whose
// first whitespace-separated field equals strconv.Itoa(pid).
// Suitable for `ps -ax -o pid=,command=` style output.
func ListingHasPID(listing string, pid int) bool {
	if pid <= 0 {
		return false
	}
	needle := strconv.Itoa(pid)
	listing = strings.ReplaceAll(listing, "\r\n", "\n")
	listing = strings.ReplaceAll(listing, "\r", "\n")
	for _, line := range strings.Split(listing, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) > 0 && fields[0] == needle {
			return true
		}
	}
	return false
}
