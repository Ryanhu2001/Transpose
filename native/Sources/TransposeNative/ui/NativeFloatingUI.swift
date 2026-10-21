import AppKit
import SwiftUI
import WebKit

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Becomes key only after a deliberate click. Showing a translation leaves the
/// source application active, with its selected text and keyboard focus intact.
final class NativeResultPanel: NSPanel {
    var onEscape: (() -> Void)?
    var focusesOnClick = false
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func sendEvent(_ event: NSEvent) {
        // WK's internal content view can otherwise consume the activating
        // click. Focus only for an actual click, then deliver that same event.
        if focusesOnClick, event.type == .leftMouseDown, !isKeyWindow { makeKey() }
        super.sendEvent(event)
    }
}

private struct NativeTranslateButton: View {
    @ObservedObject private var language = L10n.shared
    var action: () -> Void
    var onHoverChanged: (Bool) -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(L10n.text("译"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(hovered ? Color.white : Color.accentColor)
                .frame(width: 30, height: 28)
                .background(hovered ? Color.accentColor : Color(nsColor: .windowBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(5)
        .onHover { hovered = $0; onHoverChanged($0) }
        .animation(.easeOut(duration: 0.1), value: hovered)
        .accessibilityLabel(L10n.text("翻译选中文字"))
        .help(L10n.text("翻译"))
    }
}

private final class FirstMouseWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// This small native strip sits over the non-interactive portion of the web
/// header. It never covers the pin/close buttons or the selectable translation.
private final class ResultDragStrip: NSView {
    var onBegin: (() -> Void)?
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard event.type == .leftMouseDown, let window else { return }
        onBegin?()
        window.performDrag(with: event)
    }
}

private final class ResultPanelContentView: NSView {
    let webView: WKWebView
    let grip = ResizeHandleView()
    let dragStrip = ResultDragStrip()
    // A real, attached SwiftUI host is required by TranslationSession on
    // macOS 15–25. Keep it attached behind WebKit, including when hidden.
    private let translationHost = NSHostingView(rootView: AppleTranslationHostView())

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.borderWidth = 0.7
        addSubview(translationHost)
        addSubview(webView)
        addSubview(dragStrip)
        addSubview(grip)
        updateBorder()
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        translationHost.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        webView.frame = bounds
        // Frontend's header is 44 CSS pixels. Its trailing 100 pixels contain
        // controls, and the outer 6 pixels remain available for edge resizing.
        dragStrip.frame = NSRect(x: 6, y: max(0, bounds.height - 44),
                                width: max(0, bounds.width - 112), height: 38)
        grip.frame = NSRect(x: max(0, bounds.width - 22), y: 1, width: 21, height: 22)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorder()
    }

    private func updateBorder() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
}

/// WKUserContentController retains its handlers, so the proxy must not own the
/// panel controller. Navigation delegates themselves are weak.
private final class ResultMessageProxy: NSObject, WKScriptMessageHandler {
    weak var owner: NativeFloatingUI?
    init(owner: NativeFloatingUI) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.receive(message)
    }
}

@MainActor
final class NativeFloatingUI: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    var onRequest: ([String: Any]) -> Void
    private(set) var button: NSPanel?
    private(set) var result: NSPanel?
    private var resultWebView: WKWebView?
    private var resultState: [String: Any] = [:]
    private var frontendURL: URL?
    private var webReady = false
    private var queuedEvents: [[String: Any]] = []
    private var buttonTimer: Timer?
    private var fitTimer: Timer?
    private var comparisonRegion: CGRect?
    private var userAdjustedFrame = false
    private var adjustingFrame = false
    private var preferredResultSize: NSSize?
    private var isPinned: Bool { resultState["isPinned"] as? Bool ?? false }
    private static let allowedActions: Set<String> = [
        "snapshot", "result_close", "result_pin", "result_retry", "result_copy", "open_settings"
    ]

    init(onRequest: @escaping ([String: Any]) -> Void) {
        self.onRequest = onRequest
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    var isMouseInside: Bool {
        let location = NSEvent.mouseLocation
        return [button, result].compactMap { $0 }.contains { $0.isVisible && $0.frame.contains(location) }
    }

    func showButton(at point: NSPoint, action: @escaping () -> Void) {
        hideButton()
        let panel = makePanel(size: NSSize(width: 40, height: 38))
        panel.title = L10n.text("翻译选区")
        panel.contentView = FirstMouseHostingView(rootView: NativeTranslateButton(action: action,
            onHoverChanged: { [weak self] inside in
                self?.buttonTimer?.invalidate()
                if !inside { self?.scheduleButtonDismissal(after: 2) }
            }))
        panel.level = .popUpMenu
        panel.setFrameOrigin(clampedOrigin(near: point, size: panel.frame.size))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            panel.animator().alphaValue = 1
        }
        button = panel
        scheduleButtonDismissal(after: 7)
    }

    func hideButton() {
        buttonTimer?.invalidate()
        buttonTimer = nil
        button?.orderOut(nil)
        button = nil
    }

    func showResult(state: [String: Any], near point: NSPoint, avoiding region: CGRect? = nil,
                    preservingPosition: Bool = false) {
        hideButton()
        fitTimer?.invalidate()
        fitTimer = nil
        comparisonRegion = region
        resultState = state
        let reference = region.map { NSPoint(x: $0.midX, y: $0.midY) } ?? point
        let visible = visibleFrame(near: reference)
        let preferred = preferredResultSize ?? NSSize(width: 410, height: 180)
        let size = NSSize(width: min(preferred.width, max(1, visible.width - 20)),
                          height: min(preferred.height, max(1, visible.height - 20)))
        let panel: NSPanel
        if let existing = result { panel = existing }
        else {
            let created = makePanel(size: size)
            created.focusesOnClick = true
            created.styleMask.insert(.resizable)
            created.minSize = NSSize(width: 360, height: 180)
            created.maxSize = NSSize(width: CGFloat(Float.greatestFiniteMagnitude),
                                     height: CGFloat(Float.greatestFiniteMagnitude))
            created.delegate = self
            created.onEscape = { [weak self] in self?.request("result_close") }
            installWebContent(in: created)
            result = created
            panel = created
        }
        let wasVisible = panel.isVisible
        panel.title = "Transpose · " + L10n.text("译文")
        if !wasVisible || (!isPinned && !preservingPosition) {
            userAdjustedFrame = preferredResultSize != nil
            setFrame(ResultPlacement.frame(size: size, near: point, avoiding: region, visibleFrame: visible), of: panel)
        }
        if !wasVisible { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        if !wasVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.1
                panel.animator().alphaValue = 1
            }
        }
        // Also paints callers that do not fan out bridge events to the panel.
        sendEvent(["type": "result", "data": state])
        scheduleResultFit()
    }

    func updateResult(state: [String: Any]) {
        resultState = state
        sendEvent(["type": "result", "data": state])
        scheduleResultFit()
    }

    func hideResult() {
        fitTimer?.invalidate()
        fitTimer = nil
        result?.orderOut(nil)
        comparisonRegion = nil
    }

    /// Response dictionaries retain their request id. `snapshot` requests are
    /// answered by the main bridge with complete {app,result} state, never by
    /// synthesizing another request here.
    func sendEvent(_ event: [String: Any]) {
        absorbState(from: event)
        if event["type"] as? String == "result" { scheduleResultFit() }
        guard let webView = resultWebView else { return }
        guard webReady else {
            if let type = event["type"] as? String, type != "response" {
                queuedEvents.removeAll { $0["type"] as? String == type }
            }
            queuedEvents.append(event)
            if queuedEvents.count > 128 { queuedEvents.removeFirst(queuedEvents.count - 128) }
            return
        }
        dispatch(event, to: webView)
    }

    private func absorbState(from event: [String: Any]) {
        if event["type"] as? String == "result", let state = event["data"] as? [String: Any] {
            resultState = state
        } else if let state = (event["data"] as? [String: Any])?["result"] as? [String: Any] {
            resultState = state
        }
    }

    fileprivate func receive(_ message: WKScriptMessage) {
        guard message.name == "transpose", message.frameInfo.isMainFrame,
              isBundledDocument(message.frameInfo.request.url),
              isBundledDocument(message.webView?.url),
              let request = message.body as? [String: Any],
              let id = request["id"] as? String, !id.isEmpty, id.utf8.count <= 160 else { return }
        guard let action = request["action"] as? String, Self.allowedActions.contains(action),
              request["payload"] is [String: Any], JSONSerialization.isValidJSONObject(request),
              let encoded = try? JSONSerialization.data(withJSONObject: request), encoded.count <= 256_000 else {
            sendEvent(["type": "response", "id": id, "ok": false, "error": "Unsupported result action."])
            return
        }
        onRequest(request)
    }

    private func installWebContent(in panel: NSPanel) {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.allowsAirPlayForMediaPlayback = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(ResultMessageProxy(owner: self), name: "transpose")
        let webView = FirstMouseWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.underPageBackgroundColor = .windowBackgroundColor
        let content = ResultPanelContentView(webView: webView)
        content.dragStrip.onBegin = { [weak self] in self?.userAdjustedFrame = true }
        content.grip.onBegin = { [weak self] in self?.userAdjustedFrame = true }
        content.grip.onEnd = { [weak self] in self?.rememberResultSize() }
        content.grip.toolTip = L10n.text("拖动以调整窗口大小")
        content.grip.setAccessibilityLabel(L10n.text("调整窗口大小"))
        panel.contentView = content
        resultWebView = webView
        guard let resources = Bundle.main.resourceURL else { showFrontendFailure(in: panel); return }
        let root = resources.appendingPathComponent("frontend", isDirectory: true).standardizedFileURL
        let index = root.appendingPathComponent("index.html").standardizedFileURL
        guard FileManager.default.fileExists(atPath: index.path) else { showFrontendFailure(in: panel); return }
        frontendURL = index
        // The same document has a restrictive CSP. Content rules additionally
        // block every remote subresource before loading any bundled script.
        let rules = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}},{"trigger":{"url-filter":"^file:"},"action":{"type":"ignore-previous-rules"}},{"trigger":{"url-filter":"^data:image/","resource-type":["image"]},"action":{"type":"ignore-previous-rules"}}]"#
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "transpose-result-local-v1",
            encodedContentRuleList: rules) { [weak self, weak webView, weak panel] list, error in
                DispatchQueue.main.async {
                    guard let self, let webView, let panel else { return }
                    guard let list, error == nil else { self.showFrontendFailure(in: panel); return }
                    configuration.userContentController.add(list)
                    var components = URLComponents(url: index, resolvingAgainstBaseURL: false)
                    components?.fragment = "result"
                    webView.loadFileURL(components?.url ?? index, allowingReadAccessTo: root)
                }
            }
    }

    private func showFrontendFailure(in panel: NSPanel) {
        let label = NSTextField(wrappingLabelWithString: L10n.text("暂时无法翻译") + "\nFrontend assets are unavailable.")
        label.alignment = .center
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        let container = NSView(frame: NSRect(origin: .zero, size: panel.frame.size))
        label.frame = container.bounds.insetBy(dx: 20, dy: 30)
        label.autoresizingMask = [.width, .height]
        container.addSubview(label)
        panel.contentView = container
    }

    private func dispatch(_ event: [String: Any], to webView: WKWebView) {
        guard JSONSerialization.isValidJSONObject(event),
              let data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return }
        // JSONSerialization performs the quoting; model output is never HTML.
        webView.evaluateJavaScript("window.dispatchEvent(new CustomEvent('transpose:native',{detail:\(json)}));", completionHandler: nil)
    }

    private func isBundledDocument(_ url: URL?) -> Bool {
        guard let url, let frontendURL, url.isFileURL else { return false }
        return url.standardizedFileURL.path == frontendURL.path
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.targetFrame?.isMainFrame == true,
              isBundledDocument(navigationAction.request.url) else { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.isForMainFrame && isBundledDocument(navigationResponse.response.url)
                        ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard isBundledDocument(webView.url) else { return }
        webReady = true
        let events = queuedEvents
        queuedEvents.removeAll()
        for event in events { dispatch(event, to: webView) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { webReady = false }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { webReady = false }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webReady = false
        // Reload only the bundled document. Its frontend requests a snapshot
        // again after subscribing, recovering without losing the native frame.
        webView.reload()
    }

    private func request(_ action: String) {
        onRequest(["id": UUID().uuidString, "action": action, "payload": [String: Any]()])
    }

    private func scheduleButtonDismissal(after delay: TimeInterval) {
        buttonTimer?.invalidate()
        buttonTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.button, panel.isVisible else { return }
                if panel.frame.contains(NSEvent.mouseLocation) { self.scheduleButtonDismissal(after: 2) }
                else { self.hideButton() }
            }
        }
    }

    private func scheduleResultFit() {
        guard fitTimer == nil, result?.isVisible == true, !isPinned, !userAdjustedFrame else { return }
        fitTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.fitTimer = nil
                self?.fitResultHeight()
            }
        }
    }

    private func fitResultHeight() {
        guard let panel = result, panel.isVisible, !isPinned, !userAdjustedFrame else { return }
        let error = resultState["error"] as? String
        let text = error ?? (resultState["output"] as? String ?? "")
        guard !text.isEmpty else { return }
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 5
        let measured = (text as NSString).boundingRect(
            with: NSSize(width: max(1, panel.frame.width - 36), height: 10_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: error == nil ? 16 : 13), .paragraphStyle: style])
        let visible = panel.screen?.visibleFrame ?? visibleFrame(near: panel.frame.origin)
        let maximum = min(560, max(180, visible.height - 20))
        let chrome: CGFloat = error == nil ? 116 : 168
        let height = max(180, min(maximum, ceil(measured.height) + chrome))
        guard height > panel.frame.height + 1 else { return }
        var frame = panel.frame
        frame.origin.y += frame.height - height
        frame.size.height = height
        frame = clamped(frame, inside: visible)
        if let region = comparisonRegion, frame.intersects(region.insetBy(dx: -6, dy: -6)) {
            frame = ResultPlacement.frame(size: frame.size, near: NSPoint(x: region.maxX, y: region.minY),
                                          avoiding: region, visibleFrame: visible)
        }
        setFrame(frame, of: panel)
    }

    func windowWillMove(_ notification: Notification) {
        if !adjustingFrame { userAdjustedFrame = true }
    }
    func windowWillStartLiveResize(_ notification: Notification) { userAdjustedFrame = true }
    func windowDidEndLiveResize(_ notification: Notification) { rememberResultSize() }
    func windowDidResize(_ notification: Notification) {
        if !adjustingFrame, result?.inLiveResize == true { userAdjustedFrame = true }
    }
    func windowDidMove(_ notification: Notification) {
        guard !adjustingFrame, let panel = result else { return }
        // Display removal and Dock/menu-bar changes must not strand controls.
        let frame = clamped(panel.frame, inside: visibleFrame(near: NSPoint(x: panel.frame.midX, y: panel.frame.midY)))
        if frame != panel.frame { setFrame(frame, of: panel) }
    }

    private func rememberResultSize() {
        guard let result else { return }
        let visible = visibleFrame(near: NSPoint(x: result.frame.midX, y: result.frame.midY))
        let frame = clamped(result.frame, inside: visible)
        if frame != result.frame { setFrame(frame, of: result) }
        userAdjustedFrame = true
        preferredResultSize = result.frame.size
    }

    @objc private func screenParametersChanged() {
        for panel in [button, result].compactMap({ $0 }) {
            let visible = visibleFrame(near: NSPoint(x: panel.frame.midX, y: panel.frame.midY))
            let frame = clamped(panel.frame, inside: visible)
            if frame != panel.frame { setFrame(frame, of: panel) }
        }
    }

    private func visibleFrame(near point: NSPoint) -> CGRect {
        let screens = NSScreen.screens
        let containing = screens.first { $0.frame.contains(point) }
        let nearest = screens.min {
            hypot($0.frame.midX - point.x, $0.frame.midY - point.y) < hypot($1.frame.midX - point.x, $1.frame.midY - point.y)
        }
        return (containing ?? nearest ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private func clamped(_ frame: CGRect, inside visible: CGRect) -> CGRect {
        let available = visible.insetBy(dx: 10, dy: 10)
        let size = CGSize(width: min(frame.width, max(1, available.width)),
                          height: min(frame.height, max(1, available.height)))
        return CGRect(x: max(available.minX, min(frame.minX, available.maxX - size.width)),
                      y: max(available.minY, min(frame.minY, available.maxY - size.height)),
                      width: size.width, height: size.height)
    }

    private func setFrame(_ frame: CGRect, of panel: NSPanel) {
        adjustingFrame = true
        panel.setFrame(frame, display: true)
        adjustingFrame = false
    }

    private func makePanel(size: NSSize) -> NativeResultPanel {
        let panel = NativeResultPanel(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .none
        return panel
    }

    private func clampedOrigin(near point: NSPoint, size: NSSize) -> NSPoint {
        ResultPlacement.frame(size: size, near: point, avoiding: nil, visibleFrame: visibleFrame(near: point)).origin
    }
}
