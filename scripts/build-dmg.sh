#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$PROJECT_ROOT/release/Recall.app}"
OUTPUT="${2:-$PROJECT_ROOT/release/Recall-macOS.dmg}"
VENV="$PROJECT_ROOT/.test-data/dmg-venv"
if [ ! -x "$VENV/bin/dmgbuild" ]; then
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install 'dmgbuild==1.6.7'
fi
codesign --verify --deep --strict "$APP"
swift "$PROJECT_ROOT/scripts/artwork/make-dmg-background.swift" "$PROJECT_ROOT/macOS/Artwork"
"$VENV/bin/dmgbuild" -s "$PROJECT_ROOT/scripts/dmg-settings.py" -D app="$APP" -D artwork="$PROJECT_ROOT/macOS/Artwork" Recall "$OUTPUT"
hdiutil verify "$OUTPUT"
