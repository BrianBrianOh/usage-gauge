#!/bin/zsh
set -euo pipefail
TASK_DIR="${0:A:h:h}"
GAUGE_APP="$TASK_DIR/dist/Usage Gauge.app"
mkdir -p "$GAUGE_APP/Contents/MacOS" "$GAUGE_APP/Contents/Resources" "$TASK_DIR/.swift-module-cache"
swiftc -swift-version 5 -parse-as-library -O -target "$(uname -m)-apple-macos14.0" \
  -module-cache-path "$TASK_DIR/.swift-module-cache" \
  "$TASK_DIR/native/Gauge.swift" "$TASK_DIR/native/ClaudeService.swift" "$TASK_DIR/native/DataValidity.swift" "$TASK_DIR/native/Rotary.swift" "$TASK_DIR/native/Instruments.swift" "$TASK_DIR/native/Mini.swift" "$TASK_DIR/native/HUDContrast.swift" -o "$GAUGE_APP/Contents/MacOS/UsageGauge" \
  -framework AppKit -framework SwiftUI -framework Charts -framework WebKit -framework ScreenCaptureKit
cp "$TASK_DIR/native/Info.plist" "$GAUGE_APP/Contents/Info.plist"
cp "$TASK_DIR/bridge.py" "$GAUGE_APP/Contents/Resources/bridge.py"
cp "$TASK_DIR/native/native_refresh.py" "$GAUGE_APP/Contents/Resources/native_refresh.py"
cp "$TASK_DIR/native/claude_usage.py" "$GAUGE_APP/Contents/Resources/claude_usage.py"
rm -f "$GAUGE_APP/Contents/Resources/seed-state.json"
mkdir -p "$TASK_DIR/dist/AppIcon.iconset"
swift -module-cache-path "$TASK_DIR/.swift-module-cache" "$TASK_DIR/native/Icon.swift" "$TASK_DIR/dist/AppIcon.iconset/icon_512x512@2x.png"
python3 "$TASK_DIR/native/pack_icon.py" "$TASK_DIR/dist/AppIcon.iconset" "$GAUGE_APP/Contents/Resources/AppIcon.icns"
plutil -lint "$GAUGE_APP/Contents/Info.plist"
xattr -cr "$GAUGE_APP"
codesign --force --sign - "$GAUGE_APP"
codesign --verify --deep --strict "$GAUGE_APP"
print "$GAUGE_APP"
