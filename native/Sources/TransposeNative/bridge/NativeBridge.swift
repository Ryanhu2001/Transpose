import AppKit
import ApplicationServices
import Combine
import ScreenCaptureKit
import SwiftUI

typealias TransposeNativeCallback = @convention(c) (UnsafePointer<CChar>) -> Void

@MainActor private var nativeBridge: NativeBridge?
@MainActor private var loginLaunch = false

/// Tauri owns NSApplication and its delegate. These entry points only attach
/// native services to the existing application on its main thread.
@_cdecl("transpose_native_start")
func transposeNativeStart(_ callback: @escaping TransposeNativeCallback) {
    let start: @MainActor () -> Void = {
        loginLaunch = loginLaunch || ApplicationLaunchPolicy.isLoginItemLaunch(NSAppleEventManager.shared().currentAppleEvent)
        guard nativeBridge == nil else { nativeBridge?.sendSnapshot(); return }
        let bridge: NativeBridge
        let permissionProbe = CommandLine.arguments.contains("--capture-permission-probe")
        if CommandLine.arguments.contains("--smoke-test") || permissionProbe {
            // Exercise the actual FFI and webview roundtrip without touching
            // the person's saved configuration, credentials, or global input.
            UserDefaults.standard.setVolatileDomain(["appLanguage": "english"], forName: UserDefaults.argumentDomain)
            let suite = "dev.transpose.smoke.\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suite) else { return }
            defaults.set(2, forKey: "connectionSchema")
            defaults.set("apple", forKey: "provider")
            bridge = NativeBridge(callback: callback, settings: AppSettings(defaults: defaults), isSmokeTest: true,
                                  isPermissionProbe: permissionProbe,
                                  cleanup: { defaults.removePersistentDomain(forName: suite) })
        } else {
            bridge = NativeBridge(callback: callback)
        }
        nativeBridge = bridge
        bridge.start()
    }
    if Thread.isMainThread { MainActor.assumeIsolated { start() } }
    else { DispatchQueue.main.async { start() } }
}

@_cdecl("transpose_native_command")
func transposeNativeCommand(_ pointer: UnsafePointer<CChar>?) {
    guard let pointer else { return }
    let copied = String(cString: pointer)
    DispatchQueue.main.async { nativeBridge?.receive(copied) }
}

@_cdecl("transpose_native_stop")
func transposeNativeStop() {
    let stop: @MainActor () -> Void = { nativeBridge?.stop(); nativeBridge = nil }
    if Thread.isMainThread { MainActor.assumeIsolated { stop() } }
    else { DispatchQueue.main.async { stop() } }
}

@_cdecl("transpose_native_is_login_launch")
func transposeNativeIsLoginLaunch() -> Bool {
    guard Thread.isMainThread else { return false }
    return MainActor.assumeIsolated {
        loginLaunch = loginLaunch || ApplicationLaunchPolicy.isLoginItemLaunch(NSAppleEventManager.shared().currentAppleEvent)
        return loginLaunch
    }
}

@MainActor
final class NativeBridge: NSObject {
    private let settings: AppSettings
    private let loginItem: LoginItemManager
    private let selection = SelectionMonitor()
    private let capture = CaptureCoordinator()
    private let translator = TranslationService()
    private let hotKeys = HotKeys()
    private lazy var floating = NativeFloatingUI(onRequest: { [weak self] request in
        self?.receive(request, fromResult: true)
    })
    private var callback: TransposeNativeCallback?
    private var item: NSStatusItem?
    private var translationTask: Task<Void, Never>?
    private var selectionReadTask: Task<Void, Never>?
    private var appleInspectionTask: Task<Void, Never>?
    private var permissionProbeTask: Task<Void, Never>?
    private var generation = UUID()
    private var resultState: NativeResultState?
    private var selected: SelectedContent?
    private var monitors: [Any] = []
    private var subscriptions: Set<AnyCancellable> = []
    private var refreshTimer: Timer?
    private var setupWindow: NSWindow?
    private var setupTarget: TargetLanguage?
    private var queuedSnapshot = false
    private var stopped = false
    private var appleStatus = "正在检查本机语言包…"
    private var appleInspectionID = UUID()
    private var lastPermissionState = ""
    private let isSmokeTest: Bool
    private let isPermissionProbe: Bool
    private var cleanup: (() -> Void)?

    init(callback: @escaping TransposeNativeCallback,
         settings: AppSettings? = nil, loginItem: LoginItemManager? = nil,
         isSmokeTest: Bool = false, isPermissionProbe: Bool = false, cleanup: (() -> Void)? = nil) {
        self.callback = callback
        self.settings = settings ?? AppSettings()
        self.loginItem = loginItem ?? LoginItemManager()
        self.isSmokeTest = isSmokeTest
        self.isPermissionProbe = isPermissionProbe
        self.cleanup = cleanup
        super.init()
    }

    func start() {
        if isPermissionProbe { probeCapturePermission(); return }
        makeMenu()
        if isSmokeTest { inspectAppleLanguages(); sendSnapshot(); return }
        selection.shouldIgnoreEvent = { [weak self] in
            guard let self else { return true }
            return self.capture.isActive || self.capture.containsOutline(NSEvent.mouseLocation) || self.floating.isMouseInside
        }
        selection.isEnabled = settings.automaticSelection
        selection.start(onSelection: { [weak self] content in
            guard let self, self.settings.automaticSelection, !self.capture.isActive else { return }
            self.present(content)
        }, onDeferredSelection: { [weak self] candidate in
            guard let self, self.settings.automaticSelection, !self.capture.isActive else { return }
            self.presentDeferredSelection(candidate)
        }, onDismiss: { [weak self] in self?.floating.hideButton() })
        capture.onCapture = { [weak self] text, anchor in
            self?.translate(SelectedContent(text: text, anchor: anchor, sourceApp: "屏幕圈选"), preservingCapture: true)
        }
        capture.onError = { [weak self] error in
            self?.showError(error, preservingCapture: true)
            self?.queueSnapshot()
        }
        capture.onCancel = { [weak self] in self?.dismiss(force: true) }
        capture.onRecognizing = { [weak self] point in self?.showCaptureRecognizing(at: point) }
        hotKeys.onCapture = { [weak self] in self?.beginCapture() }
        hotKeys.onSelection = { [weak self] in self?.translateSelection() }
        hotKeys.register()
        settings.objectWillChange.sink { [weak self] _ in self?.queueSnapshot() }.store(in: &subscriptions)
        loginItem.objectWillChange.sink { [weak self] _ in self?.queueSnapshot() }.store(in: &subscriptions)
        L10n.shared.$selection.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, !self.stopped else { return }
                self.makeMenu()
                self.sendSnapshot()
                self.publishResult()
                self.setupWindow?.title = L10n.text("准备语言包")
            }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.sendSnapshot() }.store(in: &subscriptions)
        installMonitors()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { return }
                let current = "\(AXIsProcessTrusted())-\(CGPreflightScreenCaptureAccess())"
                if current != self.lastPermissionState {
                    self.lastPermissionState = current
                    self.sendSnapshot()
                }
            }
        }
        inspectAppleLanguages()
        sendSnapshot()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        // Stop accepting callbacks before cancelling work that may complete.
        callback = nil
        translationTask?.cancel(); translationTask = nil
        selectionReadTask?.cancel(); selectionReadTask = nil
        appleInspectionTask?.cancel(); appleInspectionTask = nil
        permissionProbeTask?.cancel(); permissionProbeTask = nil
        settings.cancelPendingWork()
        subscriptions.removeAll()
        refreshTimer?.invalidate(); refreshTimer = nil
        selection.stop()
        hotKeys.unregister()
        capture.onCancel = nil
        capture.cancel()
        capture.clearOutline()
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        floating.hideButton()
        floating.hideResult()
        setupWindow?.close(); setupWindow = nil
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
        cleanup?()
        cleanup = nil
    }

    func receive(_ text: String) {
        do { handle(try NativeBridgeRequest.decode(text)) }
        catch {
            // An invalid envelope has no reliable correlation id. Do not emit
            // any portion of its body (which can contain a credential).
            emit(["type": "response", "id": "", "ok": false, "error": L10n.text("请求格式有误。")])
        }
    }

    private func receive(_ value: [String: Any], fromResult: Bool) {
        do {
            let request = try NativeBridgeRequest(value)
            guard NativeBridgeRequest.allows(request.action, fromResult: fromResult) else { throw AppError.message("此操作不可用。") }
            handle(request)
        } catch {
            let id = (value["id"] as? String).map { String($0.prefix(160)) } ?? ""
            emit(["type": "response", "id": id, "ok": false, "error": error.localizedDescription])
        }
    }

    private func handle(_ request: NativeBridgeRequest) {
        guard !stopped else { return }
        do {
            guard !isSmokeTest || request.action == "snapshot" else { throw AppError.message("此操作不可用。") }
            guard NativeBridgeRequest.allows(request.action, fromResult: false) else { throw AppError.message("此操作不可用。") }
            try perform(request)
            emit(["type": "response", "id": request.id, "ok": true, "data": bridgeState()])
        } catch {
            emit(["type": "response", "id": request.id, "ok": false, "error": error.localizedDescription])
        }
    }

    private func perform(_ request: NativeBridgeRequest) throws {
        switch request.action {
        case "snapshot": loginItem.refresh()
        case "update_settings":
            try request.validateConnectionPatch(currentProvider: settings.provider.rawValue)
            let target = try request.string("target", maximum: 40, required: false)
            let automatic = try request.boolean("automaticSelection", required: false)
            let preferences = try request.string("preferences", maximum: 8_000, required: false)
            let baseURL = try request.string("baseURL", maximum: 2_048, required: false)
            let model = try request.string("model", maximum: 240, required: false)
            let cliPath = try request.string("cliPath", maximum: 4_096, required: false)
            let parsedTarget = target.flatMap(TargetLanguage.init(rawValue:))
            if target != nil, parsedTarget == nil { throw AppError.message("目标语言无效。") }
            // Validate the complete patch before applying any preference.
            if let parsedTarget { settings.target = parsedTarget; inspectAppleLanguages() }
            if let automatic { settings.automaticSelection = automatic; selection.isEnabled = automatic; if !automatic { floating.hideButton() } }
            if let preferences { settings.preferences = preferences }
            if let baseURL { settings.apiBaseURL = baseURL }
            if let model { settings.apiModel = model }
            if let cliPath { settings.cliPath = cliPath }
        case "provider_select":
            guard let provider = TranslationProvider(rawValue: try request.string("provider", maximum: 40) ?? "") else {
                throw AppError.message("翻译服务无效。")
            }
            settings.selectProvider(provider)
        case "set_language":
            guard let language = AppLanguage(rawValue: try request.string("language", maximum: 40) ?? "") else {
                throw AppError.message("界面语言无效。")
            }
            L10n.shared.selection = language
        case "key_save":
            try requireCredentialContext(request)
            guard settings.provider.isAPI else { throw AppError.message("此服务无需 API Key。") }
            let key = try request.string("key", maximum: 4_096) ?? ""
            settings.keyDraft = key
            guard settings.saveKey() else { settings.keyDraft = ""; throw AppError.message(settings.credentialStatus) }
        case "key_remove":
            try requireCredentialContext(request)
            guard settings.provider.isAPI else { throw AppError.message("此服务无需 API Key。") }
            guard settings.removeKey() else { throw AppError.message(settings.credentialStatus) }
        case "connection_test":
            if let expected = try request.string("expectedProvider", maximum: 40, required: false), expected != settings.provider.rawValue {
                throw AppError.message("连接已切换，请重试。")
            }
            settings.testConnection()
        case "cli_scan": settings.scanCLIs()
        case "glossary_upsert": try upsertGlossary(request.payload)
        case "glossary_delete":
            guard let id = UUID(uuidString: try request.string("id", maximum: 40) ?? "") else { throw AppError.message("术语标识无效。") }
            settings.glossary.removeAll { $0.id == id }
        case "glossary_import": settings.importGlossary()
        case "glossary_export": settings.exportGlossary()
        case "permission":
            switch try request.string("kind", maximum: 40) {
            case "accessibility":
                SelectionMonitor.requestPermission()
                openSystemPreferences("Privacy_Accessibility")
            case "screenRecording":
                _ = CGRequestScreenCaptureAccess()
                openSystemPreferences("Privacy_ScreenCapture")
            default: throw AppError.message("权限类型无效。")
            }
        case "login_set":
            loginItem.setEnabled(try request.boolean("enabled") ?? false)
            if let problem = loginProblem() { throw AppError.message(problem) }
        case "login_settings": loginItem.openSystemSettings()
        case "apple_prepare": try showAppleSetup()
        case "translate":
            let text = (try request.string("text") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw AppError.message("没有可翻译的文字。") }
            let settingsWindow = NSApp.windows.first { $0.identifier?.rawValue == "main" || $0.title == "Transpose" }
            let frame = settingsWindow?.frame
            let anchor = frame.map { NSPoint(x: $0.maxX + 10, y: $0.maxY - 90) } ?? NSEvent.mouseLocation
            translate(SelectedContent(text: text, anchor: anchor, sourceApp: "试译"))
        case "capture": beginCapture()
        case "result_close": dismiss(force: true)
        case "result_pin":
            guard resultState != nil else { return }
            resultState?.isPinned = try request.boolean("pinned") ?? false
            publishResult()
        case "result_retry":
            guard let state = resultState, state.canRetry, !state.source.isEmpty else { throw AppError.message("没有可重试的翻译。") }
            let content = SelectedContent(text: state.source, anchor: selected?.anchor ?? NSEvent.mouseLocation, sourceApp: state.sourceApp)
            translate(content, preservingCapture: capture.hasOutline, preservingResult: true)
        case "result_copy":
            guard let output = resultState?.output, !output.isEmpty else { throw AppError.message("暂无可复制的译文。") }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(output, forType: .string)
        case "open_settings": openSettings()
        case "open_external":
            guard let text = try request.string("url", maximum: 2_048), let url = URL(string: text),
                  url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil else {
                throw AppError.message("链接无效。")
            }
            NSWorkspace.shared.open(url)
        case "app_quit":
            // Let the response reach the webview before Tauri exits.
            DispatchQueue.main.async { [weak self] in self?.emit(["type": "quit"]) }
        case "app_restart":
            DispatchQueue.main.async { [weak self] in self?.emit(["type": "restart"]) }
        default: throw AppError.message("此操作不可用。")
        }
        queueSnapshot()
    }

    private func upsertGlossary(_ payload: [String: Any]) throws {
        guard let object = payload["entry"] as? [String: Any] else { throw AppError.message("词条格式有误。") }
        let request = try NativeBridgeRequest(["id": "entry", "action": "entry", "payload": object])
        let rawID = try request.string("id", maximum: 40, required: false)
        let source = try request.string("source", maximum: 160) ?? ""
        let translation = try request.string("translation", maximum: 360) ?? ""
        let note = try request.string("note", maximum: 600, required: false) ?? ""
        let enabled = try request.boolean("enabled", required: false) ?? true
        if let rawID {
            guard let id = UUID(uuidString: rawID) else { throw AppError.message("术语标识无效。") }
            let entry = GlossaryEntry(id: id, source: source, translation: translation, note: note, enabled: enabled)
            settings.glossary = try GlossaryStore.saving(entry, in: settings.glossary)
        } else {
            let entry = GlossaryEntry(source: source, translation: translation, note: note, enabled: enabled)
            settings.glossary = try GlossaryStore.importEntries(existing: settings.glossary, incoming: [entry])
        }
    }

    private func requireCredentialContext(_ request: NativeBridgeRequest) throws {
        try request.validateCredentialContext(currentProvider: settings.provider.rawValue, currentBaseURL: settings.apiBaseURL)
    }

    private func bridgeState() -> [String: Any] {
        ["app": appSnapshot(), "result": resultState.map { $0.dictionary as Any } ?? NSNull()]
    }

    private func appSnapshot() -> [String: Any] {
        let glossary = settings.glossary.map { entry -> [String: Any] in
            ["id": entry.id.uuidString, "source": entry.source, "translation": entry.translation, "note": entry.note, "enabled": entry.enabled]
        }
        let providers = TranslationProvider.allCases.map { provider -> [String: Any] in
            ["id": provider.rawValue, "title": provider.title, "isAPI": provider.isAPI, "isCLI": provider.isCLI,
             "defaultBaseURL": provider.defaultBaseURL, "defaultModel": provider.defaultModel]
        }
        let loginStatus: String
        switch loginItem.status {
        case .enabled: loginStatus = "enabled"
        case .notRegistered: loginStatus = "notRegistered"
        case .requiresApproval: loginStatus = "requiresApproval"
        case .notFound: loginStatus = "notFound"
        }
        var login: [String: Any] = ["status": loginStatus]
        if let problem = loginProblem() { login["problem"] = L10n.text(problem) }
        let publicSettings = NativeBridgePublicSettings(provider: settings.provider.rawValue, target: settings.target.rawValue,
                                                        automaticSelection: settings.automaticSelection, preferences: settings.preferences,
                                                        baseURL: settings.apiBaseURL, model: settings.apiModel, cliPath: settings.cliPath,
                                                        keyIsSaved: settings.keyIsSaved)
        return ["version": AppInfo.version, "language": L10n.shared.selection.rawValue, "locale": L10n.isEnglish ? "en" : "zh-Hans",
                "settings": publicSettings.dictionary,
                "providers": providers, "glossary": glossary,
                "detectedCLIs": settings.detectedCLIs.map { ["provider": $0.provider.rawValue, "path": $0.path] },
                "permissions": ["accessibility": AXIsProcessTrusted(),
                                "screenRecording": CGPreflightScreenCaptureAccess() && !capture.screenRecordingNeedsRestart,
                                "screenRecordingNeedsRestart": capture.screenRecordingNeedsRestart],
                "loginItem": login, "apple": ["supported": AppleTranslationBackend.isSupported, "status": L10n.text(appleStatus)],
                "status": ["credential": L10n.text(settings.credentialStatus), "connection": L10n.text(settings.connectionStatus),
                           "testingConnection": settings.testingConnection, "glossary": L10n.text(settings.glossaryStatus)]]
    }

    private func loginProblem() -> String? {
        switch loginItem.problem {
        case .system(let text): return text
        case .didNotEnable: return "开机启动尚未开启，请在系统设置中确认。"
        case .didNotDisable: return "开机启动尚未关闭，请在系统设置中确认。"
        case nil: return nil
        }
    }

    func sendSnapshot() {
        guard !stopped else { return }
        loginItem.refresh()
        emit(["type": "snapshot", "data": appSnapshot()])
    }

    private func queueSnapshot() {
        guard !queuedSnapshot, !stopped else { return }
        queuedSnapshot = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.queuedSnapshot = false
            self.sendSnapshot()
        }
    }

    private func emit(_ event: [String: Any]) {
        guard !stopped, let callback,
              JSONSerialization.isValidJSONObject(event),
              let data = try? JSONSerialization.data(withJSONObject: event),
              let json = String(data: data, encoding: .utf8) else { return }
        json.withCString { callback($0) }
        floating.sendEvent(event)
    }

    private func publishResult() {
        guard let resultState else { emit(["type": "result", "data": NSNull()]); return }
        emit(["type": "result", "data": resultState.dictionary])
    }

    private func present(_ content: SelectedContent) {
        dismiss()
        selected = content
        floating.showButton(at: content.anchor) { [weak self] in self?.translate(content) }
    }

    private func presentDeferredSelection(_ candidate: DeferredSelection) {
        dismiss()
        floating.showButton(at: candidate.anchor) { [weak self] in
            guard let self, self.settings.automaticSelection, !self.capture.isActive else { return }
            self.dismiss()
            let request = self.generation
            var state = NativeResultState()
            state.id = request
            state.sourceApp = candidate.sourceApp
            state.isLoading = true
            state.loadingMessage = "正在读取选中文字…"
            state.isPinned = self.resultState?.isPinned ?? false
            state.provider = self.settings.provider.title
            state.status = self.settings.provider.title
            self.resultState = state
            self.floating.showResult(state: state.dictionary, near: candidate.anchor)
            self.publishResult()
            self.selectionReadTask = Task { [weak self] in
                guard let self else { return }
                let content = await self.selection.resolve(candidate)
                guard !Task.isCancelled, self.generation == request, !self.capture.isActive else { return }
                if let content { self.translate(content, preservingResult: true) }
                else { self.showError("没有读到选中文字。可以按 ⌥S 圈选屏幕中的内容。") }
            }
        }
    }

    private func translateSelection() {
        guard !capture.isActive else { return }
        guard AXIsProcessTrusted() else { showError("划词翻译需要辅助功能权限。请在设置中允许 Transpose。"); return }
        dismiss()
        let request = generation
        selectionReadTask = Task { [weak self] in
            guard let self else { return }
            let content = await self.selection.readSelection(allowClipboardFallback: true)
            guard !Task.isCancelled, self.generation == request, !self.capture.isActive else { return }
            if let content { self.translate(content) }
            else { self.showError("没有读到选中文字。可以按 ⌥S 圈选屏幕中的内容。") }
        }
    }

    private func beginCapture() {
        dismiss(force: true)
        if capture.screenRecordingNeedsRestart {
            openSettings()
            showError(CapturePermission.restartMessage)
            queueSnapshot()
            return
        }
        // Hide only Tauri's settings window; never its WK result or system UI.
        emit(["type": "hide_settings"])
        guard CGPreflightScreenCaptureAccess() else {
            openSettings()
            showError("圈选翻译需要屏幕录制权限。请在设置中允许 Transpose，然后重新圈选。")
            return
        }
        capture.begin()
    }

    private func showCaptureRecognizing(at point: NSPoint) {
        selectionReadTask?.cancel(); selectionReadTask = nil
        translationTask?.cancel(); translationTask = nil
        generation = UUID()
        selected = nil
        var state = NativeResultState()
        state.sourceApp = "屏幕圈选"
        state.sourceLanguage = "识别中"
        state.isLoading = true
        state.loadingMessage = "正在识别文字…"
        state.provider = settings.provider.title
        state.status = "本机文字识别"
        resultState = state
        floating.showResult(state: state.dictionary, near: point, avoiding: capture.selectionFrame)
        publishResult()
    }

    private func translate(_ content: SelectedContent, preservingCapture: Bool = false, preservingResult: Bool = false) {
        let text = content.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard text.count <= 16_000 else { showError("这段内容较长，请选取 16,000 字符以内的部分。", preservingCapture: preservingCapture); return }
        if !preservingCapture { if capture.isActive { capture.cancel() }; capture.clearOutline() }
        selectionReadTask?.cancel(); selectionReadTask = nil
        translationTask?.cancel()
        let id = UUID()
        generation = id
        selected = content
        let options = settings.options(for: text)
        var state = NativeResultState()
        state.id = id
        state.source = text
        state.sourceApp = content.sourceApp
        state.sourceLanguage = (try? AppleTranslationLanguages.sourceCode(text)) ?? "自动检测"
        state.targetLanguage = (try? AppleTranslationLanguages.targetCode(options.targetLanguage)) ?? options.targetLanguage
        state.isLoading = true
        state.canRetry = true
        state.isPinned = resultState?.isPinned ?? false
        state.provider = settings.provider.title
        state.status = "\(settings.provider.title) · 正在翻译"
        resultState = state
        floating.showResult(state: state.dictionary, near: content.anchor, avoiding: preservingCapture ? capture.selectionFrame : nil,
                            preservingPosition: preservingCapture || preservingResult)
        publishResult()
        translationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stats = try await self.translator.translate(text, options: options) { [weak self] output in
                    guard let self, self.generation == id else { return }
                    self.resultState?.output = output
                    self.publishResult()
                }
                guard self.generation == id, !Task.isCancelled else { return }
                self.resultState?.isLoading = false
                self.resultState?.status = stats.cached ? "\(stats.provider) · 已缓存" : "\(stats.provider) · \(String(format: "%.1f", stats.elapsed)) 秒"
                self.publishResult()
            } catch is CancellationError {
                guard self.generation == id else { return }
                self.resultState?.isLoading = false
                self.publishResult()
            } catch {
                guard self.generation == id, !Task.isCancelled else { return }
                self.resultState?.isLoading = false
                self.resultState?.error = error.localizedDescription
                self.resultState?.status = "翻译未完成"
                self.publishResult()
            }
        }
    }

    private func dismiss(force: Bool = false) {
        floating.hideButton()
        selectionReadTask?.cancel(); selectionReadTask = nil
        if resultState?.isPinned == true, !force { return }
        if capture.isActive { capture.cancel() }
        capture.clearOutline()
        translationTask?.cancel(); translationTask = nil
        generation = UUID()
        resultState = nil
        selected = nil
        floating.hideResult()
        emit(["type": "result", "data": NSNull()])
    }

    private func showError(_ message: String, preservingCapture: Bool = false) {
        if !preservingCapture { if capture.isActive { capture.cancel() }; capture.clearOutline() }
        selectionReadTask?.cancel(); selectionReadTask = nil
        translationTask?.cancel(); translationTask = nil
        generation = UUID()
        selected = nil
        var state = NativeResultState()
        state.error = message
        state.status = "Transpose"
        state.provider = settings.provider.title
        resultState = state
        floating.showResult(state: state.dictionary, near: NSEvent.mouseLocation, avoiding: preservingCapture ? capture.selectionFrame : nil,
                            preservingPosition: preservingCapture)
        publishResult()
    }

    private func openSettings() { dismiss(); emit(["type": "open_settings"]) }

    private func makeMenu() {
        if item == nil { item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength) }
        item?.button?.image = TransposeBrand.menuBarImage()
        let menu = NSMenu()
        let title = NSMenuItem(title: "Transpose", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L10n.text("翻译选中文字"), action: #selector(selectionMenu), keyEquivalent: ""))
        let screen = NSMenuItem(title: L10n.text("圈选翻译"), action: #selector(captureMenu), keyEquivalent: "s")
        screen.keyEquivalentModifierMask = [.option]
        menu.addItem(screen)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L10n.text("设置…"), action: #selector(settingsMenu), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: L10n.text("退出"), action: #selector(quitMenu), keyEquivalent: "q"))
        for menuItem in menu.items { menuItem.target = self }
        item?.menu = menu
    }

    @objc private func selectionMenu() { translateSelection() }
    @objc private func captureMenu() { beginCapture() }
    @objc private func settingsMenu() { openSettings() }
    @objc private func quitMenu() { emit(["type": "quit"]) }

    private func installMonitors() {
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53, let self else { return event }
            if self.capture.isActive { self.capture.cancel(); return nil }
            if self.floating.result?.isVisible == true || self.floating.button?.isVisible == true { self.dismiss(force: true); return nil }
            return event
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return }
            MainActor.assumeIsolated {
                guard let self, !self.capture.isActive else { return }
                if self.floating.result?.isVisible == true || self.floating.button?.isVisible == true { self.dismiss(force: true) }
            }
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.capture.isActive else { return }
                if !self.floating.isMouseInside, !self.capture.containsOutline(NSEvent.mouseLocation) { self.dismiss() }
            }
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            guard let self, !self.capture.isActive, event.window !== self.floating.result, event.window !== self.floating.button else { return event }
            if !self.capture.containsOutline(NSEvent.mouseLocation) { self.dismiss() }
            return event
        }) { monitors.append(monitor) }
    }

    private func openSystemPreferences(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") { NSWorkspace.shared.open(url) }
    }

    private func showAppleSetup() throws {
        guard AppleTranslationBackend.isSupported else { throw AppError.message("Apple 翻译需要 macOS 15 或更新版本。") }
        if let setupWindow, setupTarget == settings.target {
            setupWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        setupWindow?.close()
        setupWindow = nil
        let host = NSHostingView(rootView: AppleTranslationSetupView(targetLanguage: settings.target).padding(24).frame(width: 470))
        host.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 175),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L10n.text("准备语言包")
        window.contentView = host
        window.isReleasedWhenClosed = false
        window.center()
        // Rebuild on next explicit open so a changed translation target is used.
        NotificationCenter.default.publisher(for: NSWindow.willCloseNotification, object: window).first()
            .sink { [weak self] _ in self?.setupWindow = nil; self?.inspectAppleLanguages() }.store(in: &subscriptions)
        setupWindow = window
        setupTarget = settings.target
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func inspectAppleLanguages() {
        appleInspectionTask?.cancel()
        let id = UUID()
        appleInspectionID = id
        guard #available(macOS 15.0, *) else { appleStatus = "Apple 翻译需要 macOS 15 或更新版本。"; queueSnapshot(); return }
        let target = settings.target
        appleInspectionTask = Task { [weak self] in
            let availability = AppleTranslationLanguages.availability()
            var installed = true
            var unsupported = false
            for pair in AppleTranslationLanguages.setupPairs(targetLanguage: target) {
                let status = await availability.status(from: Locale.Language(identifier: pair.0), to: Locale.Language(identifier: pair.1))
                guard let self, !Task.isCancelled, self.appleInspectionID == id else { return }
                if status != .installed { installed = false }
                if status == .unsupported { unsupported = true }
            }
            guard let self, !Task.isCancelled, self.appleInspectionID == id else { return }
            self.appleStatus = unsupported ? "所选语言暂不受 Apple 翻译支持。" : (installed ? "语言包已安装，可直接翻译。" : "语言包尚未安装完成，点击由 macOS 确认或继续准备。")
            self.queueSnapshot()
        }
    }

    private func probeCapturePermission() {
        let preflight = CGPreflightScreenCaptureAccess()
        guard preflight else {
            emit(["type": "permission_probe", "data": ["preflight": false, "effective": false,
                                                        "accessibility": AXIsProcessTrusted()]])
            return
        }
        permissionProbeTask = Task { [weak self] in
            do {
                // Check authorization through the capture service itself. Do
                // not capture pixels or retain/log any returned window data.
                _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let self, !Task.isCancelled, !self.stopped else { return }
                self.emit(["type": "permission_probe", "data": ["preflight": true, "effective": true,
                                                                  "accessibility": AXIsProcessTrusted()]])
            } catch {
                guard let self, !Task.isCancelled, !self.stopped else { return }
                self.emit(["type": "permission_probe", "data": ["preflight": true, "effective": false,
                                                               "accessibility": AXIsProcessTrusted(),
                                                               "errorCode": (error as NSError).code]])
            }
        }
    }
}
