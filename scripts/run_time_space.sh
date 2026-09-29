#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
SPACE_CONFIGURATION="${SPACE_CONFIGURATION:-release}"
swift build --configuration "$SPACE_CONFIGURATION" --product TimeSinkSpace
SPACE_APP="$PROJECT_ROOT/.build/TimeSinkSpace.app"
mkdir -p "$SPACE_APP/Contents/MacOS"
cp ".build/$SPACE_CONFIGURATION/TimeSinkSpace" "$SPACE_APP/Contents/MacOS/TimeSinkSpace"
cat > "$SPACE_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>TimeSinkSpace</string>
    <key>CFBundleIdentifier</key><string>dev.timesink.spaceprototype</string>
    <key>CFBundleName</key><string>TimeSink Space</string>
    <key>CFBundleDisplayName</key><string>TimeSink 时间空间</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$SPACE_APP"
open "$SPACE_APP"
