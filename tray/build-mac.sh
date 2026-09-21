#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/tray/main.swift"
OUTDIR="$HOME/Applications/limbo.app/Contents"
BIN="$OUTDIR/MacOS/limbo"
mkdir -p "$OUTDIR/MacOS" "$OUTDIR/Resources"
cp "$ROOT/tray/Info.plist" "$OUTDIR/Info.plist"
swiftc -parse-as-library -O -o "$BIN" "$SRC" -framework AppKit
chmod +x "$BIN"
echo "built $HOME/Applications/limbo.app"
