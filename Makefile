.PHONY: build tasks test clean

# Limbo Tasks: Swift menu bar list of live Claude sessions. Needs only swiftc, not Go.
tasks:
	mkdir -p bin
	swiftc -O -o bin/limbo-tasks tasks/main.swift -framework AppKit

# Cross-compile for Mahesh's Mac (Apple Silicon).
build:
	mkdir -p bin
	GOOS=darwin GOARCH=arm64 go build -o bin/session-watcher ./cmd/session-watcher

test:
	go test ./...

clean:
	rm -rf bin
