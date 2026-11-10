#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ "${BUILD:-0}" = "1" ] || [ ! -d "$ROOT/.build/Canvas.app" ]; then
    sh "$ROOT/build.sh"
fi
INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
mkdir -p "$INSTALL_DIR"
DEST="$INSTALL_DIR/Canvas.app"
rm -rf "$DEST"
cp -R "$ROOT/.build/Canvas.app" "$DEST"
codesign --force --sign - "$DEST"
codesign --verify --strict "$DEST"
printf 'Installed %s\n' "$DEST"
