import AppKit
@preconcurrency import ApplicationServices

/// A gesture whose text must be obtained after the user clicks the translation button.
/// The source process and generation prevent translating an obsolete selection.
struct DeferredSelection {
    let pid: pid_t
    let sourceApp: String
    let anchor: NSPoint
    fileprivate let generation: Int
    fileprivate let bundleIdentifier: String?
    fileprivate let gesturePoint: NSPoint
    fileprivate let context: SelectionReadContext
}

fileprivate struct SelectionReadContext: @unchecked Sendable {
    let target: SelectionPolicy.TargetFacts
    let endpoints: [AXUIElement]
}

/// Automatic selection monitoring reads AX only. Copying is reserved for an
/// explicit shortcut or a click on the chat application's translation button.
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
    private var gestureStart: NSPoint?
    private var gesturePID: pid_t?
    private var lastDelivered: SelectionIdentity?
    private var onSelection: ((SelectedContent) -> Void)?
    private var onDeferredSelection: ((DeferredSelection) -> Void)?
    private var onDismiss: (() -> Void)?
    private let reader = AccessibilitySelectionReader()
    private let clipboardQueue = DispatchQueue(label: "transpose.selection.clipboard", qos: .userInitiated)
    private var clipboardReadInProgress = false
    private static let copyEventTag: Int64 = 0x54414E5957484552

    func start(onSelection: @escaping (SelectedContent) -> Void,
               onDeferredSelection: ((DeferredSelection) -> Void)? = nil,
               onDismiss: @escaping () -> Void) {
        stop()
        self.onSelection = onSelection
        self.onDeferredSelection = onDeferredSelection
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
        onDeferredSelection = nil
        onDismiss = nil
        lastDelivered = nil
        dragged = false
        gestureStart = nil
        gesturePID = nil
    }

    func readSelection(allowClipboardFallback: Bool = true) async -> SelectedContent? {
        guard !Task.isCancelled, Self.isTrusted, let app = sourceApplication() else { return nil }
        let pid = app.processIdentifier
        let request = generation
        let appName = app.localizedName ?? app.bundleIdentifier ?? "App"
        let anchor = NSEvent.mouseLocation
        let result = await reader.read(pid: pid, bundleIdentifier: app.bundleIdentifier,
                                       point: quartzPoint(anchor))
        guard isCurrent(pid: pid, request: request, requireEnabled: false) else { return nil }
        if let text = result.text { return SelectedContent(text: text, anchor: anchor, sourceApp: appName) }
        guard allowClipboardFallback, result.canCopy, !clipboardReadInProgress else { return nil }
        clipboardReadInProgress = true
        defer { clipboardReadInProgress = false }
        guard let text = await copySelection(from: pid, request: request, requireEnabled: false), isCurrent(pid: pid, request: request, requireEnabled: false) else { return nil }
        return SelectedContent(text: text, anchor: anchor, sourceApp: appName)
    }

    /// Called only by an explicit button action. Never activate the source app:
    /// if the user has moved to another app, the deferred selection has expired.
    func resolve(_ deferred: DeferredSelection) async -> SelectedContent? {
        guard Self.isTrusted, isCurrent(pid: deferred.pid, request: deferred.generation),
              !clipboardReadInProgress else {
            diagnose("resolve", reason: "expired_or_busy", bundle: deferred.bundleIdentifier)
            return nil
        }
        // The loading panel may already cover the source selection. Use the
        // original AX targets rather than hit-testing through our own window.
        let result = await reader.read(pid: deferred.pid, bundleIdentifier: deferred.bundleIdentifier,
                                       point: nil, context: deferred.context)
        guard isCurrent(pid: deferred.pid, request: deferred.generation), result.canCopy else {
            diagnose("resolve", reason: result.target.protected ? "protected" : result.target.incomplete ? "ax_budget" : "target_rejected",
                     bundle: deferred.bundleIdentifier)
            return nil
        }
        if let text = result.text {
            return SelectedContent(text: text, anchor: deferred.anchor, sourceApp: deferred.sourceApp)
        }
        guard SelectionPolicy.permitsDeferred(bundle: deferred.bundleIdentifier,
                                              gesture: .keyboardSelection, target: result.target) else { return nil }
        clipboardReadInProgress = true
        defer { clipboardReadInProgress = false }
        guard let text = await copySelection(from: deferred.pid, request: deferred.generation,
                                             chatContext: result.context),
              isCurrent(pid: deferred.pid, request: deferred.generation) else { return nil }
        return SelectedContent(text: text, anchor: deferred.anchor, sourceApp: deferred.sourceApp)
    }

    private func diagnose(_ phase: String, reason: String, bundle: String?) {
        guard ProcessInfo.processInfo.arguments.contains("--selection-diagnostic") else { return }
        let report = ["selectionPhase": phase, "reason": reason, "bundle": bundle ?? "unknown"]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: .sortedKeys),
           let json = String(data: data, encoding: .utf8) { fputs(json + "\n", stderr) }
    }

    private func sourceApplication() -> NSRunningApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        return app
    }

    private func isCurrent(pid: pid_t, request: Int, requireEnabled: Bool = true) -> Bool {
        SelectionPolicy.isCurrent(originPID: pid, generation: request,
                                  currentPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                                  currentGeneration: generation, enabled: !requireEnabled || isEnabled, cancelled: Task.isCancelled)
    }

    private func quartzPoint(_ point: NSPoint) -> CGPoint {
        CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - point.y)
    }

    private func handle(_ event: NSEvent) {
        guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != Self.copyEventTag,
              isEnabled, !(shouldIgnoreEvent?() ?? false) else { return }
        switch event.type {
        case .leftMouseDown:
            dragged = false
            gestureStart = NSEvent.mouseLocation
            gesturePID = sourceApplication()?.processIdentifier
            cancelPendingRead()
            lastDelivered = nil
            onDismiss?()
        case .leftMouseDragged:
            dragged = true
        case .leftMouseUp:
            let anchor = NSEvent.mouseLocation
            let gesture: SelectionPolicy.Gesture
            if dragged, let start = gestureStart {
                gesture = .drag(distance: hypot(anchor.x - start.x, anchor.y - start.y))
            } else if event.clickCount >= 2 {
                gesture = .multipleClick(event.clickCount)
            } else if event.modifierFlags.contains(.shift) {
                gesture = .extendedClick
            } else { gesture = .plainClick }
            if gesture.canSelectText,
               let pid = sourceApplication()?.processIdentifier, pid == gesturePID {
                scheduleRead(at: anchor, gesture: gesture, start: gestureStart)
            }
            dragged = false
            gestureStart = nil
            gesturePID = nil
        case .keyUp:
            let navigation: Set<UInt16> = [123, 124, 125, 126, 115, 119, 116, 121]
            let selectedWithKeyboard = event.modifierFlags.contains(.shift) && navigation.contains(event.keyCode)
            let selectedAll = event.keyCode == 0 && event.modifierFlags.contains(.command)
            if selectedWithKeyboard || selectedAll {
                lastDelivered = nil
                onDismiss?()
                scheduleRead(at: NSEvent.mouseLocation, gesture: .keyboardSelection, start: nil)
            } else if !event.modifierFlags.contains(.command) {
                cancelPendingRead()
                lastDelivered = nil
                onDismiss?()
            }
        default: break
        }
    }

    private func cancelPendingRead() {
        generation &+= 1
        pendingRead?.cancel()
        pendingRead = nil
    }

    private func scheduleRead(at anchor: NSPoint, gesture: SelectionPolicy.Gesture, start: NSPoint?) {
        cancelPendingRead()
        guard let app = sourceApplication() else { return }
        let request = generation
        let pid = app.processIdentifier
        let appName = app.localizedName ?? app.bundleIdentifier ?? "App"
        let bundle = app.bundleIdentifier
        let point = quartzPoint(anchor)
        let startPoint = start.map(quartzPoint)
        pendingRead = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(120)) }
            catch { return }
            guard let self, self.isCurrent(pid: pid, request: request),
                  !(self.shouldIgnoreEvent?() ?? false), Self.isTrusted else { return }
            let result = await self.reader.read(pid: pid, bundleIdentifier: bundle, point: point, startPoint: startPoint)
            guard self.isCurrent(pid: pid, request: request), !(self.shouldIgnoreEvent?() ?? false) else { return }
            if let text = result.text {
                let identity = SelectionIdentity(text: text, pid: pid, x: Int(anchor.x / 12), y: Int(anchor.y / 12))
                guard self.lastDelivered != identity else { return }
                self.lastDelivered = identity
                self.onSelection?(SelectedContent(text: text, anchor: anchor, sourceApp: appName))
            } else {
                self.lastDelivered = nil
                guard SelectionPolicy.permitsDeferred(bundle: bundle, gesture: gesture, target: result.target) else { return }
                self.onDeferredSelection?(DeferredSelection(pid: pid, sourceApp: appName, anchor: anchor,
                                                           generation: request, bundleIdentifier: bundle, gesturePoint: anchor, context: result.context))
            }
        }
    }

    private func copySelection(from pid: pid_t, request: Int, requireEnabled: Bool = true,
                               chatContext: SelectionReadContext? = nil) async -> String? {
        let cancellation = SelectionCancellation()
        return await withTaskCancellationHandler(operation: {
            await performCopySelection(from: pid, request: request, requireEnabled: requireEnabled, cancellation: cancellation, chatContext: chatContext)
        }, onCancel: { cancellation.cancel() })
    }

    private func performCopySelection(from pid: pid_t, request: Int, requireEnabled: Bool,
                                      cancellation: SelectionCancellation, chatContext: SelectionReadContext?) async -> String? {
        let bundle = sourceApplication()?.bundleIdentifier
        let pasteboard = NSPasteboard.general
        // Promised formats can involve IPC. Materialize off the event loop,
        // abandoning snapshots larger than 4 MiB or slower than 120 ms.
        let captured: ClipboardSnapshot? = await withCheckedContinuation { continuation in
            clipboardQueue.async { continuation.resume(returning: ClipboardSnapshot(NSPasteboard.general)) }
        }
        guard let snapshot = captured, isCurrent(pid: pid, request: request, requireEnabled: requireEnabled),
              pasteboard.changeCount == snapshot.changeCount else {
            diagnose("copy", reason: "snapshot_or_expired", bundle: bundle)
            return nil
        }

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

        // Prefer the source application's enabled, standard Copy menu action.
        // An explicitly disabled Copy must not be bypassed with a synthetic key.
        let menuResult = await reader.pressCopy(pid: pid) { [weak self, weak attempt] in
            guard !cancellation.isCancelled else { return false }
            // AX menu discovery may span a user gesture. Revalidate on the
            // main event loop immediately before asking the app to Copy.
            return DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    guard let self, let attempt else { return false }
                    return !cancellation.isCancelled && self.isCurrent(pid: pid, request: request, requireEnabled: requireEnabled)
                        && !attempt.userRequestedCopy && NSPasteboard.general.changeCount == snapshot.changeCount
                }
            }
        }
        switch menuResult {
        case .disabled:
            diagnose("copy", reason: "menu_unavailable_or_disabled", bundle: bundle)
            // WeChat exposes a disabled or incomplete standard Copy menu for
            // some message selections that do support an explicit Cmd-C.
            // This exception is confined to the user's translation-button
            // click and requires a fresh protected-control check below.
            guard let chatContext,
                  SelectionPolicy.permitsExplicitChatKeyboardCopy(bundle: bundle, target: chatContext.target),
                  await reader.allowsChatKeyboardCopy(pid: pid, context: chatContext),
                  !cancellation.isCancelled, isCurrent(pid: pid, request: request, requireEnabled: requireEnabled),
                  !attempt.userRequestedCopy, pasteboard.changeCount == snapshot.changeCount,
                  postCopyKey() else { return nil }
        case .invoked:
            // Copy has already been sent. Even a cancelled originating task
            // must observe its bounded clipboard cleanup below.
            break
        case .unavailable:
            if let chatContext, bundle == "com.tencent.xinWeChat" {
                guard await reader.allowsChatKeyboardCopy(pid: pid, context: chatContext) else { return nil }
            }
            guard !cancellation.isCancelled, isCurrent(pid: pid, request: request, requireEnabled: requireEnabled),
                  !attempt.userRequestedCopy, pasteboard.changeCount == snapshot.changeCount else { return nil }
            guard postCopyKey() else { return nil }
        }

        // A cancelled task still gets bounded cleanup for its own text copy.
        // Switching apps, a newer gesture or a real Cmd-C/X always wins.
        for _ in 0..<80 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { continuation.resume() }
            }
            let copiedCount = pasteboard.changeCount
            let sameApp = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
            let decision = SelectionPolicy.clipboardDecision(
                originalCount: snapshot.changeCount, observedCount: copiedCount,
                text: copiedCount == snapshot.changeCount ? nil : pasteboard.string(forType: .string),
                sameApplication: sameApp, sameGeneration: generation == request,
                userRequestedCopy: attempt.userRequestedCopy)
            switch decision {
            case .wait: continue
            case .abandon:
                diagnose("copy", reason: "clipboard_superseded_or_nontext", bundle: bundle)
                return nil
            case .acceptAndRestore(let text):
                // No suspension between the final count check and restoration.
                guard snapshot.restore(to: pasteboard, onlyIfChangeCount: copiedCount) else { return nil }
                return cancellation.isCancelled || Task.isCancelled ? nil : text
            }
        }
        diagnose("copy", reason: "copy_no_write", bundle: bundle)
        return nil
    }

    private func postCopyKey() -> Bool {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: false) else { return false }
        for event in [down, up] {
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: Self.copyEventTag)
            event.post(tap: .cghidEventTap)
        }
        return true
    }
}

@MainActor
private final class ClipboardCopyAttempt { var userRequestedCopy = false }

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
                guard let data = item.data(forType: type) else { return nil }
                size += data.count
                guard size <= 4 * 1_024 * 1_024, ProcessInfo.processInfo.systemUptime < deadline else { return nil }
                values[type] = data
            }
            saved.append(values)
        }
        guard pasteboard.changeCount == changeCount else { return nil }
        items = saved
    }
    func restore(to pasteboard: NSPasteboard, onlyIfChangeCount expected: Int) -> Bool {
        let objects = items.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        guard pasteboard.changeCount == expected else { return false }
        pasteboard.clearContents()
        if !objects.isEmpty { pasteboard.writeObjects(objects) }
        return true
    }
}

/// All AX IPC stays on one background queue. A stuck app cannot block mouse
/// tracking or animations. Every read has a time, depth and node budget.
private final class AccessibilitySelectionReader: @unchecked Sendable {
    struct Result: Sendable {
        let text: String?
        let canCopy: Bool
        let target: SelectionPolicy.TargetFacts
        var endpoints: [AXUIElement] = []
        var context: SelectionReadContext { SelectionReadContext(target: target, endpoints: endpoints) }
    }
    private let queue = DispatchQueue(label: "transpose.selection.ax", qos: .userInitiated)
    private var enabledChromiumPIDs = Set<pid_t>()
    private var activeDeadline = TimeInterval.greatestFiniteMagnitude

    func read(pid: pid_t, bundleIdentifier: String?, point: CGPoint?, startPoint: CGPoint? = nil,
              context: SelectionReadContext? = nil) async -> Result {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: readSynchronously(pid: pid, bundleIdentifier: bundleIdentifier,
                                                                 point: point, startPoint: startPoint, context: context))
            }
        }
    }

    func pressCopy(pid: pid_t, allowed: @escaping @Sendable () -> Bool) async -> SelectionPolicy.CopyMenuResult {
        await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: pressCopySynchronously(pid: pid, allowed: allowed)) }
        }
    }

    private func readSynchronously(pid: pid_t, bundleIdentifier: String?, point: CGPoint?, startPoint: CGPoint?,
                                   context: SelectionReadContext?) -> Result {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.08)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.55
        activeDeadline = deadline
        defer { activeDeadline = .greatestFiniteMagnitude }
        if SelectionPolicy.needsManualAccessibility(bundleIdentifier), !enabledChromiumPIDs.contains(pid), before(deadline) {
            if AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success {
                enabledChromiumPIDs.insert(pid)
            }
        }
        // Inspect the actual gesture targets before spending time walking
        // ancestor chains. Unsupported attributes are valid for WeChat; an
        // exhausted time budget must never masquerade as a safe target.
        let rawHit = context?.endpoints.first ?? point.flatMap { hitTest(point: $0) }
        let rawStartHit = context?.endpoints.dropFirst().first ?? startPoint.flatMap { hitTest(point: $0) }
        let hit = rawHit.flatMap { belongs($0, to: pid) ? $0 : nil }
        let startHit = rawStartHit.flatMap { belongs($0, to: pid) ? $0 : nil }
        var facts = context?.target ?? SelectionPolicy.TargetFacts()
        facts.belongsToSource = [rawHit, rawStartHit].compactMap { $0 }.allSatisfy { belongs($0, to: pid) }
        let directTargets = [hit, startHit].compactMap { $0 }
        facts.protected = directTargets.contains(where: isProtected)
        facts.windowChrome = directTargets.contains { isWindowChrome($0) || isNonTextControl($0) }
        facts.riskyEditable = hit.map(isRiskyEditable) ?? false
        facts.incomplete = !before(deadline)
        guard !facts.protected, !facts.windowChrome, facts.belongsToSource, !facts.incomplete else {
            return Result(text: nil, canCopy: false, target: facts)
        }
        let focused = element(attribute: kAXFocusedUIElementAttribute, of: application)
        if hit == nil && context == nil { facts.riskyEditable = focused.map(isRiskyEditable) ?? false }
        let hitChain = chain(from: hit, deadline: deadline)
        let startChain = chain(from: startHit, deadline: deadline)
        let focusedChain = chain(from: focused, deadline: deadline)
        facts.protected = (hitChain + startChain + focusedChain).contains(where: isProtected)
        facts.windowChrome = (hitChain + startChain).contains(where: isWindowChrome)
        facts.incomplete = !before(deadline)
        guard !facts.protected, !facts.windowChrome, !facts.incomplete else {
            return Result(text: nil, canCopy: false, target: facts)
        }

        // Hit testing reaches chat message controls when focus remains in the
        // composer. Read all candidates' selected attributes, never their value.
        let candidates = hitChain + startChain + focusedChain
        for candidate in candidates {
            guard before(deadline) else { break }
            if let text = selectedText(in: candidate) { return Result(text: text, canCopy: true, target: facts) }
        }
        if before(deadline), let nested = focused.flatMap({ element(attribute: kAXFocusedUIElementAttribute, of: $0) }),
           !isProtected(nested), let text = selectedText(in: nested) {
            return Result(text: text, canCopy: true, target: facts)
        }
        // Electron/WeChat can put selection on a descendant of the window while
        // reporting a generic focused element. Keep this wider walk chat-only.
        if SelectionPolicy.isChatApplication(bundleIdentifier), before(deadline),
           let window = element(attribute: kAXFocusedWindowAttribute, of: application),
           let text = SelectionPolicy.selectedText(seeds: [window], same: { CFEqual($0, $1) },
                                                  canContinue: { self.before(deadline) }, protected: isProtected,
                                                  read: selectedText, children: children) {
            return Result(text: text, canCopy: true, target: facts)
        }
        facts.incomplete = !before(deadline)
        return Result(text: nil, canCopy: !facts.protected && !facts.windowChrome && !facts.riskyEditable && !facts.incomplete,
                      target: facts, endpoints: directTargets)
    }

    func allowsChatKeyboardCopy(pid: pid_t, context: SelectionReadContext) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let deadline = ProcessInfo.processInfo.systemUptime + 0.25
                activeDeadline = deadline
                defer { activeDeadline = .greatestFiniteMagnitude }
                let application = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(application, 0.05)
                let focused = element(attribute: kAXFocusedUIElementAttribute, of: application)
                let candidates = context.endpoints + chain(from: focused, deadline: deadline)
                let protected = candidates.contains(where: isProtected)
                continuation.resume(returning: !protected && before(deadline))
            }
        }
    }

    private func pressCopySynchronously(pid: pid_t, allowed: () -> Bool) -> SelectionPolicy.CopyMenuResult {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.06)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.30
        activeDeadline = deadline
        defer { activeDeadline = .greatestFiniteMagnitude }
        guard let menu = element(attribute: kAXMenuBarAttribute, of: application) else {
            return SelectionPolicy.menuFallbackResult(searchCompleted: before(deadline))
        }
        // Search Edit first and finish that subtree before unrelated menus.
        // Copy is commonly the fourth item; no need to probe every item for
        // shortcut and enabled attributes before its title can even match.
        let topMenus = children(menu)
        var editMenus: [AXUIElement] = []
        var otherMenus: [AXUIElement] = []
        for item in topMenus {
            guard before(deadline) else { return .disabled }
            if SelectionPolicy.isEditMenu(title: value(attribute: kAXTitleAttribute, of: item) as? String) {
                editMenus.append(item)
            } else { otherMenus.append(item) }
        }
        var pending = (editMenus + otherMenus).reversed().map { ($0, 0) }
        var visited: [AXUIElement] = []
        var truncated = false
        while let (node, depth) = pending.popLast() {
            guard visited.count < 128, before(deadline) else { return .disabled }
            guard !visited.contains(where: { CFEqual($0, node) }) else { continue }
            visited.append(node)
            AXUIElementSetMessagingTimeout(node, 0.06)
            let identifier = value(attribute: kAXIdentifierAttribute, of: node) as? String
            var isCopy = identifier == "copy:"
            if !isCopy, let title = value(attribute: kAXTitleAttribute, of: node) as? String,
               ["Copy", "复制", "拷贝", "コピー"].contains(title.trimmingCharacters(in: .whitespacesAndNewlines)) {
                isCopy = SelectionPolicy.CopyMenuItem(identifier: identifier, title: title,
                    commandCharacter: value(attribute: kAXMenuItemCmdCharAttribute, of: node) as? String,
                    enabled: true).isStandardCopy
            }
            if isCopy {
                guard value(attribute: kAXEnabledAttribute, of: node) as? Bool == true,
                      allowed(), before(deadline) else { return .disabled }
                return AXUIElementPerformAction(node, kAXPressAction as CFString) == .success ? .invoked : .disabled
            }
            guard before(deadline) else { return .disabled }
            let descendants = children(node)
            guard depth < 5 else { truncated = truncated || !descendants.isEmpty; continue }
            let capacity = max(0, 256 - pending.count)
            truncated = truncated || descendants.count > capacity
            pending.append(contentsOf: descendants.prefix(capacity).reversed().map { ($0, depth + 1) })
        }
        return SelectionPolicy.menuFallbackResult(searchCompleted: !truncated && before(deadline))
    }

    private func before(_ deadline: TimeInterval) -> Bool { ProcessInfo.processInfo.systemUptime < deadline }

    private func chain(from element: AXUIElement?, deadline: TimeInterval) -> [AXUIElement] {
        var current = element
        var visited: [AXUIElement] = []
        for _ in 0..<6 {
            guard let candidate = current, before(deadline), !visited.contains(where: { CFEqual($0, candidate) }) else { break }
            AXUIElementSetMessagingTimeout(candidate, 0.06)
            visited.append(candidate)
            current = self.element(attribute: kAXParentAttribute, of: candidate)
        }
        return visited
    }

    private func hitTest(point: CGPoint) -> AXUIElement? {
        guard before(activeDeadline) else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.06)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
              let hit else { return nil }
        return hit
    }

    private func belongs(_ element: AXUIElement, to pid: pid_t) -> Bool {
        var source: pid_t = 0
        return AXUIElementGetPid(element, &source) == .success && source == pid
    }

    private func children(_ element: AXUIElement) -> [AXUIElement] {
        guard before(activeDeadline) else { return [] }
        var values: CFArray?
        guard AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, 48, &values) == .success,
              let values else { return [] }
        return (values as [AnyObject]).compactMap { value in
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
    }

    private func selectedText(in element: AXUIElement) -> String? {
        if let string = value(attribute: kAXSelectedTextAttribute, of: element) as? String,
           let clean = SelectionPolicy.clean(string) { return clean }
        guard let range = value(attribute: "AXSelectedTextMarkerRange", of: element), before(activeDeadline) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, "AXStringForTextMarkerRange" as CFString,
                                                        range, &result) == .success else { return nil }
        return SelectionPolicy.clean(result as? String)
    }

    private func isProtected(_ element: AXUIElement) -> Bool {
        if value(attribute: kAXSubroleAttribute, of: element) as? String == "AXSecureTextField" { return true }
        if value(attribute: "AXProtectedContent", of: element) as? Bool == true { return true }
        return (value(attribute: "AXDOMInputType", of: element) as? String)?.lowercased() == "password"
    }

    private func isWindowChrome(_ element: AXUIElement) -> Bool {
        guard let role = value(attribute: kAXRoleAttribute, of: element) as? String else { return false }
        return ["AXTitleBar", "AXScrollBar", "AXSplitter", "AXGrowArea"].contains(role)
    }

    private func isNonTextControl(_ element: AXUIElement) -> Bool {
        guard let role = value(attribute: kAXRoleAttribute, of: element) as? String else { return false }
        return ["AXButton", "AXPopUpButton", "AXToolbar"].contains(role)
    }

    private func isRiskyEditable(_ element: AXUIElement) -> Bool {
        guard before(activeDeadline) else { return false }
        if value(attribute: kAXRoleAttribute, of: element) as? String == "AXTextField" { return true }
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
    }

    private func value(attribute: String, of element: AXUIElement) -> CFTypeRef? {
        guard before(activeDeadline) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }

    private func element(attribute: String, of element: AXUIElement) -> AXUIElement? {
        guard let result = value(attribute: attribute, of: element), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return (result as! AXUIElement)
    }
}
