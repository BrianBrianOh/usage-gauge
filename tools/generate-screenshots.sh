#!/bin/zsh
set -euo pipefail
TASK_DIR="${0:A:h:h}"
mkdir -p "$TASK_DIR/dist" "$TASK_DIR/docs" "$TASK_DIR/.swift-module-cache"
swiftc -swift-version 5 -parse-as-library -O -DDEMO_RENDER -DSCREENSHOT_RENDER \
  -target "$(uname -m)-apple-macos14.0" -module-cache-path "$TASK_DIR/.swift-module-cache" \
  "$TASK_DIR/native/Gauge.swift" "$TASK_DIR/native/ClaudeService.swift" "$TASK_DIR/native/DataValidity.swift" \
  "$TASK_DIR/native/Rotary.swift" "$TASK_DIR/native/Instruments.swift" "$TASK_DIR/native/Mini.swift" "$TASK_DIR/native/HUDContrast.swift" \
  "$TASK_DIR/tools/Documentation.swift" "$TASK_DIR/tools/Screenshots.swift" -o "$TASK_DIR/dist/generate-screenshots" \
  -framework AppKit -framework SwiftUI -framework Charts -framework WebKit -framework ScreenCaptureKit -framework ImageIO
"$TASK_DIR/dist/generate-screenshots" "$TASK_DIR/docs" "$@"
