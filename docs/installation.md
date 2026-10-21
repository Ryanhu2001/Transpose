# Installation

[Download the latest release](https://github.com/Ryanhu2001/Transpose/releases/latest), or [build from source](development.md).

## Mac

Requires **Apple Silicon / macOS 14+**. Apple Translation needs **macOS 15+** and downloaded language packs. No Intel build is provided.

Open the DMG and drag **Transpose.app** to **Applications**, or extract the ZIP. Quit an older copy before replacing it.

Downloads are ad-hoc signed and **not notarized**. If macOS blocks opening, attempt to open the app, then use **System Settings → Privacy & Security → Open Anyway** for Transpose. Do not disable Gatekeeper globally.

Allow **Accessibility** for selected text and **Screen Recording** for screen OCR. Keep one installed copy in Applications. Replacing an ad-hoc signed build may require granting permissions again; reopen the app if screen access remains denied.

## Windows

Requires **Windows 10/11 x64**. Windows support is experimental. Run the **Windows-x64-setup.exe** installer; it installs WebView2 if needed. Apple Translation is available only on Mac, so configure an API or local CLI service.

The installer is **not Authenticode signed** and Windows may show an unknown-publisher warning. Verify that the download came from this repository before choosing to run it.

## Configure

Opening the app displays Settings. Choose **Services / 翻译服务**, save your service credentials and test the connection. Apple language packs are prepared separately. **General → Start at login / 通用 → 开机自启动** is optional.

## Controls

| Action | Control |
| --- | --- |
| Translate selected text | Click the small **T / 译** button |
| Freeform capture | **⌥S** on Mac / **Alt+S** on Windows, draw and release |
| Rectangular capture | Hold **Shift** while drawing |
| Keep a result visible | Pin |
| Move a result | Drag its header |
| Resize a result | Drag its edge or bottom-right corner |
| Close or cancel | **Esc** or **×** |

Some apps do not expose selected text; use screen OCR in those cases. For connection errors, check the model, credentials and provider quota. See [Services](services.md).

## Updates

The original public v0.6.0 Mac release has no updater and needs one manual installation of v0.7.0; recent v0.6.0 preview builds include the updater and can upgrade in the app.

Open **Settings → General → App Updates / 设置 → 通用 → 应用更新** to check, download and install a newer version. Downloads are verified with the app's update signing key. These signatures are separate from macOS notarization and Windows publisher signing.

Updates become available when a newer release includes packages for your platform and its update manifest. You can also install the latest release manually.
