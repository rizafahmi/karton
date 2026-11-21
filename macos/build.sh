#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ARCH=$(uname -m)
swift build --package-path "$ROOT" -c release -Xswiftc -target -Xswiftc "$ARCH-apple-macosx27.0"
rm -rf "$ROOT/.build/Elixir Canvas.app" "$ROOT/.build/Canvas.app"
APP="$ROOT/.build/Karton.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Fonts"
cp "$ROOT/.build/release/CanvasApp" "$APP/Contents/MacOS/CanvasApp"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/Resources/Fonts/"* "$APP/Contents/Resources/Fonts/"
for bundle in "$ROOT/.build/release/"*.bundle; do
  if [ -d "$bundle" ]; then
    cp -R "$bundle" "$APP/Contents/Resources/"
  fi
done
# Seal the assembled bundle, not only the standalone linker-signed executable.
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
printf 'Built %s\n' "$APP"
