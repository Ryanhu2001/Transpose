import AppKit
@preconcurrency import ApplicationServices

/// Reads the current application's selection without changing its clipboard.
/// Clipboard copying is reserved for an explicit shortcut request.
@MainActor
final class SelectionMonitor {
    var isEnabled = true {
        didSet {
            if !isEnabled {
                cancelPendingRead()
                onDismiss?()
            }
        }
    }
    var shouldIgnoreEvent: (() -> Bool)?

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    private var monitors: [Any] = []
    private var pendingRead: Task<Void, Never>?
    private var generation = 0
    private var dragged = false
    private var lastDelivered: SelectionIdentity?
    private var onSelection: ((SelectedContent) -> Void)?
    private var onDismiss: (() -> Void)?
    private let reader = AccessibilitySelectionReader()
    private let clipboardQueue = DispatchQueue(label: "translateanywhere.selection.clipboard", qos: .userInitiated)
    private var clipboardReadInProgress = false
    private static let copyEventTag: Int64 = 0x54414E5957484552

    func start(onSelection: @escaping (SelectedContent) -> Void,
               onDismiss: @escaping () -> Void) {
        stop()
        self.onSelection = onSelection
        self.onDismiss = onDismiss
        if let monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyUp]
        , handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) {
            monitors.append(monitor)
        }
    }

    func stop() {
        cancelPendingRead()
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        onSelection = nil
        onDismiss = nil
        lastDelivered = nil
        dragged = false
    }

    func readSelection(allowClipboardFallback: Bool = true) async -> SelectedContent? {
        guard !Task.isCancelled,
              Self.isTrusted,
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }

        let pid = app.processIdentifier
        let appName = app.localizedName ?? app.bundleIdentifier ?? "App"
        let anchor = NSEvent.mouseLocation
        let result = await reader.read(pid: pid, bundleIdentifier: app.bundleIdentifier)
        guard !Task.isCancelled,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return nil }

        if let text = result.text {
            return SelectedContent(text: text, anchor: anchor, sourceApp: appName)
        }
        guard allowClipboardFallback, result.canCopy,
              !clipboardReadInProgress else { return nil }

        clipboardReadInProgress = true
        defer { clipboardReadInProgress = false }
        guard let text = await copySelection(from: pid), !Task.isCancelled,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return nil }
        return SelectedContent(text: text, anchor: anchor, sourceApp: appName)
    }

    private func handle(_ event: NSEvent) {
        guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != Self.copyEventTag,
              isEnabled, !(shouldIgnoreEvent?() ?? false) else { return }
        switch event.type {
        case .leftMouseDown:
            dragged = false
            cancelPendingRead()
            lastDelivered = nil
            onDismiss?()
        case .leftMouseDragged:
            dragged = true
        case .leftMouseUp:
            // A plain click can leave an old selection intact in another pane.
            // Only a gesture that can actually select text asks AX for it again.
            if dragged || event.clickCount >= 2 || event.modifierFlags.contains(.shift) {
                scheduleRead(at: NSEvent.mouseLocation)
            }
            dragged = false
        case .keyUp:
            let navigation: Set<UInt16> = [123, 124, 125, 126, 115, 119, 116, 121]
            let selectedWithKeyboard = event.modifierFlags.contains(.shift)
                && navigation.contains(event.keyCode)
            let selectedAll = event.keyCode == 0 && event.modifierFlags.contains(.command)
            if selectedWithKeyboard || selectedAll {
                lastDelivered = nil
                onDismiss?()
                scheduleRead(at: NSEvent.mouseLocation)
            } else if !event.modifierFlags.contains(.command) {
                cancelPendingRead()
                lastDelivered = nil
                onDismiss?()
            }
        default:
            break
        }
    }

    private func cancelPendingRead() {
        generation &+= 1
        pendingRead?.cancel()
        pendingRead = nil
    }

    private func scheduleRead(at anchor: NSPoint) {
        cancelPendingRead()
        let request = generation
        pendingRead = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(120)) }
            catch { return }
            guard let self, !Task.isCancelled, request == self.generation, self.isEnabled,
                  !(self.shouldIgnoreEvent?() ?? false) else { return }
            let content = await self.readSelection(allowClipboardFallback: false)
            guard !Task.isCancelled, request == self.generation,
                  self.isEnabled, !(self.shouldIgnoreEvent?() ?? false) else { return }
            guard let content else {
                self.lastDelivered = nil
                return
            }
            let identity = SelectionIdentity(
                text: content.text,
                pid: NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0,
                // Re-selecting the same word somewhere else should still work.
                x: Int(anchor.x / 12), y: Int(anchor.y / 12)
            )
            guard self.lastDelivered != identity else { return }
            self.lastDelivered = identity
            // Keep the gesture's global AppKit position while AX settles; the
            // pointer may have moved away before this delayed read completes.
            self.onSelection?(SelectedContent(text: content.text, anchor: anchor, sourceApp: content.sourceApp))
        }
    }

    private func copySelection(from pid: pid_t) async -> String? {
        let pasteboard = NSPasteboard.general
        // Materializing promised clipboard formats (especially images) can do
        // IPC. Capture them off the event loop and abandon expensive snapshots.
        let captured: ClipboardSnapshot? = await withCheckedContinuation { continuation in
            clipboardQueue.async {
                continuation.resume(returning: ClipboardSnapshot(NSPasteboard.general))
            }
        }
        guard let snapshot = captured, !Task.isCancelled,
              pasteboard.changeCount == snapshot.changeCount,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let down = CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: false) else { return nil }

        let attempt = ClipboardCopyAttempt()
        let realCopyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                if event.cgEvent?.getIntegerValueField(.eventSourceUserData) != Self.copyEventTag,
                   event.modifierFlags.contains(.command), [7, 8].contains(event.keyCode) {
                    attempt.userRequestedCopy = true
                }
            }
        }
        defer { if let realCopyMonitor { NSEvent.removeMonitor(realCopyMonitor) } }

        for event in [down, up] {
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: Self.copyEventTag)
            event.post(tap: .cghidEventTap)
        }

        // A bounded completion wait is only used for this explicit copy; AX
        // monitoring never polls. Clean up after cancellation as well. Fast
        // apps finish immediately, and slow apps get up to 800 ms to respond.
        for _ in 0..<80 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                    continuation.resume()
                }
            }
            guard !attempt.userRequestedCopy else { return nil }
            let copiedCount = pasteboard.changeCount
            guard copiedCount != snapshot.changeCount else { continue }
            let value = AccessibilitySelectionReader.clean(pasteboard.string(forType: .string))
            // No await between reading and restoring, and never overwrite a
            // newer clipboard update that arrived while reading its data.
            snapshot.restore(to: pasteboard, onlyIfChangeCount: copiedCount)
            return Task.isCancelled ? nil : value
        }
        return nil
    }
}

@MainActor
private final class ClipboardCopyAttempt {
    var userRequestedCopy = false
}

private struct SelectionIdentity: Equatable {
    let text: String
    let pid: pid_t
    let x: Int
    let y: Int
}

private struct ClipboardSnapshot: Sendable {
    let changeCount: Int
    let items: [[NSPasteboard.PasteboardType: Data]]

    init?(_ pasteboard: NSPasteboard) {
        changeCount = pasteboard.changeCount
        let deadline = ProcessInfo.processInfo.systemUptime + 0.12
        var size = 0
        var saved: [[NSPasteboard.PasteboardType: Data]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var values: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                // A promised/unreadable type cannot safely be reconstructed.
                guard let data = item.data(forType: type) else { return nil }
                size += data.count
                guard size <= 4 * 1_024 * 1_024,
                      ProcessInfo.processInfo.systemUptime < deadline else { return nil }
                values[type] = data
            }
            saved.append(values)
        }
        guard pasteboard.changeCount == changeCount else { return nil }
        items = saved
    }

    func restore(to pasteboard: NSPasteboard, onlyIfChangeCount expected: Int) {
        let objects = items.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        guard pasteboard.changeCount == expected else { return }
        pasteboard.clearContents()
        if !objects.isEmpty { pasteboard.writeObjects(objects) }
    }
}

/// All AX IPC stays on one background queue. A stuck application therefore
/// never blocks mouse tracking, animations, or the main event loop.
private final class AccessibilitySelectionReader: @unchecked Sendable {
    struct Result: Sendable {
        let text: String?
        let canCopy: Bool
    }

    private let queue = DispatchQueue(label: "translateanywhere.selection.ax", qos: .userInitiated)
    private var enabledChromiumPIDs = Set<pid_t>()

    func read(pid: pid_t, bundleIdentifier: String?) async -> Result {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: readSynchronously(pid: pid, bundleIdentifier: bundleIdentifier))
            }
        }
    }

    private func readSynchronously(pid: pid_t, bundleIdentifier: String?) -> Result {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.10)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.55

        // Chromium exposes web selection once manual accessibility is enabled.
        // This changes only the target application's accessibility tree.
        if isChromium(bundleIdentifier), enabledChromiumPIDs.insert(pid).inserted {
            AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        guard let focused = element(attribute: kAXFocusedUIElementAttribute, of: application) else {
            return Result(text: nil, canCopy: false)
        }
        AXUIElementSetMessagingTimeout(focused, 0.10)
        var current: AXUIElement? = focused
        var visited: [AXUIElement] = []
        // The focused element and a few ancestors cover native controls,
        // Safari web areas, Chromium, and most Electron editors.
        for _ in 0..<4 {
            guard let candidate = current,
                  ProcessInfo.processInfo.systemUptime < deadline,
                  !visited.contains(where: { CFEqual($0, candidate) }) else { break }
            visited.append(candidate)
            AXUIElementSetMessagingTimeout(candidate, 0.10)
            if isProtected(candidate) { return Result(text: nil, canCopy: false) }
            current = element(attribute: kAXParentAttribute, of: candidate)
        }
        // Check the ancestor chain before reading text: a web password input
        // can expose a regular-looking focused child inside a protected parent.
        for candidate in visited {
            guard ProcessInfo.processInfo.systemUptime < deadline else { break }
            if let text = selectedText(in: candidate) { return Result(text: text, canCopy: true) }
        }
        if ProcessInfo.processInfo.systemUptime < deadline,
           let nested = element(attribute: kAXFocusedUIElementAttribute, of: focused),
           !isProtected(nested), let text = selectedText(in: nested) {
            return Result(text: text, canCopy: true)
        }
        return Result(text: nil, canCopy: true)
    }

    private func selectedText(in element: AXUIElement) -> String? {
        if let string = value(attribute: kAXSelectedTextAttribute, of: element) as? String,
           let clean = Self.clean(string) { return clean }
        // WebKit and Chromium can expose a selection as text markers instead.
        guard let range = value(attribute: "AXSelectedTextMarkerRange", of: element) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, "AXStringForTextMarkerRange" as CFString, range, &result
        ) == .success else { return nil }
        return Self.clean(result as? String)
    }

    private func isProtected(_ element: AXUIElement) -> Bool {
        let subrole = value(attribute: kAXSubroleAttribute, of: element) as? String
        if subrole == "AXSecureTextField" { return true }
        if let protected = value(attribute: "AXProtectedContent", of: element) as? Bool, protected { return true }
        if let inputType = value(attribute: "AXDOMInputType", of: element) as? String,
           inputType.lowercased() == "password" { return true }
        return false
    }

    private func value(attribute: String, of element: AXUIElement) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }

    private func element(attribute: String, of element: AXUIElement) -> AXUIElement? {
        guard let result = value(attribute: attribute, of: element),
              CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return (result as! AXUIElement)
    }

    private func isChromium(_ bundle: String?) -> Bool {
        guard let bundle else { return false }
        return ["com.google.Chrome", "org.chromium.Chromium", "com.microsoft.edgemac",
                "com.brave.Browser", "company.thebrowser.Browser", "com.vivaldi.Vivaldi",
                "com.todesktop.", "com.microsoft.VSCode", "com.cursor.Cursor"]
            .contains(where: { bundle.hasPrefix($0) })
    }

    static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 16_000,
              !text.unicodeScalars.allSatisfy({ CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return text
    }
}
