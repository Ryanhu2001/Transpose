# Native bridge

The Tauri process statically links `TransposeNative`. macOS permissions, OCR, Keychain, Apple Translation and capture stay in Swift; settings and results use the same TypeScript frontend.

- Tauri settings: `native_request({ action, payload })`; updates arrive on `native:event`.
- Native result panel: local bundled WKWebView, `transpose` message handler, `transpose:native` responses. Only result controls and snapshots are allowed.
- C ABI: `transpose_native_start`, `transpose_native_command`, `transpose_native_stop`, `transpose_native_is_login_launch`.
- Requests have `id`, `action`, `payload`; responses have `type: response`, the same `id`, `ok`, and `data` or `error`.
- Successful responses contain `{ app, result }`. See `src/lib/types.ts` for the shared data shape.
- Events: `snapshot`, `result`, `open_settings`, `hide_settings`, `quit`, `restart`.
- `app_restart` is a settings-only action. `permissions.screenRecordingNeedsRestart` marks a capture denial in a process whose permission preflight is already allowed; `screenRecording` remains false until a new process can use that grant.
- No API key values are returned. Connection edits include their provider/endpoint context.

Swift copies incoming strings before returning, runs commands on the main actor, and streams JSON through the callback. Rust correlates requests without blocking the UI thread. Result content is plain text; bundled pages reject remote navigation.

`--smoke-test` exercises the packaged frontend and native snapshot in an isolated settings suite. It does not register global input, change login settings, or access real keys.

`--capture-permission-probe` uses the same isolation, registers no global input, and reports a `permission_probe` event with `{preflight,effective,errorCode?}`. When preflight allows capture, it only asks ScreenCaptureKit for available content; it captures no pixels and returns no window details.
