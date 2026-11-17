.PHONY: build tasks install-tasks uninstall-tasks test clean

# The code signing identity. "-" signs locally (ad-hoc), and macOS then forgets
# Limbo Tasks' Accessibility permission after every rebuild. A stable identity
# goes in local.mk, which git ignores, e.g. SIGN = <certificate SHA-1>.
-include local.mk
SIGN ?= -

TASKS_APP := $(HOME)/Applications/Limbo Tasks.app
TASKS_AGENT := $(HOME)/Library/LaunchAgents/com.maheshauti.limbo-tasks.plist

# Install the app bundle, turn on start at login, and start it now under launchd.
install-tasks: tasks
	mkdir -p "$(TASKS_APP)/Contents/MacOS"
	cp bin/limbo-tasks "$(TASKS_APP)/Contents/MacOS/limbo-tasks"
	cp tasks/Info.plist "$(TASKS_APP)/Contents/Info.plist"
	codesign --force --sign "$(SIGN)" "$(TASKS_APP)"
	-launchctl bootout gui/$$(id -u)/com.maheshauti.limbo-tasks 2>/dev/null
	-pkill -x limbo-tasks
	"$(TASKS_APP)/Contents/MacOS/limbo-tasks" --login-item-on
	launchctl bootstrap gui/$$(id -u) "$(TASKS_AGENT)"

uninstall-tasks:
	-launchctl bootout gui/$$(id -u)/com.maheshauti.limbo-tasks 2>/dev/null
	-pkill -x limbo-tasks
	rm -f "$(TASKS_AGENT)"
	rm -rf "$(TASKS_APP)"

# Limbo Tasks: Swift menu bar list of live Claude sessions. Needs only swiftc, not Go.
tasks:
	mkdir -p bin
	swiftc -O -o bin/limbo-tasks tasks/main.swift -framework AppKit -framework SwiftUI

# Cross-compile for Mahesh's Mac (Apple Silicon).
build:
	mkdir -p bin
	GOOS=darwin GOARCH=arm64 go build -o bin/session-watcher ./cmd/session-watcher

test:
	go test ./...

clean:
	rm -rf bin
