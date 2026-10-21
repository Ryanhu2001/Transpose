#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$PROJECT_DIR/scripts/common.sh"

usage() {
    cat <<'USAGE'
Usage: ./build.sh [--output PATH.app] [--scratch-path PATH] [--arch arm64]

Build the Tauri + TypeScript app and its statically linked Swift bridge.
Requires macOS SDK 26.4+, Node.js 22.14+, and Rust via rustup.
Defaults: .build/tauri-target/ for Cargo and dist/Transpose.app for the app.
--scratch-path selects the Cargo target directory.

Environment overrides:
  TRANSPOSE_APP_PATH       App bundle output path
  TRANSPOSE_BUILD_DIR      Cargo target directory (also accepts CARGO_TARGET_DIR)
  TRANSPOSE_SIGN_IDENTITY  codesign identity (default: - for ad-hoc signing)

This command creates a local app. It never submits the app for notarization,
creates a Git tag, or publishes a release.
USAGE
}

APP_DIR="${TRANSPOSE_APP_PATH:-$PROJECT_DIR/dist/Transpose.app}"
SCRATCH_DIR="${TRANSPOSE_BUILD_DIR:-${CARGO_TARGET_DIR:-$PROJECT_DIR/.build/tauri-target}}"
ARCH="${TRANSPOSE_ARCH:-arm64}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output) transpose_require_value "$@"; APP_DIR="$2"; shift 2 ;;
        --scratch-path) transpose_require_value "$@"; SCRATCH_DIR="$2"; shift 2 ;;
        --arch) transpose_require_value "$@"; ARCH="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) transpose_fail "Unknown argument: $1" ;;
    esac
done
[[ "$ARCH" == arm64 ]] || transpose_fail "This build supports arm64 only."
[[ "$(uname -m)" == arm64 ]] || transpose_fail "Run this script on Apple Silicon, outside Rosetta."
[[ "$APP_DIR" == *.app ]] || transpose_fail "--output must name an .app bundle."
transpose_check_toolchain
transpose_check_node
transpose_setup_rust
transpose_install_frontend
VERSION="$(transpose_read_version)"

mkdir -p "$(dirname "$APP_DIR")" "$SCRATCH_DIR"
APP_DIR="$(cd "$(dirname "$APP_DIR")" && pwd)/$(basename "$APP_DIR")"
export CARGO_TARGET_DIR="$(cd "$SCRATCH_DIR" && pwd)"

# Reject mismatched versions before building an installer with misleading metadata.
(
    cd "$PROJECT_DIR"
    node --input-type=module - "$VERSION" <<'NODE'
import { readFileSync } from 'node:fs';
const expected = process.argv[2];
for (const file of ['package.json', 'src-tauri/tauri.conf.json']) {
    if (JSON.parse(readFileSync(file, 'utf8')).version !== expected) {
        throw new Error(`${file} version must match VERSION (${expected}).`);
    }
}
NODE
)

# Tauri can notarize automatically when Apple credentials are inherited. Local
# builds deliberately remove those variables; the packaging script has an
# explicit, separate --notarize action for a future release.
(
    cd "$PROJECT_DIR"
    unset APPLE_ID APPLE_PASSWORD APPLE_TEAM_ID APPLE_API_KEY APPLE_API_ISSUER APPLE_API_KEY_PATH
    export APPLE_SIGNING_IDENTITY="${TRANSPOSE_SIGN_IDENTITY:--}"
    npm run tauri build -- --bundles app
)
BUILT_APP="$CARGO_TARGET_DIR/release/bundle/macos/Transpose.app"
[[ -d "$BUILT_APP/Contents" ]] || transpose_fail "Tauri did not produce $BUILT_APP."

# Replace the requested output only after validating a complete staged bundle.
STAGE_DIR="$(mktemp -d "$(dirname "$APP_DIR")/.transpose-build.XXXXXX")"
cleanup() {
    if [[ ( -e "$STAGE_DIR/previous.app" || -L "$STAGE_DIR/previous.app" ) && ! -e "$APP_DIR" && ! -L "$APP_DIR" ]]; then
        mv "$STAGE_DIR/previous.app" "$APP_DIR"
    fi
    rm -rf "$STAGE_DIR"
}
trap cleanup EXIT
STAGED_APP="$STAGE_DIR/Transpose.app"
ditto "$BUILT_APP" "$STAGED_APP"
INFO_PLIST="$STAGED_APP/Contents/Info.plist"
plutil -lint "$INFO_PLIST"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")" == dev.ryan.TranslateAnywhere ]] || transpose_fail "Unexpected bundle identifier."
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")" == "$VERSION" ]] || transpose_fail "Built app version differs from VERSION."
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST")" == transpose ]] || transpose_fail "Unexpected app executable."
[[ "$(lipo -archs "$STAGED_APP/Contents/MacOS/transpose")" == arm64 ]] || transpose_fail "Unexpected executable architecture."
codesign --verify --deep --strict "$STAGED_APP"

if [[ -e "$APP_DIR" || -L "$APP_DIR" ]]; then
    mv "$APP_DIR" "$STAGE_DIR/previous.app"
fi
mv "$STAGED_APP" "$APP_DIR"
printf '\nBuilt Transpose %s: %s\n' "$VERSION" "$APP_DIR"
