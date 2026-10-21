# Installation

[Download the latest release](https://github.com/Ryanhu2001/Transpose/releases/latest), or build from source with the [development guide](development.md).

## Requirements

**Apple Silicon / macOS 14+**. Apple Translation needs **macOS 15+** and downloaded language packs. No Intel build is provided.

## Install

Open the DMG and drag **Transpose.app** to **Applications**. ZIP downloads are also available. Quit an older copy before replacing it.

Downloads are ad-hoc signed and **not notarized**. If macOS blocks opening, attempt to open the app, then use **System Settings → Privacy & Security → Open Anyway** for Transpose. Do not disable Gatekeeper globally.

## Configure

Opening or reopening the app displays Settings. Login launches keep it in the menu bar. Full logout/login behavior still needs acceptance testing.

1. Allow **Accessibility** to read selections and **Screen Recording** for region OCR.
2. Choose **Services / 翻译服务**: Apple, DeepSeek, OpenRouter, Custom API or Local CLI.
3. Prepare Apple language packs, or save and test your own service credentials.
4. For everyday use, consider **General → Launch at Login / 通用 → 开机自启动**. It is optional and requires your action. Complete any macOS Login Items approval; disable it in the app or system settings at any time.

Permissions and login registration are managed by macOS. Updating an ad-hoc signed build can require checking that permission entries refer to the current app in Applications.

## Controls

| Action | Control |
| --- | --- |
| Translate selected text | Click the small **T / 译** button |
| Freeform capture | **⌥S**, draw and release |
| Rectangular capture | Hold **Shift** while drawing |
| Keep a result visible | Pin |
| Resize a result | Drag its edge or bottom-right corner |
| Close or cancel | **Esc** or **×** |

Some apps do not expose selected text; use screen OCR in those cases. If translation fails, check the service connection, model access, language packs and provider quota. See [Services](services.md).

If Screen Recording is enabled but capture is denied, reopen Transpose from Applications. Keep one installed copy; rebuilding or replacing an ad-hoc signed app may require permission again.
