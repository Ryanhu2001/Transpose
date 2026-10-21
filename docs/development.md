# Development

The app uses Tauri + TypeScript with a Swift macOS bridge.

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

## Verification

Offline checks do not contact paid services, read real keys or download language packs. They do not replace testing on a permitted Mac. Check launch/reopen and login behavior; selection and capture across apps; resize, pin and focus; both UI languages; glossary edits; Apple language preparation. Test multiple displays and scaling when changing capture geometry.

Use the final bundle for privacy permissions. Rebuilding an ad-hoc signed app may invalidate an earlier permission entry. Live API/CLI tests use your account and may incur provider charges.

## Branches and releases

Use a local `dev` branch for development. Only `main` is kept permanently on the remote. Submit feature branches or forks through PRs to `main`, then remove merged remote feature branches.

CI verifies and builds `main` and PRs. It does not publish. Tags and downloadable releases require a separate maintainer decision; do not move old tags or replace old assets. Future release notes should list the changes, download requirements and signing status briefly.

Keep generated bundles, caches, `node_modules`, Rust targets, credentials and private preferences out of Git.
