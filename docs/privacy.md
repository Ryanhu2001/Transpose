# Privacy

Transpose has no account system, built-in analytics or persistent translation-history database. It uses a Rust host, a Swift bridge on Mac and Windows system APIs. Remote providers and installed CLI tools have their own policies.

## Data flow

| Channel | Data sent |
| --- | --- |
| Apple Translation | Text stays on the Mac after language packs are installed; preparation uses Apple's download service |
| API | Source text, translation instructions, preferences and matching enabled glossary terms go to your configured endpoint |
| CLI | Text and instructions go to the selected executable, which may contact its configured provider |

**Screenshots are not uploaded.** Capture and OCR run locally; only recognized text reaches the translation channel. The retained outline does not continuously recapture the screen.

Selection detection displays a button. Translation begins when you click it or finish a screen selection. Mac uses Accessibility and Screen Recording permissions; Windows uses UI Automation, selected-text controls and screen capture. On Mac, clicking the button may use a clipboard-preserving copy fallback; automatic detection does not copy text.

## Storage

| Data | Location |
| --- | --- |
| Saved API keys | macOS Keychain or Windows Credential Manager, scoped to provider and endpoint |
| Settings and glossary | macOS preferences or Windows app data |
| Recent translation results | In-memory cache |
| Glossary exports | File you choose |
| CLI request files | Private temporary directory, removed after normal completion |

Keys are not imported automatically from shell configuration or other apps. Update checks contact GitHub for version metadata; installing an update downloads its signed package. CLI authentication and telemetry remain the CLI's responsibility; command-line text may be visible to local process tools. A forced termination can leave temporary request files.

Remove saved keys from Settings before uninstalling if you want them removed from the system credential store. Uninstalling does not necessarily remove settings, credentials, exports, system permissions or Apple's shared language packs. Revoke Mac permissions in System Settings.

Use public sample text in reports and remove keys, private endpoints and confidential content.
