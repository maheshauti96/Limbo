.PHONY: build test clean

# Cross-compile for Mahesh's Mac (Apple Silicon).
build:
	mkdir -p bin
	GOOS=darwin GOARCH=arm64 go build -o bin/session-watcher ./cmd/session-watcher

test:
	go test ./...

clean:
	rm -rf bin
