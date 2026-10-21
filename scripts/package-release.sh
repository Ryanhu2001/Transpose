#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_DIR/scripts/common.sh"

usage() {
    cat <<'USAGE'
Usage: ./scripts/package-release.sh [--version VERSION] [--output-dir PATH]
                                    [--scratch-path PATH] [--app PATH.app] [--notarize]

Build and package an Apple Silicon release as ZIP + drag-to-Applications DMG.
Default output: dist/. Version comes from VERSION; --version must match that file.
With --app, package that existing bundle without rebuilding.
This is a manual packaging command; it never creates a Git tag or publishes.

Environment overrides:
  TRANSPOSE_RELEASE_DIR    Artifact directory
  TRANSPOSE_BUILD_DIR      Cargo target directory
  TRANSPOSE_SIGN_IDENTITY  Developer ID identity (default: ad-hoc signing)
  TRANSPOSE_NOTARY_PROFILE Existing notarytool Keychain profile; used only with
                           explicit --notarize and a Developer ID signature

Without --notarize the script never accesses a notary profile or submits to Apple.
USAGE
}

OUTPUT_DIR="${TRANSPOSE_RELEASE_DIR:-$PROJECT_DIR/dist}"
SCRATCH_DIR="${TRANSPOSE_BUILD_DIR:-${CARGO_TARGET_DIR:-$PROJECT_DIR/.build/tauri-target}}"
EXISTING_APP=""
REQUESTED_VERSION=""
NOTARIZE=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) transpose_require_value "$@"; REQUESTED_VERSION="$2"; shift 2 ;;
        --output-dir) transpose_require_value "$@"; OUTPUT_DIR="$2"; shift 2 ;;
        --scratch-path) transpose_require_value "$@"; SCRATCH_DIR="$2"; shift 2 ;;
        --app) transpose_require_value "$@"; EXISTING_APP="$2"; shift 2 ;;
        --notarize) NOTARIZE=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) transpose_fail "Unknown argument: $1" ;;
    esac
done
transpose_check_toolchain
VERSION="$(transpose_read_version)"
[[ -z "$REQUESTED_VERSION" || "$REQUESTED_VERSION" == "$VERSION" ]] || transpose_fail "--version must match VERSION ($VERSION)."
if [[ "$NOTARIZE" == true ]]; then
    [[ -n "${TRANSPOSE_NOTARY_PROFILE:-}" ]] || transpose_fail "--notarize requires TRANSPOSE_NOTARY_PROFILE."
    [[ -n "${TRANSPOSE_SIGN_IDENTITY:-}" && "$TRANSPOSE_SIGN_IDENTITY" != - ]] || transpose_fail "--notarize requires TRANSPOSE_SIGN_IDENTITY for Developer ID signing."
fi
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
STAGE_DIR="$(mktemp -d "$OUTPUT_DIR/.transpose-release.XXXXXX")"
trap 'rm -rf "$STAGE_DIR"' EXIT
APP_DIR="$STAGE_DIR/Transpose.app"
if [[ -n "$EXISTING_APP" ]]; then
    [[ -d "$EXISTING_APP/Contents" ]] || transpose_fail "--app must point to an existing app bundle."
    ditto "$EXISTING_APP" "$APP_DIR"
else
    "$PROJECT_DIR/build.sh" --output "$APP_DIR" --scratch-path "$SCRATCH_DIR" --arch arm64
fi

INFO_PLIST="$APP_DIR/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")" == dev.ryan.TranslateAnywhere ]] || transpose_fail "Unexpected bundle identifier."
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")" == "$VERSION" ]] || transpose_fail "App version differs from VERSION."
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST")" == transpose ]] || transpose_fail "Unexpected app executable."
[[ "$(lipo -archs "$APP_DIR/Contents/MacOS/transpose")" == arm64 ]] || transpose_fail "Expected an arm64 executable."
codesign --verify --deep --strict "$APP_DIR"

# Tauri includes the frontend as resources as well as its app icon. Limit those
# resources to generated web assets and fixed app metadata. User data, source
# maps, dependency directories, and credentials never belong in an installer.
[[ -f "$APP_DIR/Contents/Resources/frontend/index.html" ]] || transpose_fail "Missing bundled frontend/index.html."
find "$APP_DIR" -mindepth 1 -print0 > "$STAGE_DIR/bundle-entries"
while IFS= read -r -d '' entry; do
    relative_path="${entry#"$APP_DIR/"}"
    [[ ! -L "$entry" ]] || transpose_fail "Unexpected bundle symlink: $relative_path"
    case "$relative_path" in
        *node_modules*|*/.env*|*/.git*|*/.DS_Store|*/preferences*|*/settings.json|*/credentials*|*/secrets*|*.p12|*.p8|*.key|*.pem|*.log|*.map)
            transpose_fail "Private or development content in bundle: $relative_path" ;;
    esac
    case "$relative_path" in
        Contents|Contents/MacOS|Contents/Resources|Contents/_CodeSignature|Contents/Resources/en.lproj|Contents/Resources/zh-Hans.lproj|Contents/Resources/frontend|Contents/Resources/frontend/*|Contents/Resources/_up_|Contents/Resources/_up_/dist-web|Contents/Resources/_up_/dist-web/*)
            if [[ -d "$entry" ]]; then
                continue
            fi
            case "$relative_path" in
                Contents/Resources/frontend/*|Contents/Resources/_up_/dist-web/*)
                    case "$relative_path" in
                        *.html|*.css|*.js|*.json|*.svg|*.png|*.jpg|*.jpeg|*.gif|*.webp|*.avif|*.ico|*.woff|*.woff2|*.ttf|*.otf|*.txt)
                            [[ -f "$entry" ]] || transpose_fail "Invalid web resource: $relative_path" ;;
                        *) transpose_fail "Unexpected web resource: $relative_path" ;;
                    esac
                    # Print only the path on a match, never the matched secret.
                    if LC_ALL=C /usr/bin/grep -aEq '(/Users/[^/]+/|sk-[A-Za-z0-9_-]{24,}|-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----)' "$entry"; then
                        transpose_fail "Potential personal data in web resource: $relative_path"
                    fi ;;
                *) transpose_fail "Expected bundle directory: $relative_path" ;;
            esac ;;
        Contents/Info.plist|Contents/PkgInfo|Contents/MacOS/transpose|Contents/Resources/AppIcon.icns|Contents/Resources/icon.icns|Contents/Resources/LICENSE.txt|Contents/_CodeSignature/CodeResources|Contents/Resources/en.lproj/InfoPlist.strings|Contents/Resources/zh-Hans.lproj/InfoPlist.strings)
            [[ -f "$entry" ]] || transpose_fail "Expected bundle file: $relative_path" ;;
        *) transpose_fail "Unexpected bundle content: $relative_path" ;;
    esac
done < "$STAGE_DIR/bundle-entries"

# Ensure no accidental extra executable was hidden among otherwise valid assets.
find "$APP_DIR/Contents/Resources" -type f -perm -111 -print0 > "$STAGE_DIR/executable-resources"
while IFS= read -r -d '' entry; do
    transpose_fail "Unexpected executable resource: ${entry#"$APP_DIR/"}"
done < "$STAGE_DIR/executable-resources"

if [[ "$NOTARIZE" == true ]]; then
    codesign -dv "$APP_DIR" 2>&1 | /usr/bin/grep -q '^Authority=Developer ID Application:' || \
        transpose_fail "Notarization requires a Developer ID Application signature."
    NOTARY_ZIP="$STAGE_DIR/notarization.zip"
    ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$NOTARY_ZIP"
    xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$TRANSPOSE_NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP_DIR"
    xcrun stapler validate "$APP_DIR"
    spctl --assess --type execute --verbose=2 "$APP_DIR"
else
    printf 'Packaging without notarization. Gatekeeper may require Open Anyway in System Settings.\n'
fi

ASSET_NAME="Transpose-$VERSION-macOS-arm64"
ZIP_PATH="$STAGE_DIR/$ASSET_NAME.zip"
DMG_PATH="$STAGE_DIR/$ASSET_NAME.dmg"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"

DMG_ROOT="$STAGE_DIR/dmg-root"
mkdir -p "$DMG_ROOT"
ditto "$APP_DIR" "$DMG_ROOT/Transpose.app"
ln -s /Applications "$DMG_ROOT/Applications"
cat > "$DMG_ROOT/Install.txt" <<'INSTALL'
Transpose

Drag Transpose.app into Applications, then open it from Applications.
Transpose runs in the menu bar. Grant Accessibility for text selection and
Screen Recording for region OCR when prompted by the app.

将 Transpose.app 拖入 Applications，然后从“应用程序”打开。
Transpose 常驻菜单栏。划词翻译需要辅助功能权限，圈选识别需要屏幕录制权限。

Apple language packs are downloaded by macOS separately. API keys and personal
preferences are stored on your Mac and are never included in this installer.
Apple 语言包由 macOS 另外下载。安装包不包含 API 密钥、个人设置或语言包。
INSTALL
hdiutil create -quiet -volname "Transpose $VERSION" -fs HFS+ -format UDZO \
    -srcfolder "$DMG_ROOT" "$DMG_PATH"
hdiutil verify "$DMG_PATH"
if [[ "$NOTARIZE" == true ]]; then
    codesign --force --sign "${TRANSPOSE_SIGN_IDENTITY:?DMG signing requires TRANSPOSE_SIGN_IDENTITY}" --timestamp "$DMG_PATH"
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$TRANSPOSE_NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
fi

# Check the distributable ZIP after extraction as well as the original bundle.
mkdir -p "$STAGE_DIR/zip-check"
ditto -x -k "$ZIP_PATH" "$STAGE_DIR/zip-check"
codesign --verify --deep --strict "$STAGE_DIR/zip-check/Transpose.app"
mv -f "$ZIP_PATH" "$OUTPUT_DIR/$ASSET_NAME.zip"
mv -f "$DMG_PATH" "$OUTPUT_DIR/$ASSET_NAME.dmg"
(
    cd "$OUTPUT_DIR"
    shasum -a 256 "$ASSET_NAME.zip" "$ASSET_NAME.dmg" > SHA256SUMS.txt
    shasum -a 256 -c SHA256SUMS.txt
)
printf '\nRelease artifacts: %s\n' "$OUTPUT_DIR"
