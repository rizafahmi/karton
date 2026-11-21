#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ "${BUILD:-0}" = "1" ] || [ ! -d "$ROOT/.build/Karton.app" ]; then
    sh "$ROOT/build.sh"
fi
INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
mkdir -p "$INSTALL_DIR"
DEST="$INSTALL_DIR/Karton.app"
rm -rf "$DEST"
cp -R "$ROOT/.build/Karton.app" "$DEST"
codesign --force --sign - "$DEST"
codesign --verify --strict "$DEST"
printf 'Installed %s\n' "$DEST"
