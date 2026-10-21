#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use serde_json::{json, Value};
use std::{
    collections::HashMap,
    ffi::{c_char, CStr, CString},
    sync::{
        atomic::{AtomicU64, Ordering},
        Mutex, OnceLock,
    },
    time::Duration,
};
use tauri::{Emitter, Manager, RunEvent, WebviewWindow};
use tokio::sync::oneshot;

static APP: OnceLock<tauri::AppHandle> = OnceLock::new();
static PENDING: OnceLock<Mutex<HashMap<String, oneshot::Sender<Result<Value, String>>>>> =
    OnceLock::new();
static NEXT_REQUEST: AtomicU64 = AtomicU64::new(1);

#[cfg(target_os = "macos")]
extern "C" {
    fn transpose_native_start(callback: extern "C" fn(*const c_char));
    fn transpose_native_command(request: *const c_char);
    fn transpose_native_stop();
    fn transpose_native_is_login_launch() -> bool;
}

fn pending() -> &'static Mutex<HashMap<String, oneshot::Sender<Result<Value, String>>>> {
    PENDING.get_or_init(|| Mutex::new(HashMap::new()))
}

fn show_settings(app: &tauri::AppHandle) {
    if let Some(window) = app.get_webview_window("settings") {
        let _ = window.unminimize();
        let _ = window.show();
        let _ = window.set_focus();
    }
}

extern "C" fn receive_native_event(raw: *const c_char) {
    if raw.is_null() {
        return;
    }
    // Swift keeps the pointer alive for this call; copy before returning.
    let input = unsafe { CStr::from_ptr(raw) }.to_string_lossy();
    let Ok(event) = serde_json::from_str::<Value>(&input) else {
        return;
    };
    let Some(kind) = event.get("type").and_then(Value::as_str) else {
        return;
    };
    if kind == "response" {
        if let Some(id) = event.get("id").and_then(Value::as_str) {
            if let Some(sender) = pending().lock().ok().and_then(|mut map| map.remove(id)) {
                let result = if event.get("ok").and_then(Value::as_bool) == Some(true) {
                    Ok(event.get("data").cloned().unwrap_or(Value::Null))
                } else {
                    Err(event
                        .get("error")
                        .and_then(Value::as_str)
                        .unwrap_or("The native request failed.")
                        .to_owned())
                };
                let _ = sender.send(result);
            }
        }
        return;
    }
    let Some(app) = APP.get() else {
        return;
    };
    match kind {
        "open_settings" => show_settings(app),
        "hide_settings" => {
            if let Some(window) = app.get_webview_window("settings") {
                let _ = window.hide();
            }
        }
        "quit" => app.exit(0),
        "restart" => app.request_restart(),
        "permission_probe" if std::env::args().any(|arg| arg == "--capture-permission-probe") => {
            if let Some(data) = event.get("data") {
                println!("{data}");
            }
            app.exit(0);
        }
        _ => {
            let _ = app.emit_to("settings", "native:event", event);
        }
    }
}

#[tauri::command]
async fn native_request(
    window: WebviewWindow,
    action: String,
    payload: Option<Value>,
) -> Result<Value, String> {
    if window.label() != "settings" {
        return Err("This window cannot access native settings.".into());
    }
    let payload = payload.unwrap_or_else(|| json!({}));
    if !payload.is_object() || action.len() > 64 {
        return Err("Invalid native request.".into());
    }
    let id = format!("tauri-{}", NEXT_REQUEST.fetch_add(1, Ordering::Relaxed));
    let request = serde_json::to_string(&json!({"id":id,"action":action,"payload":payload}))
        .map_err(|e| e.to_string())?;
    if request.len() > 1_000_000 {
        return Err("The request is too large.".into());
    }
    let request = CString::new(request).map_err(|_| "Invalid native request.")?;
    let (sender, receiver) = oneshot::channel();
    pending()
        .lock()
        .map_err(|_| "Native request state is unavailable.")?
        .insert(id.clone(), sender);
    #[cfg(target_os = "macos")]
    unsafe {
        transpose_native_command(request.as_ptr());
    }
    let answer = tokio::time::timeout(Duration::from_secs(300), receiver).await;
    if let Ok(mut map) = pending().lock() {
        map.remove(&id);
    }
    match answer {
        Ok(Ok(result)) => result,
        Ok(Err(_)) => Err("The native service disconnected.".into()),
        Err(_) => Err("The native request timed out.".into()),
    }
}

#[tauri::command]
fn diagnostics_report(
    app: tauri::AppHandle,
    window: WebviewWindow,
    frontend: bool,
    bridge: bool,
) -> Result<(), String> {
    if window.label() != "settings" || !std::env::args().any(|arg| arg == "--smoke-test") {
        return Err("Diagnostics are not enabled.".into());
    }
    println!(
        "{}",
        json!({"tauri":true,"frontend":frontend,"nativeBridge":bridge,"version":env!("CARGO_PKG_VERSION")})
    );
    app.exit(if frontend && bridge { 0 } else { 1 });
    Ok(())
}

fn main() {
    let app = tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![native_request, diagnostics_report])
        .on_page_load(|window, payload| {
            if payload.event() == tauri::webview::PageLoadEvent::Finished && std::env::args().any(|arg| arg == "--smoke-test") {
                let _ = window.eval(r#"
                    (async () => {
                        let frontend = false, bridge = false;
                        try {
                            const state = await window.__TAURI_INTERNALS__.invoke('native_request', {action:'snapshot',payload:{}});
                            bridge = !!state.app && Array.isArray(state.app.providers) && !('apiKey' in state.app.settings);
                            for (let i=0;i<100;i++) {
                                if ((document.getElementById('root')?.innerText.length ?? 0)>160) { frontend = true; break; }
                                await new Promise(resolve => setTimeout(resolve,100));
                            }
                        } catch (_) {}
                        await window.__TAURI_INTERNALS__.invoke('diagnostics_report',{frontend,bridge});
                    })();
                "#);
            }
        })
        .setup(|app| {
            let _ = APP.set(app.handle().clone());
            #[cfg(target_os = "macos")]
            {
                app.set_activation_policy(tauri::ActivationPolicy::Accessory);
                unsafe { transpose_native_start(receive_native_event); }
            }
            Ok(())
        })
        .on_window_event(|window, event| {
            if window.label() == "settings" {
                if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                    api.prevent_close();
                    let _ = window.hide();
                }
            }
        })
        .build(tauri::generate_context!())
        .expect("Could not start Transpose");
    app.run(|app, event| match event {
        RunEvent::Ready => {
            #[cfg(target_os = "macos")]
            let login = unsafe { transpose_native_is_login_launch() };
            #[cfg(not(target_os = "macos"))]
            let login = false;
            if !std::env::args().any(|arg| arg == "--capture-permission-probe")
                && (!login || std::env::args().any(|arg| arg == "--settings"))
            {
                show_settings(app);
            }
        }
        #[cfg(target_os = "macos")]
        RunEvent::Reopen { .. } => show_settings(app),
        RunEvent::Exit => {
            #[cfg(target_os = "macos")]
            unsafe {
                transpose_native_stop();
            }
        }
        _ => {}
    });
}
