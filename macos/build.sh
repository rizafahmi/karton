#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ARCH=$(uname -m)
swift build --package-path "$ROOT" -c release -Xswiftc -target -Xswiftc "$ARCH-apple-macosx27.0"
APP="$ROOT/.build/Elixir Canvas.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Fonts"
cp "$ROOT/.build/release/CanvasApp" "$APP/Contents/MacOS/CanvasApp"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/Fonts/"* "$APP/Contents/Resources/Fonts/"
# Seal the assembled bundle, not only the standalone linker-signed executable.
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
printf 'Built %s\n' "$APP"
