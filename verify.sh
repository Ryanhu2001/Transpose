#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$PROJECT_DIR/scripts/common.sh"

usage() {
    cat <<'USAGE'
Usage: ./verify.sh [--output-dir PATH] [--native-only]

Run the Swift bridge checks, TypeScript checks, frontend tests, and Rust tests.
Default native output: .build/verification (or TRANSPOSE_VERIFY_DIR).
--native-only runs the standalone Swift checks without Node or Cargo.
Requires macOS SDK 26.4+. Tests never call translation services or use API keys.
The first npm/Cargo dependency installation may require network access.
USAGE
}
VERIFY_DIR="${TRANSPOSE_VERIFY_DIR:-$PROJECT_DIR/.build/verification}"
NATIVE_ONLY=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir) transpose_require_value "$@"; VERIFY_DIR="$2"; shift 2 ;;
        --native-only) NATIVE_ONLY=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) transpose_fail "Unknown argument: $1" ;;
    esac
done
transpose_check_toolchain
mkdir -p "$VERIFY_DIR"
NATIVE_DIR="$PROJECT_DIR/native/Sources/TransposeNative"
xcrun swiftc -parse-as-library -swift-version 5 -O -sdk "$TRANSPOSE_SDK_PATH" \
    -target arm64-apple-macosx14.0 \
    "$NATIVE_DIR/core/Models.swift" \
    "$NATIVE_DIR/core/L10n.swift" \
    "$NATIVE_DIR/bridge/BridgeModels.swift" \
    "$NATIVE_DIR/platform/LoginItemManager.swift" \
    "$NATIVE_DIR/translation/TranslationService.swift" \
    "$NATIVE_DIR/translation/CLIRunner.swift" \
    "$NATIVE_DIR/translation/CLIProbe.swift" \
    "$NATIVE_DIR/core/GlossaryStore.swift" \
    "$NATIVE_DIR/core/TranslationPromptBuilder.swift" \
    "$NATIVE_DIR/platform/KeychainStore.swift" \
    "$NATIVE_DIR/platform/OCRService.swift" \
    "$NATIVE_DIR/platform/ResultPlacement.swift" \
    "$NATIVE_DIR/platform/CaptureStroke.swift" \
    "$NATIVE_DIR/platform/CapturePermission.swift" \
    "$NATIVE_DIR/translation/AppleTranslationBackend.swift" \
    "$PROJECT_DIR"/tests/native/*.swift \
    -o "$VERIFY_DIR/NativeVerification"
"$VERIFY_DIR/NativeVerification"

if [[ "$NATIVE_ONLY" == false ]]; then
    transpose_check_node
    transpose_setup_rust
    transpose_install_frontend
    (
        cd "$PROJECT_DIR"
        npm run typecheck
        npm test
        # Cargo resolves bundled WebView resources even when running tests.
        npm run build
        cargo test --manifest-path src-tauri/Cargo.toml
    )
fi
