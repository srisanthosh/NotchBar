#!/bin/zsh
# Builds NotchBar.app into ./build. Usage: ./build.sh [--run]
#
# Signs with the "NotchBar Local Signing" certificate when it exists (see
# scripts/setup-signing.sh), so macOS keeps its permissions across rebuilds.
# Otherwise it signs ad hoc, and permissions must be granted again after each build.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release

APP=build/NotchBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/NotchBar "$APP/Contents/MacOS/NotchBar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

IDENTITY="NotchBar Local Signing"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  codesign --force --sign "$IDENTITY" --identifier com.local.notchbar "$APP" >/dev/null
  echo "Built $APP (signed with \"$IDENTITY\")"
else
  codesign --force --sign - --identifier com.local.notchbar "$APP" >/dev/null
  echo "Built $APP (ad hoc: run scripts/setup-signing.sh so permissions survive rebuilds)"
fi

if [[ "${1:-}" == "--run" ]]; then
  pkill -x NotchBar 2>/dev/null || true
  open "$APP"
fi
