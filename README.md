<p align="center"><img src="docs/images/icon.png" width="72" alt="Transpose icon"></p>

<h1 align="center">Transpose</h1>
<p align="center">Select. Circle. Translate.</p>
<p align="center"><a href="https://github.com/Ryanhu2001/Transpose/releases/latest">Download for Mac</a> · <a href="README.zh-CN.md">简体中文</a> · <a href="docs/installation.md">Installation</a> · <a href="docs/privacy.md">Privacy</a></p>

A macOS menu bar translation tool. Select text to reveal one small translation button, or press **⌥S** and draw around text on screen. Read the result beside the original, pin it, copy it or resize it.

## Features

- Automatic selection button and freeform screen OCR.
- Retained selection outline and a pinnable, resizable translation window.
- Chinese and English settings, with single-line navigation.
- Apple Translation, DeepSeek, OpenRouter, custom APIs and local CLI tools.
- Personal glossary and AI writing preferences.
- Settings on app launch; optional launch at login.
- In-app update checks and signed downloads; online updates start with the next signed release.

Cross-app behavior depends on macOS permissions and the source app.

## Build

Requires **Apple Silicon**, **Node.js 22.14+**, stable **Rust**, and **Swift 6 / macOS SDK 26.4+**. Runtime target: macOS 14+; Apple Translation: macOS 15+.

```sh
git clone https://github.com/Ryanhu2001/Transpose.git
cd Transpose
npm ci
./verify.sh
./build.sh
open dist/Transpose.app
```

Use `npm run tauri dev` for desktop development. `npm run build` builds the frontend; `npm run tauri build -- --bundles app` builds the desktop bundle. `npm run dev` is browser-only; `?preview=1` explicitly enables sample data.

```text
src/                              React + TypeScript
src-tauri/                        Rust + Tauri
native/Sources/TransposeNative/   Swift macOS bridge
tests/frontend/                   Frontend checks
tests/native/                     Native offline checks
scripts/                          Build support
assets/                           Icons and platform resources
docs/                             Guides
```

See [Development](docs/development.md) and [Contributing](CONTRIBUTING.md).

## Permissions and services

Allow **Accessibility** for selection and **Screen Recording** for screen OCR. Captures are processed locally; translation services receive text, not screenshots. API keys are stored in macOS Keychain.

Apple language packs are downloaded separately. Apple Translation does not apply the AI glossary. Other services use your account and quotas; OpenRouter free routes have limits. See [Services](docs/services.md).

Downloads support Apple Silicon and are not notarized. See [Installation](docs/installation.md) for opening instructions. No Intel or other-OS support is claimed.

## License

[MIT](LICENSE) © Ryan.
