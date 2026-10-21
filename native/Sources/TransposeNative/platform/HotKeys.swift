import AppKit
import Carbon

@MainActor
final class HotKeys {
    static let captureShortcutLabel = "⌥S"

    private var handler: EventHandlerRef?
    private var registrations: [EventHotKeyRef] = []
    private var localMonitor: Any?
    private var lastActionTime: TimeInterval = 0
    var onSelection: (() -> Void)?
    var onCapture: (() -> Void)?
    private(set) var failed: [String] = []

    func register() {
        unregister()
        failed.removeAll()
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let owner = Unmanaged<HotKeys>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                owner.perform(id.id)
            }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard handlerStatus == noErr else {
            failed.append(L10n.text("快捷键监听失败") + " (\(handlerStatus))")
            return
        }
        // Selection is detected from the user's mouse/keyboard selection gesture;
        // capture is the only global keyboard shortcut.
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_S), UInt32(optionKey),
            EventHotKeyID(signature: 0x5452414E, id: 2),
            GetApplicationEventTarget(), 0, &reference
        )
        guard status == noErr, let reference else {
            failed.append(Self.captureShortcutLabel + " · "
                + L10n.text("快捷键注册失败，可能已被其他应用占用")
                + " (\(status))")
            unregister()
            return
        }
        registrations.append(reference)
        // Local events also cover synthesized shortcuts and controls which consume
        // an Option combination before Carbon delivers it to the dispatcher.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let id = Self.actionID(event) else { return event }
            MainActor.assumeIsolated { self?.perform(id) }
            return nil
        }
    }

    nonisolated private static func actionID(_ event: NSEvent) -> UInt32? {
        guard !event.isARepeat,
              event.modifierFlags.intersection([.command, .option, .control, .shift]) == [.option] else { return nil }
        switch Int(event.keyCode) {
        case kVK_ANSI_S: return 2
        default: return nil
        }
    }

    private func perform(_ id: UInt32) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastActionTime > 0.25 else { return }
        lastActionTime = now
        if id == 2 { onCapture?() }
    }

    func unregister() {
        registrations.forEach { UnregisterEventHotKey($0) }
        registrations.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
    }
}
