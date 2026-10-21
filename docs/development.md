# Development

The app uses Tauri + TypeScript, a Swift macOS bridge and a Rust Windows backend.

## Toolchain

Apple Silicon Mac, Node.js **22.14+**, stable Rust, Swift 6 and **macOS SDK 26.4+**. Runtime target: macOS 14+; Apple Translation: macOS 15+. Tauri uses the macOS system webview.

## Layout

| Path | Purpose |
| --- | --- |
| `src/` | React + TypeScript settings, localization and native client |
| `src-tauri/` | Rust desktop host and Tauri configuration |
| `native/Sources/TransposeNative/` | Swift selection, capture, OCR, translation, Keychain and floating windows |
| `native/Package.swift` | Native bridge package |
| `tests/frontend/`, `tests/native/` | Frontend and native checks |
| `scripts/` | Build and verification support |
| `assets/` | Icons and platform resources |
| `docs/` | Guides |

The Swift module is **TransposeNative**. The existing bundle identifier `dev.ryan.TranslateAnywhere` and Keychain service `dev.ryan.TranslateAnywhere.api` remain compatibility identifiers for preferences, permissions and saved keys.

## Commands

```sh
npm ci
npm run tauri dev
```

Production build and checks:

```sh
./verify.sh
./build.sh
open dist/Transpose.app
```

- `./verify.sh`: frontend type checking/tests, native offline checks and Rust tests. `--native-only` runs only Swift checks.
- `./build.sh`: builds the native bridge and Tauri bundle, then copies it to `dist/Transpose.app`. `--output PATH.app` changes the destination; `--scratch-path PATH` changes the Cargo target directory.
- `npm run build`: frontend build.
- `npm run tauri build -- --bundles app`: desktop bundle.
- `npm run dev`: browser frontend only. `?preview=1` displays explicitly marked sample data without native access.

Build scripts use project-local caches under `.build/`. Builds do not grant privacy permissions, enable login startup or notarize the app.

## Windows builds

Windows builds are experimental. Use Windows 10/11 x64, Node.js **22.14+**, stable Rust with the MSVC toolchain, Visual Studio C++ Build Tools and WebView2. Apple Translation and the Swift bridge remain macOS-only.

```powershell
npm ci
npm run typecheck
npm test
npm run build
cargo test --manifest-path src-tauri/Cargo.toml --target x86_64-pc-windows-msvc --locked
npm run tauri -- build --target x86_64-pc-windows-msvc --bundles nsis --ci
```

Tauri merges `src-tauri/tauri.windows.conf.json` automatically. The Windows workflow builds an unsigned NSIS installer, tests startup, real mouse dragging and resizing, screen capture, OCR and cross-process selection, then uploads the installer and reports. It does not publish a release. Real applications and multiple displays still need acceptance testing.

## Signed updates

Settings checks for updates and installs only after confirmation. Normal builds need no signing key. The manual **Prepare signed updates** workflow uses an existing version tag and the `TAURI_SIGNING_PRIVATE_KEY` repository secret to prepare macOS arm64, Windows x64 and `latest.json` artifacts. Attach these files to the matching release when publishing; the workflow never publishes or changes tags. Updater signatures do not replace OS code signing or notarization.

## Verification

Offline checks do not contact paid services, read real keys or download language packs. They do not replace testing on a permitted Mac. Check launch/reopen and login behavior; selection and capture across apps; resize, pin and focus; both UI languages; glossary edits; Apple language preparation. Test multiple displays and scaling when changing capture geometry.

Use the final bundle for privacy permissions. Rebuilding an ad-hoc signed app may invalidate an earlier permission entry. Live API/CLI tests use your account and may incur provider charges.

## Branches and releases

Use a local `dev` branch for development. Only `main` is kept permanently on the remote. Submit feature branches or forks through PRs to `main`, then remove merged remote feature branches.

CI verifies and builds `main` and PRs. It does not publish. Tags and downloadable releases require a separate maintainer decision; do not move old tags or replace old assets. Future release notes should list the changes, download requirements and signing status briefly.

Keep generated bundles, caches, `node_modules`, Rust targets, credentials and private preferences out of Git.
