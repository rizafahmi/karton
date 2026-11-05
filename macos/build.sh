#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ARCH=$(uname -m)
swift build --package-path "$ROOT" -c release -Xswiftc -target -Xswiftc "$ARCH-apple-macosx27.0"
APP="$ROOT/.build/Elixir Canvas.app"
mkdir -p "$APP/Contents/MacOS"
cp "$ROOT/.build/release/CanvasApp" "$APP/Contents/MacOS/CanvasApp"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
printf 'Built %s\n' "$APP"
