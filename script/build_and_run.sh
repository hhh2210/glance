#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:---run}"
APP_NAME="Glance Fork"
BUILD_DIR="${GLANCE_BUILD_DIR:-$ROOT_DIR/build/DerivedData}"
APP_BUNDLE="$BUILD_DIR/Build/Products/Debug/$APP_NAME.app"

case "$MODE" in
  --run|--build-only|--verify|--debug|--logs|--telemetry) ;;
  *) echo "usage: $0 [--run|--build-only|--verify|--debug|--logs|--telemetry]" >&2; exit 2 ;;
esac

if [[ "$MODE" != --build-only ]]; then
  # The fork has its own executable name; never stop upstream Glance.
  pkill -x "$APP_NAME" 2>/dev/null || true
fi

xcodebuild -quiet -project "$ROOT_DIR/glance.xcodeproj" -scheme glance \
  -configuration Debug -destination 'platform=macOS' -derivedDataPath "$BUILD_DIR" \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build

[[ "$MODE" == --build-only ]] && exit 0
if [[ "$MODE" == --debug ]]; then
  exec lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
fi

/usr/bin/open -n -g "$APP_BUNDLE"
case "$MODE" in
  --verify)
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  --logs)
    exec /usr/bin/log stream --info --style compact --predicate 'process == "Glance Fork"'
    ;;
  --telemetry)
    exec /usr/bin/log stream --info --style compact --predicate 'subsystem == "io.github.hhh2210.glance"'
    ;;
esac
