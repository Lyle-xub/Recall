#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$PROJECT_ROOT/scripts/prepare-native-runtimes.py"
python3 "$PROJECT_ROOT/scripts/prepare-ocr-runtime.py"
python3 "$PROJECT_ROOT/scripts/prepare-neural-ocr.py"
cd "$PROJECT_ROOT/macOS"
swift build -c release
APP="$PROJECT_ROOT/release/Recall.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Recall "$APP/Contents/MacOS/Recall"
cp -R "$PROJECT_ROOT/shared/models" "$APP/Contents/Resources/"
cp -R "$PROJECT_ROOT/shared/licenses" "$APP/Contents/Resources/"
if [ -d "$PROJECT_ROOT/native-runtimes/macos-arm64" ]; then
  mkdir -p "$APP/Contents/Resources/runtimes"
  cp -R "$PROJECT_ROOT/native-runtimes/macos-arm64/" "$APP/Contents/Resources/runtimes/"
fi
cp "$PROJECT_ROOT/macOS/Artwork/Recall.icns" "$APP/Contents/Resources/"
cp "$PROJECT_ROOT/macOS/Artwork/RecallTemplate"*.png "$APP/Contents/Resources/"
cp "$PROJECT_ROOT/macOS/Artwork/Recall-1024.png" "$APP/Contents/Resources/"
cp "$PROJECT_ROOT/macOS/Artwork/IridescentGlass.png" "$APP/Contents/Resources/"
cp "$PROJECT_ROOT/macOS/Artwork/Recall-Opening.wav" "$APP/Contents/Resources/"
cp "$PROJECT_ROOT/macOS/Artwork/Recall.icon/Assets/Halo.png" "$APP/Contents/Resources/RecallHalo.png"
xcrun actool "$PROJECT_ROOT/macOS/Artwork/Recall.icon" --compile "$APP/Contents/Resources" --output-format human-readable-text --notices --warnings --output-partial-info-plist .build/icon-info.plist --app-icon Recall --include-all-app-icons --minimum-deployment-target 15.0 --platform macosx
# Keep the full-resolution fallback alongside the native layered asset catalog.
cp "$PROJECT_ROOT/macOS/Artwork/Recall.icns" "$APP/Contents/Resources/"
cp Info.plist "$APP/Contents/Info.plist"
python3 "$PROJECT_ROOT/scripts/sign-macos.py" "$APP"
printf 'Built: %s\n' "$APP"
