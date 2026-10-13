#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:---run}"
APP_NAME="Glance Fork"
BUILD_DIR="${GLANCE_BUILD_DIR:-$ROOT_DIR/build/DerivedData}"
APP_BUNDLE="$BUILD_DIR/Build/Products/Debug/$APP_NAME.app"
GLANCE_TEAM="${GLANCE_DEVELOPMENT_TEAM:-}"

case "$MODE" in
  --run|--build-only|--verify|--debug|--logs|--telemetry) ;;
  *) echo "usage: $0 [--run|--build-only|--verify|--debug|--logs|--telemetry]" >&2; exit 2 ;;
esac

if [[ -n "$GLANCE_TEAM" ]]; then
  if [[ ! "$GLANCE_TEAM" =~ ^[A-Z0-9]{10}$ ]]; then
    echo 'GLANCE_DEVELOPMENT_TEAM must be the 10-character Team ID shown by Xcode.' >&2
    exit 2
  fi
  SIGNING_ARGS=(
    CODE_SIGN_STYLE=Automatic 'CODE_SIGN_IDENTITY=Apple Development'
    "DEVELOPMENT_TEAM=$GLANCE_TEAM"
    "CODE_SIGN_ENTITLEMENTS=$ROOT_DIR/script/development.entitlements"
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration
  )
else
  if [[ "$MODE" != --build-only ]]; then
    echo 'Glance needs a development signature to initialize its protected Keychain store.' >&2
    echo 'Sign in under Xcode → Settings → Apple Accounts, then run with GLANCE_DEVELOPMENT_TEAM=<Team ID>.' >&2
    echo 'Use --build-only for an ad-hoc compile check; it cannot validate credential setup.' >&2
    exit 2
  fi
  SIGNING_ARGS=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=)
fi

xcodebuild -quiet -project "$ROOT_DIR/glance.xcodeproj" -scheme glance \
  -configuration Debug -destination 'platform=macOS' -derivedDataPath "$BUILD_DIR" \
  "${SIGNING_ARGS[@]}" build

if [[ -n "$GLANCE_TEAM" ]]; then
  /usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"
  [[ -s "$APP_BUNDLE/Contents/embedded.provisionprofile" ]] || {
    echo 'Development build is missing its provisioning profile; not launching.' >&2
    exit 1
  }
fi

[[ "$MODE" == --build-only ]] && exit 0
# Keep a running app intact if compilation, signing, or profile validation fails.
# The fork has its own executable name; never stop upstream Glance.
pkill -x "$APP_NAME" 2>/dev/null || true
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
