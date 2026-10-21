# Privacy

Transpose has no account system, built-in analytics or persistent translation-history database. The Tauri settings interface uses a Rust host and Swift macOS bridge; remote providers and installed CLI tools have their own policies.

## Data flow

| Channel | Data sent |
| --- | --- |
| Apple Translation | Text stays on the Mac after language packs are installed; preparation uses Apple's download service |
| API | Source text, translation instructions, preferences and matching enabled glossary terms go to your configured endpoint |
| CLI | Text and instructions go to the selected executable, which may contact its configured provider |

**Screenshots are not uploaded.** Capture and Vision OCR run locally; only recognized text reaches the translation channel. The retained outline does not continuously recapture the screen.

Selection detection displays a button. Translation begins when you click it or finish a screen selection. Accessibility reads selected text; Screen Recording is used for region capture. Explicit selection requests may use a clipboard-preserving copy fallback; automatic detection does not.

## Storage

| Data | Location |
| --- | --- |
| Saved API keys | macOS Keychain, scoped to provider and endpoint |
| Settings and glossary | Local macOS preferences |
| Recent translation results | In-memory cache |
| Glossary exports | File you choose |
| CLI request files | Private temporary directory, removed after normal completion |

Keys are not imported automatically from shell configuration or other apps. API requests use an ephemeral session. CLI authentication and telemetry remain the CLI's responsibility; command-line text may be visible to local process tools. A forced termination can leave temporary request files.

Remove saved keys from Settings before uninstalling if you want them removed from Keychain. Deleting the app alone does not remove preferences, Keychain entries, system permissions, exports or Apple's shared language packs. Revoke permissions in macOS System Settings.

Use public sample text in reports and remove keys, private endpoints and confidential content.
