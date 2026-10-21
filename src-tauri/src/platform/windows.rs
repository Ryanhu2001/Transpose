//! Windows desktop integration. UI Automation reads selections without copying;
//! captured pixels remain in memory and Windows OCR runs on a worker thread.
use std::{
    cell::RefCell,
    ffi::c_void,
    mem::{size_of, zeroed},
    ptr::{null, null_mut},
    sync::{
        atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering},
        mpsc, Arc,
    },
    thread,
    time::{Duration, Instant},
};
use windows::Win32::{
    Foundation::{HWND, POINT},
    System::Com::{
        CoCreateInstance, CoInitializeEx, CoUninitialize, CLSCTX_INPROC_SERVER,
        COINIT_MULTITHREADED,
    },
    UI::Accessibility::{
        CUIAutomation, IUIAutomation, IUIAutomationElement, IUIAutomationTextPattern,
        UIA_TextPatternId,
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
const START_CAPTURE: u32 = 0x8001;
const CLEAR_OUTLINE: u32 = 0x8002;
const SELECTED: u32 = 0x8003;
const INPUT: u32 = 0x8004;
const STOP: u32 = 0x8005;
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
    fn SendMessageW(hwnd: Handle, message: u32, wparam: usize, lparam: isize) -> isize;
    fn PostQuitMessage(code: i32);
    fn ShowWindow(hwnd: Handle, command: i32) -> i32;
    fn DestroyWindow(hwnd: Handle) -> i32;
    fn SetWindowPos(hwnd: Handle, after: Handle, x: i32, y: i32, w: i32, h: i32, flags: u32)
        -> i32;
    fn SetWindowLongPtrW(hwnd: Handle, index: i32, value: isize) -> isize;
    fn SetLayeredWindowAttributes(hwnd: Handle, color: u32, alpha: u8, flags: u32) -> i32;
    fn SetForegroundWindow(hwnd: Handle) -> i32;
    fn GetForegroundWindow() -> Handle;
    fn GetWindowThreadProcessId(hwnd: Handle, pid: *mut u32) -> u32;
    fn GetWindowTextW(hwnd: Handle, text: *mut u16, capacity: i32) -> i32;
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
            if selection != "Transpose" {
                return Err(format!(
                    "UI Automation selection fixture returned {selection:?}."
                ));
            }
            Ok(
                serde_json::json!({"screenCapture":capture,"ocrLanguages":languages,"ocr":true,"freeformFilter":true,"selection":true,"networkRequests":0}),
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
    let (ready_tx, ready_rx) = mpsc::sync_channel(1);
    let owner = thread::spawn(move || {
        let window = CreateWindowExW(
            EX_TOOLWINDOW,
            wide("EDIT").as_ptr(),
            wide("Transpose selection fixture").as_ptr(),
            WS_POPUP | 0x10000000 | 0x80,
            30,
            30,
            400,
            80,
            0,
            0,
            GetModuleHandleW(null()),
            null(),
        );
        if window == 0 {
            let _ = ready_tx.send(0);
            return;
        }
        SendMessageW(window, 0xb1, 0, 9); // EM_SETSEL: select exactly "Transpose".
        let _ = ready_tx.send(window);
        let mut message: Message = zeroed();
        while GetMessageW(&mut message, 0, 0, 0) > 0 {
            if message.message == 0x10 {
                DestroyWindow(window);
                break;
            }
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
    });
    let hwnd = ready_rx
        .recv_timeout(Duration::from_secs(5))
        .map_err(|_| "Windows selection fixture did not start.")?;
    if hwnd == 0 {
        return Err("Windows selection fixture could not create a native text field.".into());
    }
    let result = (|| -> windows::core::Result<String> {
        let automation: IUIAutomation =
            CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER)?;
        let element = automation.ElementFromHandle(HWND(hwnd as *mut c_void))?;
        let pattern = element.GetCurrentPatternAs::<IUIAutomationTextPattern>(UIA_TextPatternId)?;
        let ranges = pattern.GetSelection()?;
        let text = ranges.GetElement(0)?.GetText(100)?;
        Ok(text.to_string())
    })();
    PostMessageW(hwnd, 0x10, 0, 0);
    let _ = owner.join();
    result.map_err(|error| format!("Windows UI Automation selection fixture failed: {error}"))
}

unsafe extern "system" fn mouse_hook(code: i32, wparam: usize, lparam: isize) -> isize {
    if code >= 0 && (wparam == 0x201 || wparam == 0x202) && !CAPTURE_ACTIVE.load(Ordering::Relaxed)
    {
        let event = &*(lparam as *const MouseInput);
        let point = pack_point(event.point);
        let _ = post(INPUT, wparam, point);
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
        if selection_key {
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
    let mut pid = 0;
    GetWindowThreadProcessId(hwnd, &mut pid);
    pid != 0 && pid != GetCurrentProcessId()
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
                        SetTimer(hwnd, LAUNCHER_TIMER, 6000, null());
                        InvalidateRect(state.launcher, null(), 0);
                    }
                });
            }
            return 0;
        }
        INPUT => {
            let point = unpack_point(lparam);
            if !foreign_window(WindowFromPoint(point)) {
                return 0;
            }
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
        let automation: Result<IUIAutomation, _> =
            CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER);
        if let Ok(automation) = automation {
            while let Ok(mut request) = requests.recv() {
                while let Ok(newer) = requests.try_recv() {
                    request = newer;
                }
                if request.generation != GENERATION.load(Ordering::Acquire)
                    || GetForegroundWindow() != request.foreground
                {
                    continue;
                }
                if let Some((text, app)) = read_selection(&automation, &request) {
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
    if !foreign_window(request.foreground) {
        return None;
    }
    let focused = automation.GetFocusedElement().ok()?;
    let mut expected_pid = 0;
    GetWindowThreadProcessId(request.foreground, &mut expected_pid);
    if focused.CurrentProcessId().ok()? != expected_pid as i32 {
        return None;
    }
    let walker = automation.ControlViewWalker().ok()?;
    let mut candidates: Vec<IUIAutomationElement> = Vec::new();
    let mut current = Some(focused);
    for _ in 0..5 {
        let Some(element) = current else {
            break;
        };
        if element
            .CurrentIsPassword()
            .map(|v| v.as_bool())
            .unwrap_or(true)
        {
            return None;
        }
        current = walker.GetParentElement(&element).ok();
        candidates.push(element);
    }
    if let Ok(point_element) = automation.ElementFromPoint(POINT {
        x: request.anchor.0,
        y: request.anchor.1,
    }) {
        if point_element.CurrentProcessId().ok() == Some(expected_pid as i32)
            && !point_element.CurrentIsPassword().ok()?.as_bool()
        {
            candidates.push(point_element);
        }
    }
    for element in candidates {
        let Ok(pattern) =
            element.GetCurrentPatternAs::<IUIAutomationTextPattern>(UIA_TextPatternId)
        else {
            continue;
        };
        let Ok(ranges) = pattern.GetSelection() else {
            continue;
        };
        let count = ranges.Length().ok()?.min(8);
        let mut parts = Vec::new();
        for index in 0..count {
            if let Ok(range) = ranges.GetElement(index) {
                if let Ok(text) = range.GetText(16_001) {
                    let text = text.to_string().trim().to_owned();
                    if !text.is_empty() {
                        parts.push(text);
                    }
                }
            }
        }
        let text = parts.join("\n");
        if !text.is_empty()
            && text.chars().count() <= 16_000
            && GetForegroundWindow() == request.foreground
        {
            let mut title = [0u16; 512];
            let count = GetWindowTextW(request.foreground, title.as_mut_ptr(), title.len() as i32);
            return Some((
                text,
                String::from_utf16_lossy(&title[..count.max(0) as usize]),
            ));
        }
    }
    None
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
