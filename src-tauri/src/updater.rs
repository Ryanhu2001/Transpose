//! Settings-only signed application updates. No provider text or credentials are sent.
use serde::Serialize;
use std::{
    sync::Mutex,
    time::{Duration, Instant},
};
use tauri::{Emitter, Manager, WebviewWindow};
use tauri_plugin_updater::{Update, UpdaterExt};

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateStatus {
    phase: &'static str,
    revision: u64,
    enabled: bool,
    current_version: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    version: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    notes: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    downloaded: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    total: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error_code: Option<&'static str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    message: Option<&'static str>,
}

impl Default for UpdateStatus {
    fn default() -> Self {
        Self {
            phase: "idle",
            revision: 0,
            enabled: true,
            current_version: env!("CARGO_PKG_VERSION").into(),
            version: None,
            notes: None,
            downloaded: None,
            total: None,
            error_code: None,
            message: None,
        }
    }
}

#[derive(Default)]
struct Runtime {
    status: UpdateStatus,
    pending: Option<Update>,
    busy: bool,
}

#[derive(Default)]
pub struct AppUpdates(Mutex<Runtime>);

fn authorize(label: &str, action: &str) -> Result<(), String> {
    if label != "settings" {
        return Err("This window cannot update the application.".into());
    }
    if !matches!(action, "status" | "check" | "install") {
        return Err("Invalid update action.".into());
    }
    Ok(())
}

fn publish(app: &tauri::AppHandle, status: UpdateStatus) -> UpdateStatus {
    // All state changes and events share this path, so a reopened settings window can
    // recover the latest progress without initiating another request.
    let state = app.state::<AppUpdates>();
    let mut runtime = state.0.lock().unwrap_or_else(|e| e.into_inner());
    let mut status = status;
    status.revision = runtime.status.revision.saturating_add(1);
    runtime.status = status.clone();
    drop(runtime);
    let _ = app.emit_to("settings", "app:update", &status);
    status
}

fn fail(app: &tauri::AppHandle, code: &'static str, message: &'static str) -> UpdateStatus {
    let state = app.state::<AppUpdates>();
    let mut runtime = state.0.lock().unwrap_or_else(|e| e.into_inner());
    runtime.busy = false;
    let mut status = runtime.status.clone();
    status.phase = if code == "feed_unavailable" {
        "unavailable"
    } else {
        "error"
    };
    status.error_code = Some(code);
    status.message = Some(message);
    status.revision = status.revision.saturating_add(1);
    runtime.status = status.clone();
    drop(runtime);
    let _ = app.emit_to("settings", "app:update", &status);
    status
}

fn install_allowed(runtime: &Runtime, version: Option<&str>) -> bool {
    !runtime.busy
        && runtime
            .pending
            .as_ref()
            .is_some_and(|update| Some(update.version.as_str()) == version)
}

#[tauri::command]
pub async fn app_updates(
    window: WebviewWindow,
    action: String,
    version: Option<String>,
) -> Result<UpdateStatus, String> {
    authorize(window.label(), &action)?;
    if std::env::args().any(|arg| {
        matches!(
            arg.as_str(),
            "--smoke-test"
                | "--windows-result-test"
                | "--windows-browser-test"
                | "--windows-platform-test"
                | "--capture-permission-probe"
        )
    }) {
        return if action == "install" {
            Err("Application updates are disabled in diagnostic mode.".into())
        } else {
            Ok(UpdateStatus {
                enabled: false,
                ..UpdateStatus::default()
            })
        };
    }
    let app = window.app_handle().clone();
    let state = app.state::<AppUpdates>();
    if action == "status" {
        return Ok(state
            .0
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .status
            .clone());
    }
    let pending = {
        let mut runtime = state.0.lock().unwrap_or_else(|e| e.into_inner());
        if runtime.busy {
            return Ok(runtime.status.clone());
        }
        if action == "install" && !install_allowed(&runtime, version.as_deref()) {
            return Err("Check for updates before installing the displayed version.".into());
        }
        runtime.busy = true;
        if action == "check" {
            runtime.pending = None;
            runtime.status = UpdateStatus {
                phase: "checking",
                revision: runtime.status.revision.saturating_add(1),
                ..UpdateStatus::default()
            };
            None
        } else {
            runtime.status.phase = "downloading";
            runtime.status.downloaded = Some(0);
            runtime.status.total = None;
            runtime.status.error_code = None;
            runtime.status.message = None;
            runtime.status.revision = runtime.status.revision.saturating_add(1);
            runtime.pending.clone()
        }
    };
    let status = state
        .0
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .status
        .clone();
    let _ = app.emit_to("settings", "app:update", &status);

    if action == "check" {
        let updater = match app
            .updater_builder()
            .timeout(Duration::from_secs(15))
            .build()
        {
            Ok(updater) => updater,
            Err(_) => {
                return Ok(fail(
                    &app,
                    "check_failed",
                    "Unable to check for updates. Try again later.",
                ))
            }
        };
        match updater.check().await {
            Ok(update) => {
                let mut status = UpdateStatus {
                    phase: "current",
                    ..UpdateStatus::default()
                };
                if let Some(update) = &update {
                    if update.download_url.scheme() != "https" {
                        return Ok(fail(
                            &app,
                            "check_failed",
                            "The update download address is not secure.",
                        ));
                    }
                    status.phase = "available";
                    status.version = Some(update.version.clone());
                    status.notes = update.body.clone();
                }
                let mut runtime = state.0.lock().unwrap_or_else(|e| e.into_inner());
                runtime.pending = update;
                status.revision = runtime.status.revision.saturating_add(1);
                runtime.status = status.clone();
                runtime.busy = false;
                drop(runtime);
                let _ = app.emit_to("settings", "app:update", &status);
                Ok(status)
            }
            Err(
                tauri_plugin_updater::Error::ReleaseNotFound
                | tauri_plugin_updater::Error::TargetNotFound(_)
                | tauri_plugin_updater::Error::TargetsNotFound(_),
            ) => Ok(fail(
                &app,
                "feed_unavailable",
                "In-app updates will be available with the next signed release.",
            )),
            Err(_) => Ok(fail(
                &app,
                "check_failed",
                "Unable to check for updates. Try again later.",
            )),
        }
    } else {
        let mut update = pending.expect("install was authorized against a pending update");
        update.timeout = Some(Duration::from_secs(600));
        let mut downloaded = 0u64;
        let mut last_event = Instant::now() - Duration::from_secs(1);
        let bytes = update
            .download(
                |chunk, total| {
                    downloaded = downloaded.saturating_add(chunk as u64);
                    // Avoid re-rendering the settings webview for every network packet.
                    if last_event.elapsed() >= Duration::from_millis(100)
                        || total == Some(downloaded)
                    {
                        let mut status = state
                            .0
                            .lock()
                            .unwrap_or_else(|e| e.into_inner())
                            .status
                            .clone();
                        status.downloaded = Some(downloaded);
                        status.total = total;
                        publish(&app, status);
                        last_event = Instant::now();
                    }
                },
                || {},
            )
            .await;
        let bytes = match bytes {
            Ok(bytes) => bytes,
            Err(_) => {
                return Ok(fail(
                    &app,
                    "download_failed",
                    "The update could not be downloaded or verified. Try again later.",
                ))
            }
        };
        let mut status = state
            .0
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .status
            .clone();
        status.phase = "installing";
        status.downloaded = Some(bytes.len() as u64);
        publish(&app, status);
        // Windows launches NSIS and exits through the plugin's cleanup handler;
        // macOS replaces the bundle atomically and then restarts below.
        let installed = tauri::async_runtime::spawn_blocking(move || update.install(bytes)).await;
        if !matches!(installed, Ok(Ok(()))) {
            return Ok(fail(
                &app,
                "install_failed",
                "The update could not be installed. Download the latest version from GitHub.",
            ));
        }
        app.restart();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mock_app() -> tauri::App<tauri::test::MockRuntime> {
        let mut context = tauri::test::mock_context(tauri::test::noop_assets());
        context.config_mut().plugins.0.insert(
            "updater".into(),
            serde_json::json!({
                "pubkey": include_str!("../../tests/fixtures/updater/public.key").trim(),
                "requireSignedVersion": true,
                "dangerousInsecureTransportProtocol": true,
                "endpoints": ["https://example.invalid/update"]
            }),
        );
        tauri::test::mock_builder()
            .plugin(tauri_plugin_updater::Builder::new().build())
            .build(context)
            .unwrap()
    }

    fn manifest(url: String) -> serde_json::Value {
        serde_json::json!({"version":"99.0.0","notes":"Verification fixture","platforms":{"test-target":{
            "url":url,"signature":include_str!("../../tests/fixtures/updater/payload.txt.sig").trim()
        }}})
    }

    #[test]
    fn only_settings_can_check_or_install_updates() {
        for action in ["status", "check", "install"] {
            assert!(authorize("settings", action).is_ok());
            for label in ["result", "capture", "", "settings-copy"] {
                assert!(authorize(label, action).is_err());
            }
        }
        for action in ["", "restart", "download", "exec"] {
            assert!(authorize("settings", action).is_err());
        }
    }

    #[test]
    fn installing_requires_the_checked_version_and_no_concurrent_operation() {
        let app = mock_app();
        let updater = app.updater_builder().target("test-target").build().unwrap();
        let pending = updater.restore_update(serde_json::json!({"version":"99.0.0","platforms":{"test-target":{"url":"https://example.invalid/update","signature":"unused"}}})).unwrap();
        let mut runtime = Runtime {
            pending,
            ..Runtime::default()
        };
        assert!(!install_allowed(&Runtime::default(), Some("99.0.0")));
        assert!(!install_allowed(&runtime, None));
        assert!(!install_allowed(&runtime, Some("98.0.0")));
        assert!(install_allowed(&runtime, Some("99.0.0")));
        runtime.busy = true;
        assert!(!install_allowed(&runtime, Some("99.0.0")));
    }

    #[test]
    fn idle_status_contains_no_remote_or_sensitive_fields() {
        assert_eq!(
            serde_json::to_value(UpdateStatus::default()).unwrap(),
            serde_json::json!({"phase":"idle","revision":0,"enabled":true,"currentVersion":env!("CARGO_PKG_VERSION")})
        );
    }

    #[test]
    fn signed_payload_rejects_tampering_and_version_substitution() {
        let app = mock_app();
        let updater = app.updater_builder().target("test-target").build().unwrap();
        let metadata = manifest("https://example.invalid/package".into());
        let update = updater.restore_update(metadata.clone()).unwrap().unwrap();
        let bytes = include_bytes!("../../tests/fixtures/updater/payload.txt");
        assert!(update.verify(bytes).is_ok());
        assert!(update.verify(b"tampered").is_err());
        let mut substituted = metadata;
        substituted["version"] = serde_json::json!("100.0.0");
        let update = updater.restore_update(substituted).unwrap().unwrap();
        assert!(matches!(
            update.verify(bytes),
            Err(tauri_plugin_updater::Error::SignedVersionMismatch { .. })
        ));
        let mut changed_key = update.clone();
        changed_key.signature = "invalid signature".into();
        assert!(changed_key.verify(bytes).is_err());
    }

    #[test]
    fn local_feed_checks_and_downloads_verified_bytes_without_installing() {
        use std::{
            io::{Read, Write},
            net::TcpListener,
        };
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let manifest = serde_json::to_vec(&manifest(format!("{base}/package"))).unwrap();
        let payload = include_bytes!("../../tests/fixtures/updater/payload.txt").to_vec();
        let server = std::thread::spawn(move || {
            for bytes in [manifest, payload] {
                let (mut stream, _) = listener.accept().unwrap();
                stream
                    .set_read_timeout(Some(Duration::from_secs(5)))
                    .unwrap();
                let mut request = [0u8; 4096];
                let _ = stream.read(&mut request).unwrap();
                write!(stream, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", bytes.len()).unwrap();
                stream.write_all(&bytes).unwrap();
            }
        });
        let app = mock_app();
        let updater = app
            .updater_builder()
            .target("test-target")
            .no_proxy()
            .timeout(Duration::from_secs(5))
            .endpoints(vec![format!("{base}/latest.json").parse().unwrap()])
            .unwrap()
            .build()
            .unwrap();
        let bytes = tauri::async_runtime::block_on(async {
            let update = updater.check().await.unwrap().unwrap();
            assert_eq!(update.version, "99.0.0");
            let mut progress = 0;
            let bytes = update
                .download(|chunk, _| progress += chunk, || {})
                .await
                .unwrap();
            assert_eq!(progress, bytes.len());
            bytes
        });
        assert_eq!(
            bytes,
            include_bytes!("../../tests/fixtures/updater/payload.txt")
        );
        server.join().unwrap();
    }
}
