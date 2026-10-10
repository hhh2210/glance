#!/bin/bash
set -euo pipefail

# Build a universal, ad-hoc signed archive without changing the source checkout.
# DEVELOPER_DIR selects Xcode; XCODEBUILD may name an alternate xcodebuild binary.
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
output_dir="$repo_root/build/releases"
derived_data="$repo_root/build/ReleasePackaging"
expected_version=""
xcodebuild_command="${XCODEBUILD:-xcodebuild}"

usage() {
    cat <<'EOF'
Usage: tools/package-release.sh [--version VERSION] [--output DIR] [--derived-data DIR]

Builds Release for arm64 and x86_64 with a macOS 15.0 deployment target.
--version checks the app's version against a release tag; it does not override it.
--output defaults to build/releases; existing release archives are never replaced.
--derived-data defaults to build/ReleasePackaging and is retained for rebuilds.

The archive is ad-hoc signed and NOT notarized. This script does not request
credentials, remove quarantine attributes, or change Gatekeeper settings.
Set DEVELOPER_DIR to pin the Xcode installation used for the build.
EOF
}

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version|--output|--derived-data)
            [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || fail "$1 requires a value"
            case "$1" in
                --version) expected_version="$2" ;;
                --output) output_dir="$2" ;;
                --derived-data) derived_data="$2" ;;
            esac
            shift 2
            ;;
        --help|-h) usage; exit 0 ;;
        *) fail "unknown argument: $1" ;;
    esac
done

[[ "$(uname -s)" == Darwin ]] || fail 'packaging requires macOS and Xcode 26 or later'
command -v "$xcodebuild_command" >/dev/null || fail "xcodebuild not found: $xcodebuild_command"
mkdir -p "$output_dir" "$derived_data"
output_dir="$(cd "$output_dir" && pwd)"
derived_data="$(cd "$derived_data" && pwd)"

"$xcodebuild_command" -version
"$xcodebuild_command" \
    -project "$repo_root/glance.xcodeproj" \
    -scheme glance \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$derived_data" \
    'ARCHS=arm64 x86_64' \
    ONLY_ACTIVE_ARCH=NO \
    MACOSX_DEPLOYMENT_TARGET=15.0 \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY= \
    DEVELOPMENT_TEAM= \
    build

app="$derived_data/Build/Products/Release/Glance Fork.app"
plist="$app/Contents/Info.plist"
[[ -f "$plist" ]] || fail "missing built app: $app"
/usr/bin/plutil -lint "$plist"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")"
executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")"
minimum_os="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist")"
[[ "$version" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || fail "invalid release version: $version"
[[ -z "$expected_version" || "$version" == "$expected_version" ]] || \
    fail "tag version $expected_version does not match app version $version"
[[ "$bundle_id" == io.github.hhh2210.glance ]] || fail "unexpected bundle identity: $bundle_id"
[[ "$minimum_os" == 15.0 ]] || fail "unexpected deployment target: $minimum_os"
if /usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$plist" >/dev/null 2>&1; then
    fail 'the fork release must not contain an upstream Sparkle update feed'
fi
if /usr/libexec/PlistBuddy -c 'Print :keychain-access-groups' \
    "$repo_root/glance/glance.entitlements" >/dev/null 2>&1; then
    fail 'ad-hoc signing cannot use a provisioned keychain access group'
fi

# Some lipo versions parse multiple -verify_arch arguments inconsistently.
for architecture in arm64 x86_64; do
    /usr/bin/lipo "$app/Contents/MacOS/$executable" -verify_arch "$architecture"
done
architectures="$(/usr/bin/lipo -archs "$app/Contents/MacOS/$executable")"
archive_name="Glance-Fork-$version.zip"
[[ ! -e "$output_dir/$archive_name" && ! -e "$output_dir/$archive_name.sha256" ]] || \
    fail "archive already exists; choose a new --output directory: $output_dir/$archive_name"

staging_dir="$(mktemp -d "$output_dir/.glance-package.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
staged_app="$staging_dir/Glance Fork.app"
/usr/bin/ditto "$app" "$staged_app"
/usr/bin/codesign --force --sign - --timestamp=none --options runtime \
    --entitlements "$repo_root/glance/glance.entitlements" "$staged_app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$staged_app"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$staged_app" "$staging_dir/$archive_name"
(
    cd "$staging_dir"
    /usr/bin/shasum -a 256 "$archive_name" > "$archive_name.sha256"
)
mv "$staging_dir/$archive_name" "$staging_dir/$archive_name.sha256" "$output_dir/"

printf '\nPackaged %s (build %s) [%s], macOS %s+\n' "$version" "$build_number" "$architectures" "$minimum_os"
printf 'Signing: ad-hoc; notarization: none. Gatekeeper may block downloaded copies.\n'
printf 'Archive: %s/%s\n' "$output_dir" "$archive_name"
cat "$output_dir/$archive_name.sha256"
