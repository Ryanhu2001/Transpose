//! Windows host: keep credentials/settings in the backend and restrict the result webview.
use crate::{backend::Backend, platform::windows as platform};
use serde_json::{json, Value};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc, Mutex, OnceLock,
};
use tauri::{
    menu::{Menu, MenuItem},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    AppHandle, Emitter, Manager, PhysicalPosition, WebviewUrl, WebviewWindow, WebviewWindowBuilder,
};

static BACKEND: OnceLock<Arc<Backend>> = OnceLock::new();
static ANCHOR: Mutex<Option<(i32, i32)>> = Mutex::new(None);
static LAST_RESULT: Mutex<Option<String>> = Mutex::new(None);
static RESULT_TEST_READY: AtomicBool = AtomicBool::new(false);
static RESULT_MINIMUM: Mutex<Option<tauri::PhysicalSize<u32>>> = Mutex::new(None);

fn result_minimum_size(
    scale: f64,
    outer: tauri::PhysicalSize<u32>,
    inner: tauri::PhysicalSize<u32>,
) -> tauri::PhysicalSize<u32> {
    let scale = if scale.is_finite() && scale > 0.0 {
        scale
    } else {
        1.0
    };
    tauri::PhysicalSize::new(
        (360.0 * scale).ceil() as u32 + outer.width.saturating_sub(inner.width),
        (180.0 * scale).ceil() as u32 + outer.height.saturating_sub(inner.height),
    )
}

fn refresh_result_minimum(window: &WebviewWindow) {
    let (Ok(outer), Ok(inner), Ok(scale)) = (
        window.outer_size(),
        window.inner_size(),
        window.scale_factor(),
    ) else {
        return;
    };
    // Tao's undecorated WM_GETMINMAXINFO treats this constraint as an outer
    // size even while the Windows shadow still has a non-client frame. Measure
    // that frame so the WebView retains at least 360 × 180 logical pixels.
    let minimum = result_minimum_size(scale, outer, inner);
    let changed = RESULT_MINIMUM
        .lock()
        .map(|mut previous| {
            if *previous == Some(minimum) {
                false
            } else {
                *previous = Some(minimum);
                true
            }
        })
        .unwrap_or(true);
    if changed {
        let _ = window.set_min_size(Some(minimum));
    }
}

fn result_test_enabled() -> bool {
    std::env::args().any(|arg| arg == "--windows-result-test")
}

fn backend() -> Result<&'static Arc<Backend>, String> {
    BACKEND
        .get()
        .ok_or_else(|| "The translation service is starting.".into())
}

pub fn setup(app: &mut tauri::App) -> Result<(), Box<dyn std::error::Error>> {
    let result_test = result_test_enabled();
    let smoke = result_test || std::env::args().any(|arg| arg == "--smoke-test");
    let data_dir = if smoke {
        std::env::temp_dir().join(format!("transpose-smoke-{}", std::process::id()))
    } else {
        app.path().app_data_dir()?
    };
    let state = Arc::new(Backend::new(data_dir, smoke).map_err(std::io::Error::other)?);
    BACKEND
        .set(state.clone())
        .map_err(|_| "Backend already started")?;
    let handle = app.handle().clone();
    state.set_emitter(Arc::new(move |event| emit_event(&handle, event)));

    let result_window = WebviewWindowBuilder::new(app, "result", WebviewUrl::App("index.html#result".into()))
        .title("Transpose")
        .inner_size(460.0, 280.0)
        .min_inner_size(360.0, 180.0)
        .resizable(true)
        .decorations(false)
        .shadow(true)
        .always_on_top(true)
        .skip_taskbar(true)
        .focused(false)
        .visible(false)
        .on_page_load(move |window, payload| {
            if result_test && payload.event() == tauri::webview::PageLoadEvent::Finished {
                let _ = window.eval(r#"
                    (async () => {
                        for (let i = 0; i < 150; i++) {
                            if (document.querySelector('.translation-output')?.textContent === 'The translation window stays under your control.') {
                                await window.__TAURI_INTERNALS__.invoke('native_request', {action:'result_test_ready',payload:{}});
                                return;
                            }
                            await new Promise(resolve => setTimeout(resolve, 100));
                        }
                    })();
                "#);
            }
        })
        .on_navigation(|url| {
            matches!(
                url.host_str(),
                Some("tauri.localhost" | "127.0.0.1" | "localhost")
            )
        })
        .build()?;
    refresh_result_minimum(&result_window);
    if smoke && !result_test {
        state.set_platform_status(true, false);
        return Ok(());
    }

    let translate_state = state.clone();
    let dismiss_state = state.clone();
    let error_state = state.clone();
    let recognize_state = state.clone();
    platform::start(platform::Callbacks {
        on_translate: Arc::new(move |text, source, point| {
            if result_test {
                return;
            }
            set_anchor(point);
            let state = translate_state.clone();
            tauri::async_runtime::spawn(async move {
                if let Err(error) = state.translate_text(text, source) {
                    state.show_error(error);
                }
            });
        }),
        on_dismiss: Arc::new(move || {
            if !dismiss_state.result_pinned() {
                let state = dismiss_state.clone();
                tauri::async_runtime::spawn(async move {
                    let _ = state.request("result_close", json!({})).await;
                });
            }
        }),
        on_error: Arc::new(move |error| {
            if result_test {
                return;
            }
            let state = error_state.clone();
            tauri::async_runtime::spawn(async move {
                state.show_error(error);
            });
        }),
        on_recognizing: Arc::new(move |point| {
            if result_test {
                return;
            }
            set_anchor(point);
            recognize_state.show_recognizing();
        }),
    })
    .map_err(std::io::Error::other)?;
    if result_test {
        state.set_platform_status(true, false);
        set_anchor((120, 120));
        state.prepare_result_test().map_err(std::io::Error::other)?;
        return Ok(());
    }
    platform::set_automatic_selection(state.automatic_selection());
    state.set_platform_status(
        !platform::ocr_languages().is_empty(),
        platform::launch_at_login(),
    );
    install_tray(app)?;
    Ok(())
}

fn set_anchor(point: (i32, i32)) {
    if let Ok(mut anchor) = ANCHOR.lock() {
        *anchor = Some(point);
    }
}

fn emit_event(app: &AppHandle, event: Value) {
    if event["type"] == "result" {
        if event["data"].is_null() {
            if let Some(window) = app.get_webview_window("result") {
                let _ = window.hide();
            }
            platform::clear_outline();
            if let Ok(mut last) = LAST_RESULT.lock() {
                *last = None;
            }
        } else if let Some(window) = app.get_webview_window("result") {
            let id = event["data"]["id"].as_str().unwrap_or_default().to_owned();
            let changed = LAST_RESULT
                .lock()
                .map(|mut last| {
                    let changed = last.as_ref() != Some(&id);
                    *last = Some(id);
                    changed
                })
                .unwrap_or(false);
            if changed {
                place_result(&window);
                let _ = window.show();
            }
        }
    }
    let _ = app.emit_to("settings", "native:event", event.clone());
    let _ = app.emit_to("result", "native:event", event);
    write_result_test_report(app);
}

fn write_result_test_report(app: &AppHandle) {
    if !result_test_enabled() {
        return;
    }
    let args: Vec<_> = std::env::args_os().collect();
    let Some(path) = args
        .iter()
        .position(|arg| arg == "--diagnostics-output")
        .and_then(|index| args.get(index + 1))
        .map(std::path::PathBuf::from)
    else {
        return;
    };
    let Some(window) = app.get_webview_window("result") else {
        return;
    };
    let Ok(backend) = backend() else {
        return;
    };
    let position = window.outer_position().unwrap_or_default();
    let size = window.outer_size().unwrap_or_default();
    let report = json!({
        "ready": RESULT_TEST_READY.load(Ordering::Acquire),
        "fixtureText": "The translation window stays under your control.",
        "networkRequests": 0,
        "window": {
            "hwnd": window.hwnd().map(|handle| (handle.0 as usize).to_string()).unwrap_or_default(),
            "left": position.x, "top": position.y,
            "right": position.x + size.width as i32,
            "bottom": position.y + size.height as i32,
            "dpi": window.scale_factor().unwrap_or(1.0) * 96.0,
            "minWidth":360,"minHeight":180
        },
        "result":backend.state()["result"]
    });
    let temporary = path.with_extension("tmp");
    if std::fs::write(&temporary, report.to_string()).is_ok() {
        let _ = std::fs::rename(temporary, path);
    }
}

fn place_result(window: &WebviewWindow) {
    let point = ANCHOR.lock().ok().and_then(|mut p| p.take());
    let Some((x, y)) = point else {
        return;
    };
    let Ok(monitors) = window.available_monitors() else {
        return;
    };
    let monitor = monitors
        .iter()
        .find(|m| {
            let p = m.position();
            let s = m.size();
            x >= p.x && y >= p.y && x < p.x + s.width as i32 && y < p.y + s.height as i32
        })
        .or_else(|| monitors.first());
    let Some(monitor) = monitor else {
        return;
    };
    let size = window
        .outer_size()
        .unwrap_or(tauri::PhysicalSize::new(460, 280));
    let p = monitor.position();
    let s = monitor.size();
    let max_x = (p.x + s.width as i32 - size.width as i32 - 12).max(p.x + 12);
    let max_y = (p.y + s.height as i32 - size.height as i32 - 40).max(p.y + 12);
    let _ = window.set_position(PhysicalPosition::new(
        (x + 14).clamp(p.x + 12, max_x),
        (y + 18).clamp(p.y + 12, max_y),
    ));
}

pub async fn request(
    window: &WebviewWindow,
    action: &str,
    payload: Value,
) -> Result<Value, String> {
    if !window_allowed(window.label(), action) {
        return Err("This window cannot access native settings.".into());
    }
    let state = backend()?;
    let app = window.app_handle();
    match action {
        "result_test_ready" => {
            RESULT_TEST_READY.store(true, Ordering::Release);
            write_result_test_report(app);
        }
        "capture" => {
            if let Some(result) = app.get_webview_window("result") {
                let _ = result.hide();
            }
            if let Some(settings) = app.get_webview_window("settings") {
                let _ = settings.hide();
            }
            platform::capture()?;
        }
        "permission" => {
            if platform::ocr_languages().is_empty() {
                open_external("ms-settings:regionlanguage")?;
            }
            state.set_platform_status(
                !platform::ocr_languages().is_empty(),
                platform::launch_at_login(),
            );
        }
        "login_set" => {
            let enabled = payload["enabled"]
                .as_bool()
                .ok_or("Expected a login setting.")?;
            platform::set_launch_at_login(enabled)?;
            state.set_platform_status(
                !platform::ocr_languages().is_empty(),
                platform::launch_at_login(),
            );
        }
        "login_settings" => open_external("ms-settings:startupapps")?,
        "apple_prepare" => return Err("Apple Translation is available on macOS only.".into()),
        "open_settings" => crate::show_settings(app),
        "open_external" => {
            let url = payload["url"].as_str().ok_or("Expected a web address.")?;
            let parsed = reqwest::Url::parse(url).map_err(|_| "Invalid web address.")?;
            if parsed.scheme() != "https"
                || !matches!(
                    parsed.host_str(),
                    Some("github.com" | "openrouter.ai" | "platform.deepseek.com")
                )
            {
                return Err("This web address is not allowed.".into());
            }
            open_external(url)?;
        }
        "app_restart" => app.request_restart(),
        "app_quit" => app.exit(0),
        "result_copy" => {
            let output = state
                .result_output()
                .ok_or("There is no translation to copy.")?;
            platform::copy_text(&output)?;
        }
        _ => {
            let result = state.request(action, payload).await?;
            if action == "update_settings" {
                platform::set_automatic_selection(state.automatic_selection());
            }
            return Ok(result);
        }
    }
    Ok(state.state())
}

fn window_allowed(label: &str, action: &str) -> bool {
    label == "settings"
        || (label == "result"
            && matches!(
                action,
                "snapshot"
                    | "result_close"
                    | "result_pin"
                    | "result_retry"
                    | "result_copy"
                    | "open_settings"
            ))
        || (label == "result" && result_test_enabled() && action == "result_test_ready")
}

fn open_external(url: &str) -> Result<(), String> {
    use windows::{
        core::PCWSTR,
        Win32::UI::{Shell::ShellExecuteW, WindowsAndMessaging::SW_SHOWNORMAL},
    };
    let value: Vec<u16> = url.encode_utf16().chain(std::iter::once(0)).collect();
    let verb: Vec<u16> = "open".encode_utf16().chain(std::iter::once(0)).collect();
    let result = unsafe {
        ShellExecuteW(
            None,
            PCWSTR(verb.as_ptr()),
            PCWSTR(value.as_ptr()),
            None,
            None,
            SW_SHOWNORMAL,
        )
    };
    if result.0 as isize <= 32 {
        Err("Windows could not open this page.".into())
    } else {
        Ok(())
    }
}

fn install_tray(app: &tauri::App) -> Result<(), Box<dyn std::error::Error>> {
    let settings = MenuItem::with_id(app, "settings", "Transpose Settings…", true, None::<&str>)?;
    let capture = MenuItem::with_id(
        app,
        "capture",
        "Translate Screen Area (Alt+S)",
        true,
        None::<&str>,
    )?;
    let quit = MenuItem::with_id(app, "quit", "Quit Transpose", true, None::<&str>)?;
    let menu = Menu::with_items(app, &[&settings, &capture, &quit])?;
    let mut tray = TrayIconBuilder::new()
        .tooltip("Transpose")
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_menu_event(|app, event| match event.id.as_ref() {
            "settings" => crate::show_settings(app),
            "capture" => {
                if let Err(error) = platform::capture() {
                    if let Ok(state) = backend() {
                        state.show_error(error);
                    }
                }
            }
            "quit" => app.exit(0),
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            if matches!(
                event,
                TrayIconEvent::Click {
                    button: MouseButton::Left,
                    button_state: MouseButtonState::Up,
                    ..
                }
            ) {
                crate::show_settings(tray.app_handle());
            }
        });
    if let Some(icon) = app.default_window_icon() {
        tray = tray.icon(icon.clone());
    }
    tray.build(app)?;
    Ok(())
}

pub fn window_event(window: &tauri::Window, event: &tauri::WindowEvent) {
    if window.label() == "result" {
        if matches!(
            event,
            tauri::WindowEvent::Resized(_) | tauri::WindowEvent::ScaleFactorChanged { .. }
        ) {
            if let Some(result) = window.app_handle().get_webview_window("result") {
                refresh_result_minimum(&result);
            }
        }
        if let tauri::WindowEvent::CloseRequested { api, .. } = event {
            api.prevent_close();
            if let Ok(state) = backend() {
                let state = state.clone();
                tauri::async_runtime::spawn(async move {
                    let _ = state.request("result_close", json!({})).await;
                });
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{result_minimum_size, window_allowed};
    #[test]
    fn minimum_preserves_client_area_with_undecorated_windows_frame() {
        let size = |width, height| tauri::PhysicalSize::new(width, height);
        assert_eq!(
            result_minimum_size(1.0, size(476, 289), size(460, 280)),
            size(376, 189)
        );
        assert_eq!(
            result_minimum_size(1.5, size(714, 434), size(690, 420)),
            size(564, 284)
        );
        assert_eq!(
            result_minimum_size(2.0, size(952, 578), size(920, 560)),
            size(752, 378)
        );
        assert_eq!(
            result_minimum_size(1.0, size(460, 280), size(460, 280)),
            size(360, 180)
        );
    }
    #[test]
    fn result_cannot_modify_settings_or_execute_commands() {
        for action in [
            "key_save",
            "provider_select",
            "translate",
            "capture",
            "open_external",
            "app_restart",
            "app_quit",
            "glossary_import",
        ] {
            assert!(!window_allowed("result", action));
        }
        assert!(window_allowed("result", "result_pin"));
        assert!(window_allowed("result", "snapshot"));
        assert!(!window_allowed("untrusted", "snapshot"));
        assert!(window_allowed("settings", "key_save"));
    }
}
