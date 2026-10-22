//! Windows desktop integration. UI Automation reads selections without copying;
//! captured pixels remain in memory and Windows OCR runs on a worker thread.
use std::{
    cell::RefCell,
    ffi::c_void,
    mem::{size_of, zeroed},
    ptr::{null, null_mut},
    sync::{
        atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering},
        mpsc, Arc, OnceLock,
    },
    thread,
    time::{Duration, Instant},
};
use windows::core::Interface;
use windows::Win32::{
    Foundation::{HWND, POINT},
    System::Com::{
        CoCreateInstance, CoInitializeEx, CoUninitialize, CLSCTX_INPROC_SERVER,
        COINIT_MULTITHREADED,
    },
    UI::Accessibility::{
        CUIAutomation, CUIAutomation8, IUIAutomation, IUIAutomation2, IUIAutomationElement,
        IUIAutomationTextChildPattern, IUIAutomationTextPattern, IUIAutomationTextPattern2,
        IUIAutomationTreeWalker, UIA_TextChildPatternId, UIA_TextPattern2Id, UIA_TextPatternId,
    },
};

#[path = "windows/ocr.rs"]
mod ocr;

type Handle = isize;
type WndProc = unsafe extern "system" fn(Handle, u32, usize, isize) -> isize;

#[derive(Clone)]
pub struct Callbacks {
    pub on_translate: Arc<dyn Fn(String, String, (i32, i32)) + Send + Sync>,
    pub on_dismiss: Arc<dyn Fn() + Send + Sync>,
    pub on_error: Arc<dyn Fn(String) + Send + Sync>,
    pub on_recognizing: Arc<dyn Fn((i32, i32)) + Send + Sync>,
}

static CONTROLLER: AtomicUsize = AtomicUsize::new(0);
static AUTOMATIC: AtomicBool = AtomicBool::new(true);
static GENERATION: AtomicU64 = AtomicU64::new(0);
static CAPTURE_ACTIVE: AtomicBool = AtomicBool::new(false);
static SELECTION_LAUNCHER: AtomicUsize = AtomicUsize::new(0);
static SELECTION_READS: AtomicU64 = AtomicU64::new(0);
static SELECTION_REASON: AtomicUsize = AtomicUsize::new(0);
const START_CAPTURE: u32 = 0x8001;
const CLEAR_OUTLINE: u32 = 0x8002;
const SELECTED: u32 = 0x8003;
const INPUT: u32 = 0x8004;
const STOP: u32 = 0x8005;
const OWN_INPUT: u32 = 0x8006;
const SELECTION_TIMER: usize = 1;
const LAUNCHER_TIMER: usize = 2;
const HOTKEY_ID: i32 = 0x5452;
const BLUE: u32 = 0x00d55f1d; // COLORREF BGR: #1d5fd5.
const WHITE: u32 = 0x00ffffff;
const WS_POPUP: u32 = 0x80000000;
const EX_TOOLWINDOW: u32 = 0x80;
const EX_TOPMOST: u32 = 0x8;
const EX_NOACTIVATE: u32 = 0x08000000;
const EX_LAYERED: u32 = 0x80000;
const EX_TRANSPARENT: u32 = 0x20;
const MAX_SELECTION_ANCESTORS: usize = 64;
const MAX_SELECTION_CANDIDATES: usize = 4 * MAX_SELECTION_ANCESTORS;

thread_local! { static STATE: RefCell<Option<State>> = const { RefCell::new(None) }; }

#[derive(Clone)]
struct Selection {
    text: String,
    app: String,
    anchor: (i32, i32),
    foreground: Handle,
    generation: u64,
}
struct ReadRequest {
    anchor: (i32, i32),
    foreground: Handle,
    generation: u64,
}
struct State {
    callbacks: Callbacks,
    launcher: Handle,
    overlay: Handle,
    selection: Option<Selection>,
    pending: Option<ReadRequest>,
    read: mpsc::Sender<ReadRequest>,
    down: Option<(Point, Instant)>,
    last_click: Option<(Point, Instant)>,
    capture: Option<Capture>,
}
struct Capture {
    image: DesktopImage,
    points: Vec<Point>,
    drawing: bool,
    rectangle: bool,
    finished: bool,
}
struct DesktopImage {
    left: i32,
    top: i32,
    width: i32,
    height: i32,
    pixels: Vec<u8>,
    bitmap: Handle,
}
impl Drop for DesktopImage {
    fn drop(&mut self) {
        unsafe {
            DeleteObject(self.bitmap);
        }
    }
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct Point {
    x: i32,
    y: i32,
}
#[repr(C)]
#[derive(Clone, Copy, Default)]
struct Rect {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
}
#[repr(C)]
struct MonitorInfo {
    size: u32,
    monitor: Rect,
    work: Rect,
    flags: u32,
}
#[repr(C)]
struct GuiThreadInfo {
    size: u32,
    flags: u32,
    active: Handle,
    focus: Handle,
    capture: Handle,
    menu_owner: Handle,
    move_size: Handle,
    caret: Handle,
    caret_rect: Rect,
}
#[repr(C)]
struct WindowClass {
    size: u32,
    style: u32,
    procedure: Option<WndProc>,
    class_extra: i32,
    window_extra: i32,
    instance: Handle,
    icon: Handle,
    cursor: Handle,
    background: Handle,
    menu: *const u16,
    name: *const u16,
    small_icon: Handle,
}
#[repr(C)]
struct Message {
    hwnd: Handle,
    message: u32,
    wparam: usize,
    lparam: isize,
    time: u32,
    point: Point,
    private: u32,
}
#[repr(C)]
struct Paint {
    dc: Handle,
    erase: i32,
    rect: Rect,
    restore: i32,
    incremental: i32,
    reserved: [u8; 32],
}
#[repr(C)]
struct MouseInput {
    point: Point,
    mouse_data: u32,
    flags: u32,
    time: u32,
    extra: usize,
}
#[repr(C)]
struct KeyboardInput {
    vk: u32,
    scan: u32,
    flags: u32,
    time: u32,
    extra: usize,
}
#[repr(C)]
struct BitmapInfo {
    size: u32,
    width: i32,
    height: i32,
    planes: u16,
    bits: u16,
    compression: u32,
    image_size: u32,
    xppm: i32,
    yppm: i32,
    used: u32,
    important: u32,
    colors: [u32; 1],
}

#[link(name = "user32")]
unsafe extern "system" {
    fn RegisterClassExW(class: *const WindowClass) -> u16;
    fn CreateWindowExW(
        ex: u32,
        class: *const u16,
        title: *const u16,
        style: u32,
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        parent: Handle,
        menu: Handle,
        instance: Handle,
        param: *const c_void,
    ) -> Handle;
    fn DefWindowProcW(hwnd: Handle, message: u32, wparam: usize, lparam: isize) -> isize;
    fn GetMessageW(message: *mut Message, hwnd: Handle, min: u32, max: u32) -> i32;
    fn TranslateMessage(message: *const Message) -> i32;
    fn DispatchMessageW(message: *const Message) -> isize;
    fn PostMessageW(hwnd: Handle, message: u32, wparam: usize, lparam: isize) -> i32;
    fn SendMessageTimeoutW(
        hwnd: Handle,
        message: u32,
        wparam: usize,
        lparam: isize,
        flags: u32,
        timeout: u32,
        result: *mut usize,
    ) -> isize;
    fn PostQuitMessage(code: i32);
    fn ShowWindow(hwnd: Handle, command: i32) -> i32;
    fn DestroyWindow(hwnd: Handle) -> i32;
    fn SetWindowPos(hwnd: Handle, after: Handle, x: i32, y: i32, w: i32, h: i32, flags: u32)
        -> i32;
    fn SetWindowLongPtrW(hwnd: Handle, index: i32, value: isize) -> isize;
    fn GetWindowLongPtrW(hwnd: Handle, index: i32) -> isize;
    fn SetLayeredWindowAttributes(hwnd: Handle, color: u32, alpha: u8, flags: u32) -> i32;
    fn SetForegroundWindow(hwnd: Handle) -> i32;
    fn GetForegroundWindow() -> Handle;
    fn GetWindowThreadProcessId(hwnd: Handle, pid: *mut u32) -> u32;
    fn GetAncestor(hwnd: Handle, flags: u32) -> Handle;
    fn GetWindowTextW(hwnd: Handle, text: *mut u16, capacity: i32) -> i32;
    fn GetClassNameW(hwnd: Handle, text: *mut u16, capacity: i32) -> i32;
    fn IsWindowUnicode(hwnd: Handle) -> i32;
    fn GetGUIThreadInfo(thread: u32, info: *mut GuiThreadInfo) -> i32;
    fn GetClipboardSequenceNumber() -> u32;
    fn WindowFromPoint(point: Point) -> Handle;
    fn GetCursorPos(point: *mut Point) -> i32;
    fn GetDpiForWindow(hwnd: Handle) -> u32;
    fn MonitorFromPoint(point: Point, flags: u32) -> Handle;
    fn GetMonitorInfoW(monitor: Handle, info: *mut MonitorInfo) -> i32;
    fn SetWindowRgn(hwnd: Handle, region: Handle, redraw: i32) -> i32;
    fn GetAsyncKeyState(key: i32) -> i16;
    fn GetDoubleClickTime() -> u32;
    fn SetWindowsHookExW(
        kind: i32,
        callback: Option<unsafe extern "system" fn(i32, usize, isize) -> isize>,
        instance: Handle,
        thread: u32,
    ) -> Handle;
    fn UnhookWindowsHookEx(hook: Handle) -> i32;
    fn CallNextHookEx(hook: Handle, code: i32, wparam: usize, lparam: isize) -> isize;
    fn RegisterHotKey(hwnd: Handle, id: i32, modifiers: u32, key: u32) -> i32;
    fn UnregisterHotKey(hwnd: Handle, id: i32) -> i32;
    fn SetTimer(hwnd: Handle, id: usize, delay: u32, callback: *const c_void) -> usize;
    fn KillTimer(hwnd: Handle, id: usize) -> i32;
    fn GetSystemMetrics(index: i32) -> i32;
    fn LoadCursorW(instance: Handle, name: *const u16) -> Handle;
    fn SetCursor(cursor: Handle) -> Handle;
    fn SetCapture(hwnd: Handle) -> Handle;
    fn ReleaseCapture() -> i32;
    fn InvalidateRect(hwnd: Handle, rect: *const Rect, erase: i32) -> i32;
    fn BeginPaint(hwnd: Handle, paint: *mut Paint) -> Handle;
    fn EndPaint(hwnd: Handle, paint: *const Paint) -> i32;
    fn GetClientRect(hwnd: Handle, rect: *mut Rect) -> i32;
    fn GetWindowRect(hwnd: Handle, rect: *mut Rect) -> i32;
    fn IsWindowVisible(hwnd: Handle) -> i32;
    fn FillRect(dc: Handle, rect: *const Rect, brush: Handle) -> i32;
    fn DrawTextW(dc: Handle, text: *const u16, count: i32, rect: *mut Rect, format: u32) -> i32;
    fn GetDC(hwnd: Handle) -> Handle;
    fn ReleaseDC(hwnd: Handle, dc: Handle) -> i32;
    fn OpenClipboard(hwnd: Handle) -> i32;
    fn CloseClipboard() -> i32;
    fn EmptyClipboard() -> i32;
    fn SetClipboardData(format: u32, data: Handle) -> Handle;
}
#[link(name = "gdi32")]
unsafe extern "system" {
    fn CreateCompatibleDC(dc: Handle) -> Handle;
    fn CreateCompatibleBitmap(dc: Handle, width: i32, height: i32) -> Handle;
    fn DeleteDC(dc: Handle) -> i32;
    fn DeleteObject(object: Handle) -> i32;
    fn SelectObject(dc: Handle, object: Handle) -> Handle;
    fn GetDIBits(
        dc: Handle,
        bitmap: Handle,
        start: u32,
        rows: u32,
        pixels: *mut c_void,
        info: *mut BitmapInfo,
        usage: u32,
    ) -> i32;
    fn BitBlt(
        target: Handle,
        x: i32,
        y: i32,
        width: i32,
        height: i32,
        source: Handle,
        sx: i32,
        sy: i32,
        operation: u32,
    ) -> i32;
    fn CreateSolidBrush(color: u32) -> Handle;
    fn CreatePen(style: i32, width: i32, color: u32) -> Handle;
    fn CreateFontW(
        height: i32,
        width: i32,
        escapement: i32,
        orientation: i32,
        weight: i32,
        italic: u32,
        underline: u32,
        strike: u32,
        charset: u32,
        precision: u32,
        clip: u32,
        quality: u32,
        pitch: u32,
        family: *const u16,
    ) -> Handle;
    fn GetStockObject(index: i32) -> Handle;
    fn SetTextColor(dc: Handle, color: u32) -> u32;
    fn SetBkMode(dc: Handle, mode: i32) -> i32;
    fn RoundRect(dc: Handle, left: i32, top: i32, right: i32, bottom: i32, ew: i32, eh: i32)
        -> i32;
    fn Polyline(dc: Handle, points: *const Point, count: i32) -> i32;
    fn Ellipse(dc: Handle, left: i32, top: i32, right: i32, bottom: i32) -> i32;
    fn CreateRoundRectRgn(left: i32, top: i32, right: i32, bottom: i32, ew: i32, eh: i32)
        -> Handle;
}
#[link(name = "kernel32")]
unsafe extern "system" {
    fn GetModuleHandleW(name: *const u16) -> Handle;
    fn GetCurrentProcessId() -> u32;
    fn GlobalAlloc(flags: u32, bytes: usize) -> Handle;
    fn GlobalLock(memory: Handle) -> *mut c_void;
    fn GlobalUnlock(memory: Handle) -> i32;
    fn GlobalFree(memory: Handle) -> Handle;
}
#[link(name = "dwmapi")]
unsafe extern "system" {
    fn DwmFlush() -> i32;
}
#[link(name = "runtimeobject")]
unsafe extern "system" {
    fn RoInitialize(initialization: u32) -> i32;
    fn RoUninitialize();
}
#[link(name = "advapi32")]
unsafe extern "system" {
    fn RegCreateKeyExW(
        key: Handle,
        subkey: *const u16,
        reserved: u32,
        class: *const u16,
        options: u32,
        access: u32,
        security: *const c_void,
        result: *mut Handle,
        disposition: *mut u32,
    ) -> i32;
    fn RegOpenKeyExW(
        key: Handle,
        subkey: *const u16,
        options: u32,
        access: u32,
        result: *mut Handle,
    ) -> i32;
    fn RegSetValueExW(
        key: Handle,
        name: *const u16,
        reserved: u32,
        kind: u32,
        bytes: *const u8,
        len: u32,
    ) -> i32;
    fn RegQueryValueExW(
        key: Handle,
        name: *const u16,
        reserved: *mut u32,
        kind: *mut u32,
        bytes: *mut u8,
        len: *mut u32,
    ) -> i32;
    fn RegDeleteValueW(key: Handle, name: *const u16) -> i32;
    fn RegCloseKey(key: Handle) -> i32;
}

fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(Some(0)).collect()
}

pub fn start(callbacks: Callbacks) -> Result<(), String> {
    if CONTROLLER.load(Ordering::Acquire) != 0 {
        return Ok(());
    }
    let (ready_tx, ready_rx) = mpsc::sync_channel(1);
    thread::Builder::new().name("transpose-desktop".into()).spawn(move || unsafe {
        let instance = GetModuleHandleW(null());
        let controller_class = wide("TransposeController");
        let launcher_class = wide("TransposeSelection");
        let capture_class = wide("TransposeCapture");
        for (name, proc) in [(&controller_class, controller_proc as WndProc), (&launcher_class, launcher_proc as WndProc), (&capture_class, capture_proc as WndProc)] {
            let class = WindowClass { size: size_of::<WindowClass>() as u32, style: 0x8, procedure: Some(proc), class_extra: 0, window_extra: 0, instance, icon: 0, cursor: LoadCursorW(0, 32512usize as *const u16), background: 0, menu: null(), name: name.as_ptr(), small_icon: 0 };
            if RegisterClassExW(&class) == 0 { let _ = ready_tx.send(Err("Windows could not create the desktop controls.".into())); return; }
        }
        let title = wide("Transpose");
        let controller = CreateWindowExW(EX_TOOLWINDOW, controller_class.as_ptr(), title.as_ptr(), WS_POPUP, 0, 0, 0, 0, 0, 0, instance, null());
        let launcher = CreateWindowExW(EX_TOOLWINDOW | EX_TOPMOST | EX_NOACTIVATE, launcher_class.as_ptr(), title.as_ptr(), WS_POPUP, 0, 0, 30, 30, 0, 0, instance, null());
        let overlay = CreateWindowExW(EX_TOOLWINDOW | EX_TOPMOST, capture_class.as_ptr(), title.as_ptr(), WS_POPUP, 0, 0, 0, 0, 0, 0, instance, null());
        if controller == 0 || launcher == 0 || overlay == 0 { let _ = ready_tx.send(Err("Windows could not create the translation windows.".into())); return; }
        CONTROLLER.store(controller as usize, Ordering::Release);
        SELECTION_LAUNCHER.store(launcher as usize, Ordering::Release);
        let (read_tx, read_rx) = mpsc::channel::<ReadRequest>();
        thread::Builder::new().name("transpose-selection".into()).spawn(move || selection_worker(read_rx)).ok();
        STATE.with(|state| *state.borrow_mut() = Some(State { callbacks: callbacks.clone(), launcher, overlay, selection: None, pending: None, read: read_tx, down: None, last_click: None, capture: None }));
        let mouse = SetWindowsHookExW(14, Some(mouse_hook), instance, 0);
        let keyboard = SetWindowsHookExW(13, Some(keyboard_hook), instance, 0);
        let hotkey = RegisterHotKey(controller, HOTKEY_ID, 0x4001, b'S' as u32);
        if hotkey == 0 { (callbacks.on_error)("Alt+S is already in use. Start screen translation from Settings.".into()); }
        if mouse == 0 || keyboard == 0 { (callbacks.on_error)("Windows could not monitor text selection. Screen translation remains available.".into()); }
        let _ = ready_tx.send(Ok(()));
        let mut message: Message = zeroed();
        while GetMessageW(&mut message, 0, 0, 0) > 0 { TranslateMessage(&message); DispatchMessageW(&message); }
        UnregisterHotKey(controller, HOTKEY_ID);
        if mouse != 0 { UnhookWindowsHookEx(mouse); }
        if keyboard != 0 { UnhookWindowsHookEx(keyboard); }
        CONTROLLER.store(0, Ordering::Release);
        STATE.with(|state| *state.borrow_mut() = None);
        DestroyWindow(launcher); DestroyWindow(overlay); DestroyWindow(controller);
    }).map_err(|e| e.to_string())?;
    ready_rx
        .recv_timeout(Duration::from_secs(5))
        .map_err(|_| "Windows desktop integration did not start.".to_string())?
}

fn post(message: u32, wparam: usize, lparam: isize) -> Result<(), String> {
    let hwnd = CONTROLLER.load(Ordering::Acquire) as Handle;
    if hwnd == 0 || unsafe { PostMessageW(hwnd, message, wparam, lparam) } == 0 {
        Err("Windows desktop integration is unavailable.".into())
    } else {
        Ok(())
    }
}
pub fn capture() -> Result<(), String> {
    post(START_CAPTURE, 0, 0)
}
pub fn clear_outline() {
    GENERATION.fetch_add(1, Ordering::AcqRel);
    let _ = post(CLEAR_OUTLINE, 0, 0);
}
pub fn set_automatic_selection(enabled: bool) {
    AUTOMATIC.store(enabled, Ordering::Release);
    if !enabled {
        let _ = post(CLEAR_OUTLINE, 1, 0);
    }
}
pub fn stop() {
    let _ = post(STOP, 0, 0);
}

fn selection_test_enabled() -> bool {
    static ENABLED: OnceLock<bool> = OnceLock::new();
    *ENABLED.get_or_init(|| std::env::args_os().any(|arg| arg == "--windows-browser-test"))
}

fn selection_test_reason(reason: usize) {
    if selection_test_enabled() {
        SELECTION_REASON.store(reason, Ordering::Release);
    }
}

/// Explicit fixture diagnostics contain only window geometry and state codes.
/// Normal launches never expose selected text, application titles or history.
pub fn selection_test_snapshot() -> serde_json::Value {
    if !selection_test_enabled() {
        return serde_json::Value::Null;
    }
    let hwnd = SELECTION_LAUNCHER.load(Ordering::Acquire) as Handle;
    let mut rect = Rect::default();
    let visible = unsafe { hwnd != 0 && IsWindowVisible(hwnd) != 0 };
    unsafe { GetWindowRect(hwnd, &mut rect) };
    let reason = match SELECTION_REASON.load(Ordering::Acquire) {
        1 => "reading",
        2 => "empty",
        3 => "selected",
        4 => "button",
        5 => "stale",
        _ => "idle",
    };
    serde_json::json!({
        "launcher": {"hwnd":hwnd.to_string(),"visible":visible,
            "left":rect.left,"top":rect.top,"right":rect.right,"bottom":rect.bottom},
        "reason":reason,"requests":SELECTION_READS.load(Ordering::Acquire),
        "generation":GENERATION.load(Ordering::Acquire)
    })
}
pub fn ocr_languages() -> Vec<String> {
    thread::spawn(|| unsafe {
        if RoInitialize(1) < 0 {
            return Vec::new();
        }
        let result = ocr::available_languages().unwrap_or_default();
        RoUninitialize();
        result
    })
    .join()
    .unwrap_or_default()
}

/// Exercises real Windows APIs without an API key or network request. CI calls
/// this on a worker thread; no screenshot or recognized content is persisted.
pub fn run_self_test() -> Result<serde_json::Value, String> {
    unsafe {
        let initialization = RoInitialize(1);
        if initialization < 0 {
            return Err(format!(
                "Windows Runtime initialization failed: 0x{:08x}",
                initialization as u32
            ));
        }
        let result = (|| {
            let image = desktop_image()?;
            let capture = serde_json::json!({"width":image.width,"height":image.height,"bytes":image.pixels.len()});
            drop(image);
            let languages = ocr::available_languages()?;
            let (width, height, pixels) = diagnostic_bitmap()?;
            let full = ocr::recognize(width, height, pixels.clone(), Vec::new())?;
            if !full.to_ascii_lowercase().contains("transpose") {
                return Err(format!(
                    "Windows OCR did not recognize the synthetic fixture: {full}"
                ));
            }
            // A concave polygon includes the bottom and right blank margins,
            // but excludes the large text in the upper left.
            let excluded = vec![
                (0.0, 130.0),
                (520.0, 130.0),
                (520.0, 0.0),
                (640.0, 0.0),
                (640.0, 180.0),
                (0.0, 180.0),
            ];
            let clipped = ocr::recognize(width, height, pixels, excluded);
            if clipped
                .as_ref()
                .is_ok_and(|text| text.to_ascii_lowercase().contains("transpose"))
            {
                return Err("Windows OCR included text outside the freeform selection.".into());
            }
            let selection = diagnostic_selection()?;
            let legacy_selection = diagnostic_legacy_selection()?;
            if selection != "Transpose" {
                return Err(format!(
                    "UI Automation selection fixture returned {selection:?}."
                ));
            }
            Ok(
                serde_json::json!({"screenCapture":capture,"ocrLanguages":languages,"ocr":true,"freeformFilter":true,"selection":true,"legacySelection":legacy_selection,"networkRequests":0}),
            )
        })();
        RoUninitialize();
        result
    }
}

unsafe fn diagnostic_bitmap() -> Result<(u32, u32, Vec<u8>), String> {
    let (width, height) = (640, 180);
    let screen = GetDC(0);
    let dc = CreateCompatibleDC(screen);
    let bitmap = CreateCompatibleBitmap(screen, width, height);
    if dc == 0 || bitmap == 0 {
        if bitmap != 0 {
            DeleteObject(bitmap);
        }
        if dc != 0 {
            DeleteDC(dc);
        }
        ReleaseDC(0, screen);
        return Err("Could not create the Windows OCR fixture.".into());
    }
    let previous = SelectObject(dc, bitmap);
    let bounds = Rect {
        left: 0,
        top: 0,
        right: width,
        bottom: height,
    };
    let brush = CreateSolidBrush(WHITE);
    FillRect(dc, &bounds, brush);
    DeleteObject(brush);
    let font = CreateFontW(
        -42,
        0,
        0,
        0,
        500,
        0,
        0,
        0,
        1,
        0,
        0,
        5,
        0,
        wide("Segoe UI").as_ptr(),
    );
    let previous_font = SelectObject(dc, font);
    SetBkMode(dc, 1);
    SetTextColor(dc, 0);
    let text = wide("Transpose OCR 2026");
    let mut text_bounds = Rect {
        left: 24,
        top: 26,
        right: 620,
        bottom: 110,
    };
    DrawTextW(
        dc,
        text.as_ptr(),
        text.len() as i32 - 1,
        &mut text_bounds,
        0x20,
    );
    SelectObject(dc, previous_font);
    DeleteObject(font);
    SelectObject(dc, previous);
    let mut pixels = vec![0; (width * height * 4) as usize];
    let mut info = BitmapInfo {
        size: 40,
        width,
        height: -height,
        planes: 1,
        bits: 32,
        compression: 0,
        image_size: 0,
        xppm: 0,
        yppm: 0,
        used: 0,
        important: 0,
        colors: [0],
    };
    let copied = GetDIBits(
        dc,
        bitmap,
        0,
        height as u32,
        pixels.as_mut_ptr().cast(),
        &mut info,
        0,
    );
    DeleteObject(bitmap);
    DeleteDC(dc);
    ReleaseDC(0, screen);
    if copied != height {
        return Err("Could not read the Windows OCR fixture.".into());
    }
    Ok((width as u32, height as u32, pixels))
}

unsafe fn diagnostic_selection() -> Result<String, String> {
    use std::{
        io::{BufRead, BufReader, Read},
        os::windows::process::CommandExt,
        process::{Command, Stdio},
    };
    // Windows Server stock EDIT controls can expose only the legacy proxy. WPF
    // supplies its own TextBoxAutomationPeer and exercises the same native UIA
    // TextPattern client path as Chromium, modern editors and other providers.
    // This fixed, local fixture is used only by the explicit diagnostic flag.
    let script = r#"
$ErrorActionPreference = 'Stop'
trap { [Console]::Error.WriteLine($_.Exception.Message); exit 2 }
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
[Console]::Error.WriteLine('wpf:start')
Add-Type -AssemblyName PresentationFramework
[Console]::Error.WriteLine('wpf:framework-loaded')
$window = [System.Windows.Window]::new()
$window.Title = 'Transpose selection fixture'
$window.Width = 440
$window.Height = 180
$window.Left = 30
$window.Top = 30
$window.Topmost = $true
$text = [System.Windows.Controls.TextBox]::new()
$text.Text = "Transpose selection fixture`r`nNative UI Automation selection"
$text.AcceptsReturn = $true
$text.FontSize = 20
$text.Margin = [System.Windows.Thickness]::new(12)
# Each GroupBox is a real UIA control ancestor. A text selection can be much
# deeper than ten parents in a browser page or a richly structured document.
$content = $text
for ($index = 0; $index -lt 18; $index++) {
    $group = [System.Windows.Controls.GroupBox]::new()
    $group.BorderThickness = [System.Windows.Thickness]::new(0)
    $group.Padding = [System.Windows.Thickness]::new(0)
    $group.Content = $content
    $content = $group
}
$window.Content = $content
$window.Add_Loaded({
    [Console]::Error.WriteLine('wpf:loaded')
    $window.Activate() | Out-Null
    $text.Focus() | Out-Null
    $text.Select(0,9)
    $peer = [System.Windows.Automation.Peers.UIElementAutomationPeer]::CreatePeerForElement($text)
    [Console]::Out.WriteLine(([System.Windows.Interop.WindowInteropHelper]::new($window)).Handle.ToInt64())
    [Console]::Out.Flush()
    [Console]::Error.WriteLine('wpf:ready')
    $timer.Start()
})
$timer = [System.Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [TimeSpan]::FromSeconds(20)
$timer.Add_Tick({ $timer.Stop(); $window.Close() })
[Console]::Error.WriteLine('wpf:showing')
$window.ShowDialog() | Out-Null
[Console]::Error.WriteLine('wpf:closed')
"#;
    let powershell = std::env::var_os("SystemRoot")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| "C:\\Windows".into())
        .join("System32\\WindowsPowerShell\\v1.0\\powershell.exe");
    let mut fixture = Command::new(powershell)
        .args([
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-STA",
            "-Command",
            script,
        ])
        .creation_flags(0x08000000)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| format!("Cannot start the local WPF selection fixture: {error}"))?;
    let Some(stdout) = fixture.stdout.take() else {
        let _ = fixture.kill();
        let _ = fixture.wait();
        return Err("The selection fixture has no output stream.".into());
    };
    let (ready_tx, ready_rx) = mpsc::sync_channel(1);
    let reader = thread::spawn(move || {
        let mut line = String::new();
        let result = BufReader::new(stdout)
            .read_line(&mut line)
            .map(|_| line.trim().parse::<Handle>().unwrap_or(0));
        let _ = ready_tx.send(result);
    });
    let (hwnd, startup) = match ready_rx.recv_timeout(Duration::from_secs(25)) {
        Ok(Ok(hwnd)) if hwnd != 0 => (hwnd, "ready".to_owned()),
        Ok(Ok(_)) => (
            0,
            "stdout ended or returned an invalid window handle".to_owned(),
        ),
        Ok(Err(error)) => (0, format!("stdout read failed: {error}")),
        Err(error) => (0, format!("25-second startup deadline: {error}")),
    };
    let result = if hwnd == 0 {
        let process = fixture
            .try_wait()
            .map(|status| format!("{status:?}"))
            .unwrap_or_else(|error| format!("status error: {error}"));
        let _ = fixture.kill();
        let _ = fixture.wait();
        let mut error = String::new();
        if let Some(mut stderr) = fixture.stderr.take() {
            let _ = stderr.read_to_string(&mut error);
        }
        Err(format!(
            "The WPF selection fixture did not expose a window (startup={startup}; process-before-cleanup={process}; stderr={}): {}",
            if error.trim().is_empty() {"empty"} else {"available"},error.trim()
        ))
    } else {
        (|| -> Result<String, String> {
            let automation: IUIAutomation =
                CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER)
                    .map_err(|error| format!("create UI Automation: {error}"))?;
            let root = automation
                .ElementFromHandle(HWND(hwnd as *mut c_void))
                .map_err(|error| format!("find WPF fixture: {error}"))?;
            let walker = automation
                .ControlViewWalker()
                .map_err(|error| format!("create WPF tree walker: {error}"))?;
            let mut queue = vec![root.clone()];
            let mut checked = 0;
            let mut found = None;
            while let Some(element) = queue.pop() {
                checked += 1;
                if checked > 64 {
                    break;
                }
                if let Ok(pattern) =
                    element.GetCurrentPatternAs::<IUIAutomationTextPattern>(UIA_TextPatternId)
                {
                    let ranges = pattern
                        .GetSelection()
                        .map_err(|error| format!("read WPF selected ranges: {error}"))?;
                    if ranges.Length().map_err(|error| error.to_string())? > 0 {
                        let text = ranges
                            .GetElement(0)
                            .and_then(|range| range.GetText(100))
                            .map_err(|error| format!("read WPF selected text: {error}"))?
                            .to_string();
                        if !text.is_empty() {
                            found = Some((element, text));
                            break;
                        }
                    }
                }
                let mut child = walker.GetFirstChildElement(&element).ok();
                while let Some(element) = child {
                    child = walker.GetNextSiblingElement(&element).ok();
                    queue.push(element);
                }
            }
            let (element, text) = found.ok_or_else(|| {
                format!("WPF fixture exposed no selected TextPattern in {checked} UIA elements.")
            })?;
            let mut depth = 0;
            let mut ancestor = Some(element.clone());
            while let Some(current) = ancestor {
                if automation
                    .CompareElements(&current, &root)
                    .is_ok_and(|same| same.as_bool())
                {
                    break;
                }
                depth += 1;
                if depth > 48 {
                    return Err("The nested selection fixture exceeded its ancestor bound.".into());
                }
                ancestor = walker.GetParentElement(&current).ok();
            }
            if depth <= 10 {
                return Err("The nested selection fixture did not expose its deep UIA ancestry.".into());
            }
            element
                .SetFocus()
                .map_err(|error| format!("focus WPF text fixture: {error}"))?;
            // Also run the production selection reader against this other
            // process. The fixture owns focus and contains no password fields.
            let request = ReadRequest {
                anchor: (80, 80),
                foreground: hwnd,
                generation: 0,
            };
            let production = read_selection(&automation,&request).ok_or_else(||format!("The production reader could not read the WPF selection (foreground={:#x}, fixture={:#x}).",GetForegroundWindow(),hwnd))?;
            if production.0 != text {
                return Err("The production reader and direct TextPattern returned different selected text.".into());
            }
            Ok(text)
        })()
    };
    if hwnd != 0 {
        PostMessageW(hwnd, 0x10, 0, 0);
    }
    // Ensure a failed diagnostic leaves no PowerShell window or child process.
    let _ = fixture.kill();
    let _ = fixture.wait();
    let _ = reader.join();
    result.map_err(|error| format!("Windows UI Automation selection fixture failed: {error}"))
}

unsafe fn diagnostic_legacy_selection() -> Result<serde_json::Value, String> {
    use std::{
        io::{BufRead, BufReader, Read},
        os::windows::process::CommandExt,
        process::{Command, Stdio},
    };
    let script = r#"
$ErrorActionPreference = 'Stop'
trap { [Console]::Error.WriteLine($_.Exception.Message); exit 2 }
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
[Console]::Error.WriteLine('legacy:start')
Add-Type -AssemblyName System.Windows.Forms
[Console]::Error.WriteLine('legacy:framework-loaded')
$form = [System.Windows.Forms.Form]::new()
$form.Text = 'Transpose legacy selection fixture'
$form.Width = 460
$form.Height = 340
$form.Left = 40
$form.Top = 40
$form.TopMost = $true
$edit = [System.Windows.Forms.TextBox]::new()
$edit.Multiline = $true
$edit.HideSelection = $false
$edit.SetBounds(12,12,410,70)
$edit.Text = "First line`r`n$([char]::ConvertFromUtf32(0x1F3B9)) Transpose"
$rich = [System.Windows.Forms.RichTextBox]::new()
$rich.HideSelection = $false
$rich.SetBounds(12,95,410,80)
$rich.Text = "First line`n$([char]::ConvertFromUtf32(0x1F3B9)) Transpose"
$password = [System.Windows.Forms.TextBox]::new()
$password.SetBounds(12,190,410,30)
$password.UseSystemPasswordChar = $true
$password.Text = 'Transpose private fixture'
$form.Controls.AddRange(@($edit,$rich,$password))
$form.Add_Shown({
    [Console]::Error.WriteLine('legacy:shown')
    $edit.Select($edit.Text.IndexOf('Transpose'),9)
    $rich.Select($rich.Text.IndexOf('Transpose'),9)
    $password.Select(0,9)
    $edit.Focus() | Out-Null
    [Console]::Out.WriteLine(('{0},{1},{2},{3}' -f $form.Handle.ToInt64(),$edit.Handle.ToInt64(),$rich.Handle.ToInt64(),$password.Handle.ToInt64()))
    [Console]::Out.Flush()
    [Console]::Error.WriteLine('legacy:ready')
    $timer.Start()
})
$timer = [System.Windows.Forms.Timer]::new()
$timer.Interval = 20000
$timer.Add_Tick({ $timer.Stop(); $form.Close() })
[Console]::Error.WriteLine('legacy:showing')
$form.ShowDialog() | Out-Null
[Console]::Error.WriteLine('legacy:closed')
"#;
    let powershell = std::env::var_os("SystemRoot")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| "C:\\Windows".into())
        .join("System32\\WindowsPowerShell\\v1.0\\powershell.exe");
    let mut fixture = Command::new(powershell)
        .args([
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-STA",
            "-Command",
            script,
        ])
        .creation_flags(0x08000000)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| format!("Cannot start the legacy selection fixture: {error}"))?;
    let Some(stdout) = fixture.stdout.take() else {
        let _ = fixture.kill();
        let _ = fixture.wait();
        return Err("The legacy fixture has no output stream.".into());
    };
    let (ready_tx, ready_rx) = mpsc::sync_channel(1);
    let reader = thread::spawn(move || {
        let mut line = String::new();
        let result = BufReader::new(stdout).read_line(&mut line).map(|_| {
            line.trim()
                .split(',')
                .filter_map(|part| part.parse::<Handle>().ok())
                .collect::<Vec<_>>()
        });
        let _ = ready_tx.send(result);
    });
    let (handles, startup) = match ready_rx.recv_timeout(Duration::from_secs(25)) {
        Ok(Ok(handles)) if handles.len() == 4 && handles.iter().all(|handle| *handle != 0) => {
            (handles, "ready".to_owned())
        }
        Ok(Ok(handles)) => (
            handles,
            "stdout ended or returned invalid control handles".to_owned(),
        ),
        Ok(Err(error)) => (Vec::new(), format!("stdout read failed: {error}")),
        Err(error) => (Vec::new(), format!("25-second startup deadline: {error}")),
    };
    let result = if handles.len() != 4 || handles.iter().any(|handle| *handle == 0) {
        let process = fixture
            .try_wait()
            .map(|status| format!("{status:?}"))
            .unwrap_or_else(|error| format!("status error: {error}"));
        let _ = fixture.kill();
        let _ = fixture.wait();
        let mut error = String::new();
        if let Some(mut stderr) = fixture.stderr.take() {
            let _ = stderr.read_to_string(&mut error);
        }
        Err(format!(
            "The legacy selection fixture did not expose its controls (startup={startup}; process-before-cleanup={process}; stderr={}): {}",
            if error.trim().is_empty() {"empty"} else {"available"},error.trim()
        ))
    } else {
        (|| -> Result<serde_json::Value, String> {
            let parent = handles[0];
            let automation: IUIAutomation =
                CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER)
                    .map_err(|error| error.to_string())?;
            let clipboard = GetClipboardSequenceNumber();
            for (index, name) in [(1, "EDIT"), (2, "RichEdit")] {
                let element = automation
                    .ElementFromHandle(HWND(handles[index] as *mut c_void))
                    .map_err(|error| format!("find legacy {name}: {error}"))?;
                SetForegroundWindow(parent);
                element
                    .SetFocus()
                    .map_err(|error| format!("focus legacy {name}: {error}"))?;
                let direct = read_legacy_edit_selection(
                    handles[index],
                    parent,
                    Instant::now() + Duration::from_millis(650),
                )
                .ok_or_else(|| format!("The native {name} selection reader returned no text."))?;
                if direct != "Transpose" {
                    return Err(format!(
                        "The native {name} selection had wrong CRLF/UTF-16 offsets: {direct:?}"
                    ));
                }
                let request = ReadRequest {
                    anchor: (80, 80),
                    foreground: parent,
                    generation: 0,
                };
                let production = read_selection(&automation, &request).ok_or_else(|| {
                    format!("The production reader missed the legacy {name} selection.")
                })?;
                if production.0 != "Transpose" {
                    return Err(format!(
                        "The production {name} reader returned the wrong selected text."
                    ));
                }
            }
            let password = automation
                .ElementFromHandle(HWND(handles[3] as *mut c_void))
                .map_err(|error| error.to_string())?;
            password
                .SetFocus()
                .map_err(|error| format!("focus password fixture: {error}"))?;
            let request = ReadRequest {
                anchor: (80, 250),
                foreground: parent,
                generation: 0,
            };
            if read_legacy_edit_selection(
                handles[3],
                parent,
                Instant::now() + Duration::from_millis(650),
            )
            .is_some()
                || read_selection(&automation, &request).is_some()
            {
                return Err("A password field exposed selected text to the reader.".into());
            }
            if GetClipboardSequenceNumber() != clipboard {
                return Err("Reading the native selections changed the clipboard.".into());
            }
            Ok(
                serde_json::json!({"edit":true,"richEdit":true,"utf16AndParagraphOffsets":true,"passwordProtected":true,"clipboardUnchanged":true}),
            )
        })()
    };
    if let Some(parent) = handles.first() {
        PostMessageW(*parent, 0x10, 0, 0);
    }
    let _ = fixture.kill();
    let _ = fixture.wait();
    let _ = reader.join();
    result.map_err(|error| format!("Windows legacy selection fixture failed: {error}"))
}

unsafe extern "system" fn mouse_hook(code: i32, wparam: usize, lparam: isize) -> isize {
    if code >= 0 && (wparam == 0x201 || wparam == 0x202) && !CAPTURE_ACTIVE.load(Ordering::Relaxed)
    {
        let event = &*(lparam as *const MouseInput);
        // WebView2 can put a renderer-process child HWND under our result.
        // Classify its top-level window now, before queued input can outlive a
        // native move or a hide, rather than checking WindowFromPoint later.
        if foreign_window(WindowFromPoint(event.point)) {
            let _ = post(INPUT, wparam, pack_point(event.point));
        } else if wparam == 0x201 {
            let _ = post(OWN_INPUT, wparam, 0);
        }
    }
    CallNextHookEx(0, code, wparam, lparam)
}
unsafe extern "system" fn keyboard_hook(code: i32, wparam: usize, lparam: isize) -> isize {
    if code >= 0
        && wparam == 0x101
        && AUTOMATIC.load(Ordering::Relaxed)
        && !CAPTURE_ACTIVE.load(Ordering::Relaxed)
    {
        let event = &*(lparam as *const KeyboardInput);
        let selection_key = GetAsyncKeyState(0x10) < 0
            && [0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28].contains(&event.vk)
            || event.vk == b'A' as u32 && GetAsyncKeyState(0x11) < 0;
        if selection_key && foreign_window(GetForegroundWindow()) {
            let mut point = Point::default();
            GetCursorPos(&mut point);
            let _ = post(INPUT, 0x101, pack_point(point));
        }
    }
    CallNextHookEx(0, code, wparam, lparam)
}
fn pack_point(point: Point) -> isize {
    ((point.x as u16 as u32) | ((point.y as u16 as u32) << 16)) as isize
}
fn unpack_point(value: isize) -> Point {
    Point {
        x: (value as u16) as i16 as i32,
        y: ((value as u32 >> 16) as u16) as i16 as i32,
    }
}
unsafe fn foreign_window(hwnd: Handle) -> bool {
    if hwnd == 0 {
        return false;
    }
    let own_pid = GetCurrentProcessId();
    let mut hit_pid = 0;
    GetWindowThreadProcessId(hwnd, &mut hit_pid);
    for window in [hwnd, GetAncestor(hwnd, 2), GetAncestor(hwnd, 3)] {
        let mut pid = 0;
        GetWindowThreadProcessId(window, &mut pid);
        if pid == own_pid {
            return false;
        }
    }
    hit_pid != 0
}

unsafe extern "system" fn controller_proc(
    hwnd: Handle,
    message: u32,
    wparam: usize,
    lparam: isize,
) -> isize {
    match message {
        START_CAPTURE | 0x312 => {
            begin_capture();
            return 0;
        }
        CLEAR_OUTLINE => {
            if wparam == 0 {
                CAPTURE_ACTIVE.store(false, Ordering::Release);
            }
            let handles = STATE.with(|cell| {
                cell.borrow_mut().as_mut().map(|state| {
                    state.selection = None;
                    if wparam == 0 {
                        state.capture = None;
                    }
                    (state.launcher, state.overlay)
                })
            });
            if let Some((launcher, overlay)) = handles {
                ShowWindow(launcher, 0);
                if wparam == 0 {
                    ShowWindow(overlay, 0);
                }
            }
            return 0;
        }
        STOP => {
            PostQuitMessage(0);
            return 0;
        }
        SELECTED => {
            let selection = *Box::from_raw(lparam as *mut Selection);
            if AUTOMATIC.load(Ordering::Acquire)
                && selection.generation == GENERATION.load(Ordering::Acquire)
                && GetForegroundWindow() == selection.foreground
                && !CAPTURE_ACTIVE.load(Ordering::Acquire)
            {
                STATE.with(|cell| {
                    if let Some(state) = cell.borrow_mut().as_mut() {
                        let size = (30 * GetDpiForWindow(selection.foreground).max(96) / 96) as i32;
                        let (mut x, mut y) = (selection.anchor.0 + 12, selection.anchor.1 + 12);
                        let monitor = MonitorFromPoint(Point { x, y }, 2);
                        let mut info = MonitorInfo {
                            size: size_of::<MonitorInfo>() as u32,
                            monitor: Rect::default(),
                            work: Rect::default(),
                            flags: 0,
                        };
                        if GetMonitorInfoW(monitor, &mut info) != 0 {
                            x = x.clamp(info.work.left, info.work.right - size);
                            y = y.clamp(info.work.top, info.work.bottom - size);
                        }
                        state.selection = Some(selection);
                        let region =
                            CreateRoundRectRgn(0, 0, size + 1, size + 1, size / 3, size / 3);
                        if region != 0 && SetWindowRgn(state.launcher, region, 0) == 0 {
                            DeleteObject(region);
                        }
                        SetWindowPos(state.launcher, -1, x, y, size, size, 0x10 | 0x40);
                        selection_test_reason(4);
                        SetTimer(hwnd, LAUNCHER_TIMER, 6000, null());
                        InvalidateRect(state.launcher, null(), 0);
                    }
                });
            }
            return 0;
        }
        INPUT => {
            let point = unpack_point(lparam);
            let mut dismiss = None;
            STATE.with(|cell| {
                if let Some(state) = cell.borrow_mut().as_mut() {
                    if wparam == 0x201 {
                        // A foreign click dismisses only unpinned results via the host.
                        GENERATION.fetch_add(1, Ordering::AcqRel);
                        KillTimer(hwnd, SELECTION_TIMER);
                        ShowWindow(state.launcher, 0);
                        state.selection = None;
                        state.pending = None;
                        state.down = Some((point, Instant::now()));
                        dismiss = Some(state.callbacks.on_dismiss.clone());
                    } else if AUTOMATIC.load(Ordering::Acquire) {
                        let now = Instant::now();
                        let dragged = state.down.take().is_some_and(|(down, _)| {
                            (down.x - point.x).abs() + (down.y - point.y).abs() >= 3
                        });
                        let double = state.last_click.is_some_and(|(previous, time)| {
                            now.duration_since(time).as_millis() < GetDoubleClickTime() as u128
                                && (previous.x - point.x).abs() + (previous.y - point.y).abs() < 8
                        });
                        if dragged || double || wparam == 0x101 || GetAsyncKeyState(0x10) < 0 {
                            let generation = GENERATION.fetch_add(1, Ordering::AcqRel) + 1;
                            state.pending = Some(ReadRequest {
                                anchor: (point.x, point.y),
                                foreground: GetForegroundWindow(),
                                generation,
                            });
                            SetTimer(hwnd, SELECTION_TIMER, 140, null());
                        }
                        state.last_click = Some((point, now));
                    }
                }
            });
            if let Some(callback) = dismiss {
                callback();
            }
            return 0;
        }
        OWN_INPUT => {
            GENERATION.fetch_add(1, Ordering::AcqRel);
            KillTimer(hwnd, SELECTION_TIMER);
            STATE.with(|cell| {
                if let Some(state) = cell.borrow_mut().as_mut() {
                    state.down = None;
                    state.last_click = None;
                    state.pending = None;
                }
            });
            return 0;
        }
        0x113 if wparam == SELECTION_TIMER => {
            KillTimer(hwnd, SELECTION_TIMER);
            STATE.with(|cell| {
                if let Some(state) = cell.borrow_mut().as_mut() {
                    if let Some(request) = state.pending.take() {
                        let _ = state.read.send(request);
                    }
                }
            });
            return 0;
        }
        0x113 if wparam == LAUNCHER_TIMER => {
            KillTimer(hwnd, LAUNCHER_TIMER);
            STATE.with(|cell| {
                if let Some(state) = cell.borrow_mut().as_mut() {
                    ShowWindow(state.launcher, 0);
                    state.selection = None;
                }
            });
            return 0;
        }
        _ => {}
    }
    DefWindowProcW(hwnd, message, wparam, lparam)
}

unsafe extern "system" fn launcher_proc(
    hwnd: Handle,
    message: u32,
    wparam: usize,
    lparam: isize,
) -> isize {
    match message {
        0x21 => return 3, // MA_NOACTIVATE: retain the source application's selection.
        0x202 => {
            let action = STATE.with(|cell| {
                let mut state = cell.borrow_mut();
                let state = state.as_mut()?;
                ShowWindow(hwnd, 0);
                state
                    .selection
                    .take()
                    .map(|selection| (state.callbacks.on_translate.clone(), selection))
            });
            if let Some((callback, selection)) = action {
                callback(selection.text, selection.app, selection.anchor);
            }
            return 0;
        }
        0xf => {
            let mut paint: Paint = zeroed();
            let dc = BeginPaint(hwnd, &mut paint);
            let mut bounds = Rect::default();
            GetClientRect(hwnd, &mut bounds);
            let white = CreateSolidBrush(WHITE);
            FillRect(dc, &bounds, white);
            DeleteObject(white);
            let brush = CreateSolidBrush(BLUE);
            let previous_brush = SelectObject(dc, brush);
            let pen = CreatePen(0, 1, BLUE);
            let previous_pen = SelectObject(dc, pen);
            RoundRect(dc, 0, 0, bounds.right, bounds.bottom, 9, 9);
            let font = CreateFontW(
                -(bounds.bottom * 4 / 5),
                0,
                0,
                0,
                600,
                1,
                0,
                0,
                1,
                0,
                0,
                5,
                0,
                wide("Georgia").as_ptr(),
            );
            let previous_font = SelectObject(dc, font);
            SetBkMode(dc, 1);
            SetTextColor(dc, WHITE);
            bounds.top += 1;
            DrawTextW(dc, wide("T").as_ptr(), 1, &mut bounds, 1 | 4 | 0x20);
            SelectObject(dc, previous_font);
            SelectObject(dc, previous_pen);
            SelectObject(dc, previous_brush);
            DeleteObject(font);
            DeleteObject(pen);
            DeleteObject(brush);
            EndPaint(hwnd, &paint);
            return 0;
        }
        0x14 => return 1,
        _ => {}
    }
    DefWindowProcW(hwnd, message, wparam, lparam)
}

fn selection_worker(requests: mpsc::Receiver<ReadRequest>) {
    unsafe {
        if CoInitializeEx(None, COINIT_MULTITHREADED).is_err() {
            return;
        }
        // The Windows 8+ client exposes IUIAutomation2 timeouts. The
        // legacy CUIAutomation class can silently omit those bounds.
        let automation: Result<IUIAutomation, _> =
            CoCreateInstance(&CUIAutomation8, None, CLSCTX_INPROC_SERVER);
        if let Ok(automation) = automation {
            if let Ok(settings) = automation.cast::<IUIAutomation2>() {
                let _ = settings.SetConnectionTimeout(150);
                let _ = settings.SetTransactionTimeout(350);
            }
            while let Ok(mut request) = requests.recv() {
                while let Ok(newer) = requests.try_recv() {
                    request = newer;
                }
                if request.generation != GENERATION.load(Ordering::Acquire)
                    || GetForegroundWindow() != request.foreground
                {
                    selection_test_reason(5);
                    continue;
                }
                if selection_test_enabled() {
                    SELECTION_READS.fetch_add(1, Ordering::AcqRel);
                }
                selection_test_reason(1);
                let mut content = read_selection(&automation, &request);
                if content.is_none()
                    && request.generation == GENERATION.load(Ordering::Acquire)
                    && GetForegroundWindow() == request.foreground
                {
                    thread::sleep(Duration::from_millis(100));
                    if request.generation == GENERATION.load(Ordering::Acquire) {
                        content = read_selection(&automation, &request);
                    }
                }
                if let Some((text, app)) = content {
                    selection_test_reason(3);
                    let selection = Box::new(Selection {
                        text,
                        app,
                        anchor: request.anchor,
                        foreground: request.foreground,
                        generation: request.generation,
                    });
                    let pointer = Box::into_raw(selection);
                    if post(SELECTED, 0, pointer as isize).is_err() {
                        drop(Box::from_raw(pointer));
                    }
                } else {
                    selection_test_reason(2);
                }
            }
        }
        CoUninitialize();
    }
}
unsafe fn read_selection(
    automation: &IUIAutomation,
    request: &ReadRequest,
) -> Option<(String, String)> {
    if !foreign_window(request.foreground) || GetForegroundWindow() != request.foreground {
        return None;
    }
    let started = Instant::now();
    let deadline = started + Duration::from_millis(650);
    let foreground_root = GetAncestor(request.foreground, 2);
    let mut native_candidates = Vec::new();
    let mut gui: GuiThreadInfo = zeroed();
    gui.size = size_of::<GuiThreadInfo>() as u32;
    if GetGUIThreadInfo(0, &mut gui) != 0 && window_belongs_to(gui.focus, foreground_root) {
        let mut class = [0u16; 128];
        let length = GetClassNameW(gui.focus, class.as_mut_ptr(), class.len() as i32);
        if legacy_edit_kind(&String::from_utf16_lossy(&class[..length.max(0) as usize])).is_some()
            && (GetWindowLongPtrW(gui.focus, -16) & 0x20 != 0
                || bounded_message(gui.focus, 0xd2, 0, 0, deadline).is_none_or(|value| value != 0))
        {
            return None;
        }
        native_candidates.push(gui.focus);
    }
    let pointed_window = WindowFromPoint(Point {
        x: request.anchor.0,
        y: request.anchor.1,
    });
    if window_belongs_to(pointed_window, foreground_root) {
        native_candidates.push(pointed_window);
    }

    let mut candidates = Vec::new();
    let mut search_roots = Vec::new();
    if let Ok(walker) = automation.ControlViewWalker() {
        if Instant::now() >= deadline {
            return None;
        }
        let root = automation
            .ElementFromHandle(HWND(foreground_root as *mut c_void))
            .ok();
        let mut seeds = Vec::new();
        // Chromium creates its web accessibility provider on demand. Query
        // the source-owned renderer HWND through UIA as well as the focused
        // and pointed elements: a cold point query can still hit browser UI.
        // No browser flags, synthetic input or clipboard access are needed.
        let mut renderer_handles = native_candidates.clone();
        renderer_handles.sort_unstable();
        renderer_handles.dedup();
        for handle in renderer_handles {
            if Instant::now() >= deadline {
                return None;
            }
            if is_chromium_renderer(&window_class(handle)) {
                if let Ok(element) = automation.ElementFromHandle(HWND(handle as *mut c_void)) {
                    seeds.push(element);
                }
            }
        }
        if Instant::now() >= deadline {
            return None;
        }
        if let Ok(element) = automation.GetFocusedElement() {
            seeds.push(element);
        }
        if Instant::now() >= deadline {
            return None;
        }
        if let Ok(element) = automation.ElementFromPoint(POINT {
            x: request.anchor.0,
            y: request.anchor.1,
        }) {
            seeds.push(element);
        }
        // A packaged app may put its focused content in a different process
        // from the foreground ApplicationFrameWindow. Verify its ancestor
        // window instead of requiring identical foreground/content PIDs.
        for seed in seeds {
            if Instant::now() >= deadline {
                return None;
            }
            match safe_element_chain(
                automation, &walker, seed, foreground_root, root.as_ref(), deadline,
            ) {
                ElementChain::Protected => return None,
                ElementChain::Safe(chain) => {
                    if let Some(first) = chain.first() {
                        search_roots.push(first.clone());
                    }
                    for element in chain {
                        add_element(&mut candidates, element);
                    }
                }
                ElementChain::Unrelated => {}
            }
        }
        for element in &candidates {
            if Instant::now() >= deadline {
                break;
            }
            if let Ok(handle) = element.CurrentNativeWindowHandle() {
                let handle = handle.0 as Handle;
                if window_belongs_to(handle, foreground_root) {
                    native_candidates.push(handle);
                }
            }
            if let Some(text) = selected_pattern_text(element) {
                if GetForegroundWindow() == request.foreground {
                    return Some((text, window_title(request.foreground)));
                }
                return None;
            }
        }
        // Prefer a real selected TextPattern before requesting TextChild on
        // every ancestor. Cold browser providers can otherwise spend the
        // entire read budget hydrating patterns before GetSelection is tried.
        // TextChild is only a route to its validated container; its child or
        // document range is never treated as a user selection.
        for element in &candidates {
            if Instant::now() >= deadline {
                break;
            }
            if let Ok(child) =
                element.GetCurrentPatternAs::<IUIAutomationTextChildPattern>(UIA_TextChildPatternId)
            {
                if let Ok(container) = child.TextContainer() {
                    if let ElementChain::Safe(chain) = safe_element_chain(
                        automation,
                        &walker,
                        container,
                        foreground_root,
                        root.as_ref(),
                        deadline,
                    ) {
                        if let Some(text) = chain
                            .first()
                            .and_then(|element| selected_pattern_text(element))
                        {
                            if GetForegroundWindow() == request.foreground {
                                return Some((text, window_title(request.foreground)));
                            }
                            return None;
                        }
                    }
                }
            }
        }
        // Some note editors focus a container while exposing the selected
        // rich text through one of its children. Search only these small
        // focused/pointed subtrees, never the whole app or desktop.
        let mut queue = search_roots
            .into_iter()
            .map(|element| (element, 0))
            .collect::<Vec<_>>();
        let mut visited = 0;
        while let Some((element, depth)) = queue.pop() {
            if visited >= 24 || Instant::now() >= deadline {
                break;
            }
            if depth >= 3 {
                continue;
            }
            let mut child = walker.GetFirstChildElement(&element).ok();
            while let Some(element) = child {
                if visited >= 24 || Instant::now() >= deadline {
                    break;
                }
                visited += 1;
                child = walker.GetNextSiblingElement(&element).ok();
                if let ElementChain::Safe(_) = safe_element_chain(
                    automation,
                    &walker,
                    element.clone(),
                    foreground_root,
                    root.as_ref(),
                    deadline,
                ) {
                    if let Some(text) = selected_pattern_text(&element) {
                        if GetForegroundWindow() == request.foreground {
                            return Some((text, window_title(request.foreground)));
                        }
                        return None;
                    }
                    queue.push((element, depth + 1));
                }
            }
        }
    }
    native_candidates.sort_unstable();
    native_candidates.dedup();
    for handle in native_candidates.into_iter().take(8) {
        if Instant::now() >= deadline {
            break;
        }
        if let Some(text) = read_legacy_edit_selection(handle, request.foreground, deadline) {
            return Some((text, window_title(request.foreground)));
        }
    }
    None
}

enum ElementChain {
    Safe(Vec<IUIAutomationElement>),
    Protected,
    Unrelated,
}
unsafe fn safe_element_chain(
    automation: &IUIAutomation,
    walker: &IUIAutomationTreeWalker,
    seed: IUIAutomationElement,
    foreground_root: Handle,
    root: Option<&IUIAutomationElement>,
    deadline: Instant,
) -> ElementChain {
    let mut chain = Vec::new();
    let mut current = Some(seed);
    let mut belongs = false;
    let mut protected = false;
    let mut uncertain = false;
    // Web content can include dozens of semantic ancestors before reaching
    // its renderer HWND. Keep the time bound while allowing that ancestry.
    for _ in 0..MAX_SELECTION_ANCESTORS {
        if Instant::now() >= deadline {
            return ElementChain::Unrelated;
        }
        let Some(element) = current else {
            break;
        };
        match element.CurrentIsPassword() {
            Ok(value) => protected |= value.as_bool(),
            Err(_) => uncertain = true,
        }
        let handle = element
            .CurrentNativeWindowHandle()
            .ok()
            .map(|handle| handle.0 as Handle);
        belongs |= handle.is_some_and(|handle| window_belongs_to(handle, foreground_root));
        let at_root = handle == Some(foreground_root)
            || root.is_some_and(|root| {
                automation
                    .CompareElements(&element, root)
                    .is_ok_and(|v| v.as_bool())
            });
        belongs |= at_root;
        current = if at_root {
            None
        } else {
            walker.GetParentElement(&element).ok()
        };
        chain.push(element);
        if at_root {
            break;
        }
    }
    if !belongs {
        ElementChain::Unrelated
    } else if protected {
        ElementChain::Protected
    } else if uncertain {
        ElementChain::Unrelated
    } else {
        ElementChain::Safe(chain)
    }
}
fn add_element(
    elements: &mut Vec<IUIAutomationElement>,
    element: IUIAutomationElement,
) {
    // Four seeds can each contribute a full bounded ancestor chain. Avoid
    // truncating a deep Document or a later focused/pointed seed. Pointer
    // identity only avoids exact duplicates locally; different COM wrappers
    // may remain, with no cross-process comparison for each pair.
    if elements.len() < MAX_SELECTION_CANDIDATES
        && !elements.iter().any(|existing| existing.as_raw() == element.as_raw())
    {
        elements.push(element);
    }
}
unsafe fn selected_pattern_text(element: &IUIAutomationElement) -> Option<String> {
    if element.CurrentIsPassword().ok()?.as_bool() {
        return None;
    }
    let pattern = element
        .GetCurrentPatternAs::<IUIAutomationTextPattern>(UIA_TextPatternId)
        .ok()
        .or_else(|| {
            element
                .GetCurrentPatternAs::<IUIAutomationTextPattern2>(UIA_TextPattern2Id)
                .ok()
                .map(Into::into)
        })?;
    let ranges = pattern.GetSelection().ok()?;
    let count = ranges.Length().ok()?;
    if !(1..=8).contains(&count) {
        return None;
    }
    let mut parts = Vec::new();
    for index in 0..count {
        let text = ranges
            .GetElement(index)
            .and_then(|range| range.GetText(32_001))
            .ok()?
            .to_string();
        if text.encode_utf16().count() >= 32_001 {
            return None;
        }
        if !text.trim().is_empty() {
            parts.push(text);
        }
    }
    clean_selection(parts.join("\n"))
}
fn clean_selection(text: String) -> Option<String> {
    if text.chars().count() > 16_000 {
        return None;
    }
    let text = text.trim();
    if text.is_empty() || text.chars().count() > 16_000 || text.chars().all(char::is_control) {
        None
    } else {
        Some(text.to_owned())
    }
}
unsafe fn window_title(window: Handle) -> String {
    let mut title = [0u16; 512];
    let count = GetWindowTextW(window, title.as_mut_ptr(), title.len() as i32);
    String::from_utf16_lossy(&title[..count.max(0) as usize])
}
unsafe fn window_belongs_to(window: Handle, foreground_root: Handle) -> bool {
    window != 0
        && foreground_root != 0
        && (window == foreground_root || GetAncestor(window, 2) == foreground_root)
}
fn legacy_edit_kind(class: &str) -> Option<bool> {
    let class = class.to_ascii_lowercase();
    if class == "edit" || class.starts_with("windowsforms10.edit.") {
        Some(false)
    } else if class.starts_with("richedit") || class.starts_with("windowsforms10.richedit") {
        Some(true)
    } else {
        None
    }
}
fn is_chromium_renderer(class: &str) -> bool {
    class.eq_ignore_ascii_case("Chrome_RenderWidgetHostHWND")
}
unsafe fn window_class(window: Handle) -> String {
    let mut class = [0u16; 128];
    let length = GetClassNameW(window, class.as_mut_ptr(), class.len() as i32);
    String::from_utf16_lossy(&class[..length.max(0) as usize])
}
unsafe fn bounded_message(
    window: Handle,
    message: u32,
    wparam: usize,
    lparam: isize,
    deadline: Instant,
) -> Option<usize> {
    let remaining = deadline
        .checked_duration_since(Instant::now())?
        .as_millis()
        .min(100) as u32;
    if remaining == 0 {
        return None;
    }
    let mut result = 0;
    (SendMessageTimeoutW(
        window,
        message,
        wparam,
        lparam,
        0x23,
        remaining,
        &mut result,
    ) != 0)
        .then_some(result)
}
unsafe fn read_legacy_edit_selection(
    window: Handle,
    foreground: Handle,
    deadline: Instant,
) -> Option<String> {
    if GetForegroundWindow() != foreground
        || !window_belongs_to(window, GetAncestor(foreground, 2))
        || IsWindowUnicode(window) == 0
    {
        return None;
    }
    let mut class = [0u16; 128];
    let length = GetClassNameW(window, class.as_mut_ptr(), class.len() as i32);
    let rich = legacy_edit_kind(&String::from_utf16_lossy(&class[..length.max(0) as usize]))?;
    // Only the actual Windows EDIT/RichEdit controls have this fallback. Never
    // issue WM_COPY, keyboard shortcuts or read password controls.
    if GetWindowLongPtrW(window, -16) & 0x20 != 0 {
        return None;
    } // ES_PASSWORD
    if bounded_message(window, 0xd2, 0, 0, deadline)? != 0 {
        return None;
    } // EM_GETPASSWORDCHAR
    let mut pid = 0;
    GetWindowThreadProcessId(window, &mut pid);
    let send = |message, wparam, lparam| {
        (GetForegroundWindow() == foreground
            && window_belongs_to(window, GetAncestor(foreground, 2)))
        .then(|| bounded_message(window, message, wparam, lparam, deadline))
        .flatten()
    };
    let (mut start, mut end) = (0u32, 0u32);
    send(
        0xb0,
        (&mut start as *mut u32) as usize,
        (&mut end as *mut u32) as isize,
    )?;
    if end <= start || end - start > 32_000 || end > 65_535 {
        return None;
    }
    let length = send(0xe, 0, 0)?;
    if length == 0 || length > 65_535 {
        return None;
    }
    let mut text = vec![0u16; length + 1];
    let copied = send(0xd, text.len(), text.as_mut_ptr() as isize)?;
    if copied > length {
        return None;
    }
    text.truncate(copied);
    let (mut confirmed_start, mut confirmed_end) = (0u32, 0u32);
    send(
        0xb0,
        (&mut confirmed_start as *mut u32) as usize,
        (&mut confirmed_end as *mut u32) as isize,
    )?;
    let mut current_pid = 0;
    GetWindowThreadProcessId(window, &mut current_pid);
    if (start, end) != (confirmed_start, confirmed_end)
        || pid != current_pid
        || GetForegroundWindow() != foreground
    {
        return None;
    }
    legacy_selection_text(&text, start as usize, end as usize, rich)
}
fn legacy_selection_text(text: &[u16], start: usize, end: usize, rich: bool) -> Option<String> {
    let normalized;
    let text = if rich {
        // RichEdit selection positions count one CR per paragraph, whereas
        // WM_GETTEXT expands it to CRLF. Index UTF-16, including surrogate pairs.
        normalized = text
            .iter()
            .copied()
            .enumerate()
            .filter_map(|(index, ch)| {
                (!(ch == 10 && index > 0 && text[index - 1] == 13)).then_some(ch)
            })
            .collect::<Vec<_>>();
        normalized.as_slice()
    } else {
        text
    };
    if start >= end || end > text.len() {
        return None;
    }
    clean_selection(String::from_utf16(&text[start..end]).ok()?)
}

unsafe fn begin_capture() {
    GENERATION.fetch_add(1, Ordering::AcqRel);
    // ShowWindow may synchronously dispatch WM_ACTIVATE. Mark the old overlay
    // inactive and release STATE before calling any window activation APIs.
    CAPTURE_ACTIVE.store(false, Ordering::Release);
    let callbacks = STATE.with(|cell| cell.borrow().as_ref().map(|state| state.callbacks.clone()));
    let Some(callbacks) = callbacks else {
        return;
    };
    let handles = STATE.with(|cell| {
        cell.borrow_mut().as_mut().map(|state| {
            state.capture = None;
            (state.launcher, state.overlay)
        })
    });
    if let Some((launcher, overlay)) = handles {
        ShowWindow(launcher, 0);
        ShowWindow(overlay, 0);
    }
    // Let DWM present the hidden launcher/old outline before sampling pixels.
    DwmFlush();
    match desktop_image() {
        Ok(image) => {
            let prepared = STATE.with(|cell| {
                cell.borrow_mut().as_mut().map(|state| {
                    let frame = (image.left, image.top, image.width, image.height);
                    state.capture = Some(Capture {
                        image,
                        points: Vec::new(),
                        drawing: false,
                        rectangle: false,
                        finished: false,
                    });
                    (state.overlay, frame)
                })
            });
            if let Some((overlay, frame)) = prepared {
                SetWindowLongPtrW(overlay, -20, (EX_TOOLWINDOW | EX_TOPMOST) as isize);
                CAPTURE_ACTIVE.store(true, Ordering::Release);
                SetWindowPos(overlay, -1, frame.0, frame.1, frame.2, frame.3, 0x40);
                SetForegroundWindow(overlay);
                InvalidateRect(overlay, null(), 0);
            }
        }
        Err(error) => (callbacks.on_error)(error),
    }
}

unsafe fn desktop_image() -> Result<DesktopImage, String> {
    let left = GetSystemMetrics(76);
    let top = GetSystemMetrics(77);
    let width = GetSystemMetrics(78);
    let height = GetSystemMetrics(79);
    let bytes = (width as i64)
        .checked_mul(height as i64)
        .and_then(|n| n.checked_mul(4))
        .filter(|n| *n > 0 && *n <= 256 * 1024 * 1024)
        .ok_or("The combined display area is too large to capture.")? as usize;
    let screen = GetDC(0);
    let memory = CreateCompatibleDC(screen);
    let bitmap = CreateCompatibleBitmap(screen, width, height);
    if screen == 0 || memory == 0 || bitmap == 0 {
        if bitmap != 0 {
            DeleteObject(bitmap);
        }
        if memory != 0 {
            DeleteDC(memory);
        }
        if screen != 0 {
            ReleaseDC(0, screen);
        }
        return Err("Windows could not capture the display.".into());
    }
    let previous = SelectObject(memory, bitmap);
    let copied = BitBlt(memory, 0, 0, width, height, screen, left, top, 0x40cc0020);
    SelectObject(memory, previous);
    let mut pixels = vec![0u8; bytes];
    let mut info = BitmapInfo {
        size: 40,
        width,
        height: -height,
        planes: 1,
        bits: 32,
        compression: 0,
        image_size: 0,
        xppm: 0,
        yppm: 0,
        used: 0,
        important: 0,
        colors: [0],
    };
    let rows = GetDIBits(
        memory,
        bitmap,
        0,
        height as u32,
        pixels.as_mut_ptr().cast(),
        &mut info,
        0,
    );
    DeleteDC(memory);
    ReleaseDC(0, screen);
    if copied == 0 || rows != height {
        DeleteObject(bitmap);
        return Err(
            "Windows could not read the display pixels. Protected windows cannot be captured."
                .into(),
        );
    }
    Ok(DesktopImage {
        left,
        top,
        width,
        height,
        pixels,
        bitmap,
    })
}

unsafe extern "system" fn capture_proc(
    hwnd: Handle,
    message: u32,
    wparam: usize,
    lparam: isize,
) -> isize {
    match message {
        0x20 => {
            SetCursor(LoadCursorW(0, 32515usize as *const u16));
            return 1;
        }
        0x100 if wparam == 0x1b => {
            cancel_capture();
            return 0;
        }
        0x6 if wparam & 0xffff == 0 && CAPTURE_ACTIVE.load(Ordering::Acquire) => {
            cancel_capture();
            return 0;
        }
        0x7e => {
            cancel_capture();
            return 0;
        }
        0x201 => {
            STATE.with(|cell| {
                if let Some(capture) = cell
                    .borrow_mut()
                    .as_mut()
                    .and_then(|state| state.capture.as_mut())
                {
                    if capture.finished {
                        return;
                    }
                    capture.drawing = true;
                    capture.rectangle = GetAsyncKeyState(0x10) < 0;
                    capture.points = vec![unpack_point(lparam)];
                    SetCapture(hwnd);
                }
            });
            InvalidateRect(hwnd, null(), 0);
            return 0;
        }
        0x200 => {
            STATE.with(|cell| {
                if let Some(capture) = cell
                    .borrow_mut()
                    .as_mut()
                    .and_then(|state| state.capture.as_mut())
                {
                    if !capture.drawing || capture.finished {
                        return;
                    }
                    let point = unpack_point(lparam);
                    if capture
                        .points
                        .last()
                        .is_some_and(|last| (point.x - last.x).abs() + (point.y - last.y).abs() < 2)
                    {
                        return;
                    }
                    capture.rectangle = GetAsyncKeyState(0x10) < 0;
                    if capture.points.len() < 8192 {
                        capture.points.push(point);
                    }
                    InvalidateRect(hwnd, null(), 0);
                }
            });
            return 0;
        }
        0x202 => {
            ReleaseCapture();
            finish_capture(unpack_point(lparam));
            return 0;
        }
        0xf => {
            let mut paint: Paint = zeroed();
            let dc = BeginPaint(hwnd, &mut paint);
            STATE.with(|cell| {
                if let Some(capture) = cell
                    .borrow()
                    .as_ref()
                    .and_then(|state| state.capture.as_ref())
                {
                    paint_capture(dc, capture);
                }
            });
            EndPaint(hwnd, &paint);
            return 0;
        }
        0x14 => return 1,
        0x84 if !CAPTURE_ACTIVE.load(Ordering::Relaxed) => return -1,
        _ => {}
    }
    DefWindowProcW(hwnd, message, wparam, lparam)
}
unsafe fn cancel_capture() {
    CAPTURE_ACTIVE.store(false, Ordering::Release);
    let overlay = STATE.with(|cell| {
        cell.borrow_mut().as_mut().map(|state| {
            state.capture = None;
            state.overlay
        })
    });
    if let Some(overlay) = overlay {
        ShowWindow(overlay, 0);
    }
}
fn polygon_points(capture: &Capture) -> Vec<Point> {
    if capture.rectangle && capture.points.len() >= 2 {
        let first = capture.points[0];
        let last = *capture.points.last().unwrap();
        vec![
            first,
            Point {
                x: last.x,
                y: first.y,
            },
            last,
            Point {
                x: first.x,
                y: last.y,
            },
            first,
        ]
    } else {
        let mut points = capture.points.clone();
        if points.len() > 2 {
            points.push(points[0]);
        }
        points
    }
}
unsafe fn finish_capture(point: Point) {
    let mut cancelled = false;
    let work = STATE.with(|cell| {
        let mut state = cell.borrow_mut();
        let state = state.as_mut()?;
        let capture = state.capture.as_mut()?;
        if !capture.drawing || capture.finished {
            return None;
        }
        capture.drawing = false;
        capture.rectangle = GetAsyncKeyState(0x10) < 0;
        capture.points.push(point);
        let polygon = polygon_points(capture);
        let left = polygon
            .iter()
            .map(|p| p.x)
            .min()?
            .clamp(0, capture.image.width - 1);
        let top = polygon
            .iter()
            .map(|p| p.y)
            .min()?
            .clamp(0, capture.image.height - 1);
        let right = polygon
            .iter()
            .map(|p| p.x)
            .max()?
            .clamp(left + 1, capture.image.width);
        let bottom = polygon
            .iter()
            .map(|p| p.y)
            .max()?
            .clamp(top + 1, capture.image.height);
        let width = right - left;
        let height = bottom - top;
        if polygon.len() < 4 || width < 8 || height < 8 {
            cancelled = true;
            return None;
        }
        let mut pixels = vec![255; width as usize * height as usize * 4];
        for y in 0..height {
            let source = (((top + y) * capture.image.width + left) * 4) as usize;
            let destination = (y * width * 4) as usize;
            pixels[destination..destination + width as usize * 4]
                .copy_from_slice(&capture.image.pixels[source..source + width as usize * 4]);
        }
        let local_polygon = polygon
            .iter()
            .map(|p| ((p.x - left) as f64, (p.y - top) as f64))
            .collect::<Vec<_>>();
        let anchor = (capture.image.left + right + 12, capture.image.top + top);
        capture.finished = true;
        // The retained outline needs only geometry. Release the full desktop
        // capture now rather than keeping it for a pinned translation window.
        capture.image.pixels.clear();
        capture.image.pixels.shrink_to_fit();
        DeleteObject(capture.image.bitmap);
        capture.image.bitmap = 0;
        CAPTURE_ACTIVE.store(false, Ordering::Release);
        Some((
            state.callbacks.clone(),
            width as u32,
            height as u32,
            pixels,
            local_polygon,
            anchor,
            GENERATION.load(Ordering::Acquire),
            state.overlay,
        ))
    });
    if cancelled {
        cancel_capture();
    }
    let Some((callbacks, width, height, pixels, polygon, anchor, generation, overlay)) = work
    else {
        return;
    };
    SetWindowLongPtrW(
        overlay,
        -20,
        (EX_TOOLWINDOW | EX_TOPMOST | EX_NOACTIVATE | EX_LAYERED | EX_TRANSPARENT) as isize,
    );
    SetLayeredWindowAttributes(overlay, WHITE, 255, 1);
    InvalidateRect(overlay, null(), 1);
    (callbacks.on_recognizing)(anchor);
    thread::Builder::new()
        .name("transpose-ocr".into())
        .spawn(move || {
            let initialization = unsafe { RoInitialize(1) };
            let result = if initialization >= 0 {
                ocr::recognize(width, height, pixels, polygon)
            } else {
                Err(format!(
                    "Windows OCR initialization failed: 0x{:08x}",
                    initialization as u32
                ))
            };
            if initialization >= 0 {
                unsafe {
                    RoUninitialize();
                }
            }
            if generation != GENERATION.load(Ordering::Acquire) {
                return;
            }
            match result {
                Ok(text) => (callbacks.on_translate)(text, "Screen".into(), anchor),
                Err(error) => (callbacks.on_error)(error),
            }
        })
        .ok();
}
unsafe fn paint_capture(dc: Handle, capture: &Capture) {
    let bounds = Rect {
        left: 0,
        top: 0,
        right: capture.image.width,
        bottom: capture.image.height,
    };
    if capture.finished {
        let brush = CreateSolidBrush(WHITE);
        FillRect(dc, &bounds, brush);
        DeleteObject(brush);
    } else {
        let memory = CreateCompatibleDC(dc);
        let previous = SelectObject(memory, capture.image.bitmap);
        BitBlt(
            dc,
            0,
            0,
            capture.image.width,
            capture.image.height,
            memory,
            0,
            0,
            0x00cc0020,
        );
        SelectObject(memory, previous);
        DeleteDC(memory);
    }
    let points = if capture.finished || capture.rectangle {
        polygon_points(capture)
    } else {
        capture.points.clone()
    };
    if !points.is_empty() {
        let halo = CreatePen(0, 5, WHITE);
        let previous = SelectObject(dc, halo);
        if points.len() > 1 {
            Polyline(dc, points.as_ptr(), points.len() as i32);
        }
        let line = CreatePen(0, 2, BLUE);
        SelectObject(dc, line);
        if points.len() > 1 {
            Polyline(dc, points.as_ptr(), points.len() as i32);
        }
        let dot = CreateSolidBrush(BLUE);
        let previous_brush = SelectObject(dc, dot);
        let start = points[0];
        Ellipse(dc, start.x - 3, start.y - 3, start.x + 4, start.y + 4);
        SelectObject(dc, previous_brush);
        SelectObject(dc, previous);
        DeleteObject(dot);
        DeleteObject(line);
        DeleteObject(halo);
    } else if !capture.finished {
        let mut hint = Rect {
            left: bounds.right / 2 - 210,
            top: 24,
            right: bounds.right / 2 + 210,
            bottom: 56,
        };
        let paper = CreateSolidBrush(WHITE);
        let previous_brush = SelectObject(dc, paper);
        let previous_pen = SelectObject(dc, GetStockObject(8));
        RoundRect(dc, hint.left, hint.top, hint.right, hint.bottom, 16, 16);
        SetBkMode(dc, 1);
        SetTextColor(dc, 0x00534942);
        let font = CreateFontW(
            -14,
            0,
            0,
            0,
            400,
            0,
            0,
            0,
            1,
            0,
            0,
            5,
            0,
            wide("Segoe UI").as_ptr(),
        );
        let previous_font = SelectObject(dc, font);
        let text = wide("Draw to translate · Shift: rectangle · Esc: cancel");
        DrawTextW(
            dc,
            text.as_ptr(),
            text.len() as i32 - 1,
            &mut hint,
            1 | 4 | 0x20,
        );
        SelectObject(dc, previous_font);
        SelectObject(dc, previous_pen);
        SelectObject(dc, previous_brush);
        DeleteObject(font);
        DeleteObject(paper);
    }
}

pub fn copy_text(text: &str) -> Result<(), String> {
    let utf16 = wide(text);
    unsafe {
        let memory = GlobalAlloc(0x42, utf16.len() * 2);
        if memory == 0 {
            return Err("Windows could not allocate clipboard storage.".into());
        }
        let pointer = GlobalLock(memory);
        if pointer.is_null() {
            GlobalFree(memory);
            return Err("Windows could not write to the clipboard.".into());
        }
        std::ptr::copy_nonoverlapping(utf16.as_ptr(), pointer.cast(), utf16.len());
        GlobalUnlock(memory);
        let owner = CONTROLLER.load(Ordering::Acquire) as Handle;
        if OpenClipboard(owner) == 0 {
            GlobalFree(memory);
            return Err("The clipboard is busy. Please try again.".into());
        }
        EmptyClipboard();
        let stored = SetClipboardData(13, memory);
        CloseClipboard();
        if stored == 0 {
            GlobalFree(memory);
            Err("Windows could not update the clipboard.".into())
        } else {
            Ok(())
        }
    }
}

const RUN_KEY: &str = "Software\\Microsoft\\Windows\\CurrentVersion\\Run";
pub fn set_launch_at_login(enabled: bool) -> Result<(), String> {
    let path = std::env::current_exe().map_err(|e| e.to_string())?;
    let command = wide(&format!("\"{}\" --background", path.to_string_lossy()));
    unsafe {
        let mut key = 0;
        let created = RegCreateKeyExW(
            -2147483647,
            wide(RUN_KEY).as_ptr(),
            0,
            null(),
            0,
            0x2,
            null(),
            &mut key,
            null_mut(),
        );
        if created != 0 {
            return Err("Windows could not update launch at login.".into());
        }
        let result = if enabled {
            RegSetValueExW(
                key,
                wide("Transpose").as_ptr(),
                0,
                1,
                command.as_ptr().cast(),
                (command.len() * 2) as u32,
            )
        } else {
            RegDeleteValueW(key, wide("Transpose").as_ptr())
        };
        RegCloseKey(key);
        if result == 0 || (!enabled && result == 2) {
            Ok(())
        } else {
            Err("Windows could not update launch at login.".into())
        }
    }
}
pub fn launch_at_login() -> bool {
    unsafe {
        let mut key = 0;
        if RegOpenKeyExW(-2147483647, wide(RUN_KEY).as_ptr(), 0, 0x1, &mut key) != 0 {
            return false;
        }
        let mut bytes = [0u16; 2048];
        let mut len = (bytes.len() * 2) as u32;
        let mut kind = 0;
        let result = RegQueryValueExW(
            key,
            wide("Transpose").as_ptr(),
            null_mut(),
            &mut kind,
            bytes.as_mut_ptr().cast(),
            &mut len,
        );
        RegCloseKey(key);
        if result != 0 || kind != 1 {
            return false;
        }
        let command = String::from_utf16_lossy(
            &bytes[..(len as usize / 2).saturating_sub(1).min(bytes.len())],
        );
        std::env::current_exe()
            .is_ok_and(|path| command == format!("\"{}\" --background", path.to_string_lossy()))
    }
}

#[cfg(test)]
mod selection_compatibility_tests {
    use super::{clean_selection, is_chromium_renderer, legacy_edit_kind, legacy_selection_text};
    #[test]
    fn chromium_activation_is_limited_to_renderer_windows() {
        assert!(is_chromium_renderer("Chrome_RenderWidgetHostHWND"));
        assert!(is_chromium_renderer("chrome_renderwidgethosthwnd"));
        assert!(!is_chromium_renderer("Chrome_WidgetWin_1"));
        assert!(!is_chromium_renderer("Chrome_RenderWidgetHostHWND-unrelated"));
        assert!(!is_chromium_renderer("EDIT"));
    }
    #[test]
    fn native_edit_classes_are_narrow() {
        assert_eq!(legacy_edit_kind("EDIT"), Some(false));
        assert_eq!(legacy_edit_kind("RICHEDIT50W"), Some(true));
        assert_eq!(
            legacy_edit_kind("WindowsForms10.RichEdit20W.app.0.123"),
            Some(true)
        );
        assert_eq!(
            legacy_edit_kind("WindowsForms10.EDIT.app.0.123"),
            Some(false)
        );
        assert_eq!(legacy_edit_kind("Chrome_RenderWidgetHostHWND"), None);
        assert_eq!(legacy_edit_kind("PasswordWidget"), None);
    }
    #[test]
    fn utf16_selection_preserves_supplementary_characters() {
        let text = "a🎹中文z".encode_utf16().collect::<Vec<_>>();
        assert_eq!(
            legacy_selection_text(&text, 1, 5, false).as_deref(),
            Some("🎹中文")
        );
        assert!(legacy_selection_text(&text, 2, 5, false).is_none());
    }
    #[test]
    fn rich_edit_paragraph_positions_use_one_cr() {
        let text = "First line\r\n🎹 Transpose"
            .encode_utf16()
            .collect::<Vec<_>>();
        assert_eq!(
            legacy_selection_text(&text, 14, 23, true).as_deref(),
            Some("Transpose")
        );
        assert_eq!(
            legacy_selection_text(&text, 15, 24, false).as_deref(),
            Some("Transpose")
        );
    }
    #[test]
    fn empty_oversized_and_invalid_ranges_are_rejected() {
        let text = "small".encode_utf16().collect::<Vec<_>>();
        assert!(legacy_selection_text(&text, 0, 0, false).is_none());
        assert!(legacy_selection_text(&text, 1, 20, false).is_none());
        assert!(clean_selection("a".repeat(16_001)).is_none());
        assert!(clean_selection(format!("{}word", " ".repeat(16_001))).is_none());
        assert!(clean_selection("\t\r\n".into()).is_none());
    }
}
