#!/bin/bash
# Shared helpers for the macOS build and release scripts. Requires Bash 3.2+.

transpose_fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

transpose_require_value() {
    [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || transpose_fail "$1 requires a value."
}

transpose_read_version() {
    [[ -f "$PROJECT_DIR/VERSION" ]] || transpose_fail "Missing VERSION file."
    local value
    value="$(tr -d '\r\n' < "$PROJECT_DIR/VERSION")"
    [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || transpose_fail "VERSION must contain a release version such as 0.4.0."
    printf '%s\n' "$value"
}

transpose_check_node() {
    command -v node >/dev/null || transpose_fail "Node.js 22.14+ is required."
    command -v npm >/dev/null || transpose_fail "npm is required."
    node -e 'const [major, minor] = process.versions.node.split(".").map(Number); process.exit(major > 22 || (major === 22 && minor >= 14) ? 0 : 1)' || \
        transpose_fail "Node.js 22.14+ is required (selected: $(node --version))."
}

transpose_setup_rust() {
    # A project-local installation keeps bootstrap tooling out of global shell
    # configuration. An existing system/user Cargo installation takes priority.
    if ! command -v cargo >/dev/null; then
        local local_cargo="$PROJECT_DIR/.build/toolchains/cargo"
        local local_rustup="$PROJECT_DIR/.build/toolchains/rustup"
        [[ -x "$local_cargo/bin/cargo" && -d "$local_rustup" ]] || \
            transpose_fail "Install Rust with rustup, or provide the project-local .build/toolchains installation."
        export CARGO_HOME="$local_cargo"
        export RUSTUP_HOME="$local_rustup"
        export PATH="$CARGO_HOME/bin:$PATH"
    fi
    cargo --version >/dev/null || transpose_fail "The selected Rust toolchain is unavailable."
    export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$PROJECT_DIR/.build/tauri-target}"
}

transpose_install_frontend() {
    [[ -f "$PROJECT_DIR/package-lock.json" ]] || transpose_fail "Missing package-lock.json; run npm install and review the lockfile."
    if [[ ! -d "$PROJECT_DIR/node_modules" ]]; then
        (cd "$PROJECT_DIR" && npm ci)
    fi
}

transpose_check_toolchain() {
    [[ "$(uname -s)" == Darwin ]] || transpose_fail "Build and release require macOS."
    command -v xcrun >/dev/null || transpose_fail "Install Xcode or Xcode Command Line Tools."
    xcrun --find swift >/dev/null || transpose_fail "The selected toolchain does not provide Swift."
    local sdk_version sdk_major sdk_minor
    sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
    sdk_major="${sdk_version%%.*}"
    sdk_minor="${sdk_version#*.}"
    sdk_minor="${sdk_minor%%.*}"
    [[ "$sdk_major" =~ ^[0-9]+$ && "$sdk_minor" =~ ^[0-9]+$ ]] || transpose_fail "Cannot determine macOS SDK version: $sdk_version"
    if (( sdk_major < 26 || (sdk_major == 26 && sdk_minor < 4) )); then
        transpose_fail "macOS SDK 26.4+ is required (selected: $sdk_version). Select a newer Xcode with xcode-select or DEVELOPER_DIR."
    fi
    TRANSPOSE_SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
}
