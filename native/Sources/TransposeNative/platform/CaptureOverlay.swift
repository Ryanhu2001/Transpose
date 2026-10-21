import AppKit
import ApplicationServices
import QuartzCore
import ScreenCaptureKit

@MainActor
final class CaptureCoordinator {
    var onCapture: ((String, NSPoint) -> Void)?
    var onError: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onRecognizing: ((NSPoint) -> Void)?
    private(set) var isActive = false
    private(set) var screenRecordingNeedsRestart = false
    var hasOutline: Bool { outlinePanel != nil }
    var selectionFrame: CGRect? { outlineGeometry?.selectionFrame }

    private var panels: [CapturePanel] = []
    private var outlinePanel: CaptureOutlinePanel?
    private var outlineGeometry: CaptureOutlineGeometry?
    private var task: Task<Void, Never>?
    private var keyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var generation = UUID()

    func begin() {
        guard !isActive else { return }
        clearOutline()
        guard !screenRecordingNeedsRestart else {
            onError?(CapturePermission.restartMessage)
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            onError?("请在系统设置 → 隐私与安全性 → 屏幕与系统音频录制中允许 Transpose，然后重新打开应用。")
            return
        }
        isActive = true
        installKeyMonitors()
        let session = UUID()
        generation = session
        task = Task { [weak self] in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let self, !Task.isCancelled, self.generation == session else { return }
                let ownWindows = content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }
                // Capture every display before adding any overlay windows. Each preview stays frozen
                // until selection ends; OCR uses precisely the pixels the user has circled.
                var snapshots: [CaptureSnapshot] = []
                for screen in NSScreen.screens {
                    guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                          let display = content.displays.first(where: { $0.displayID == displayID.uint32Value }) else { continue }
                    let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
                    let config = SCStreamConfiguration()
                    let scale = max(CGFloat(filter.pointPixelScale), screen.backingScaleFactor)
                    config.width = max(1, Int((screen.frame.width * scale).rounded()))
                    config.height = max(1, Int((screen.frame.height * scale).rounded()))
                    config.showsCursor = false
                    config.captureResolution = .best
                    config.capturesAudio = false
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    guard !Task.isCancelled, self.generation == session else { return }
                    snapshots.append(CaptureSnapshot(image: image, screenFrame: screen.frame))
                }
                guard !snapshots.isEmpty else {
                    self.finishWithError("没有找到可圈选的屏幕。")
                    return
                }
                self.show(snapshots: snapshots)
            } catch {
                guard let self, !Task.isCancelled, self.generation == session else { return }
                if let recovery = CapturePermission.recovery(for: error, preflightGranted: CGPreflightScreenCaptureAccess()) {
                    if recovery == .restartApplication { self.screenRecordingNeedsRestart = true }
                    self.finishWithError(CapturePermission.message(for: recovery))
                } else {
                    self.finishWithError("无法读取屏幕：\(error.localizedDescription)")
                }
            }
        }
    }

    func cancel() {
        let shouldNotify = isActive || hasOutline
        generation = UUID()
        task?.cancel()
        task = nil
        dismissPanels()
        clearOutline()
        removeKeyMonitors()
        isActive = false
        if shouldNotify { onCancel?() }
    }

    func containsOutline(_ globalPoint: NSPoint) -> Bool {
        outlineGeometry?.contains(globalPoint) ?? false
    }

    /// Clearing the retained border must not cancel screenshots or an in-flight OCR request.
    func clearOutline() {
        outlinePanel?.orderOut(nil)
        outlinePanel?.close()
        outlinePanel = nil
        outlineGeometry = nil
    }

    private func show(snapshots: [CaptureSnapshot]) {
        panels = snapshots.map { snapshot in
            let panel = CapturePanel(contentRect: snapshot.screenFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .screenSaver
            panel.backgroundColor = .clear
            panel.isOpaque = true
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.acceptsMouseMovedEvents = true
            let view = CaptureOverlayView(snapshot: snapshot)
            view.onBegin = { [weak self, weak view] in
                self?.panels.compactMap { $0.contentView as? CaptureOverlayView }.filter { $0 !== view }.forEach { $0.clearSelection() }
            }
            view.onSelect = { [weak self] selection in self?.recognize(snapshot: snapshot, selection: selection) }
            view.onCancel = { [weak self] in self?.cancel() }
            panel.contentView = view
            panel.makeFirstResponder(view)
            panel.orderFrontRegardless()
            return panel
        }
        let mouse = NSEvent.mouseLocation
        (panels.first { $0.frame.contains(mouse) } ?? panels.first)?.makeKey()
    }

    private func recognize(snapshot: CaptureSnapshot, selection: CaptureSelection) {
        guard isActive else { return }
        let rect = selection.bounds
        guard rect.width >= 8, rect.height >= 8, CaptureGeometry.filledAreaEstimate(selection.points) >= 80 else {
            NSSound.beep()
            panels.compactMap { $0.contentView as? CaptureOverlayView }.forEach { $0.clearSelection() }
            return
        }
        let session = generation
        retainOutline(selection: selection, screenFrame: snapshot.screenFrame)
        dismissPanels()
        onRecognizing?(NSPoint(x: snapshot.screenFrame.minX + rect.maxX,
                               y: snapshot.screenFrame.minY + rect.minY))
        task = Task { [weak self] in
            do {
                let text = try await OCRService.recognize(image: snapshot.image, canvas: snapshot.screenFrame.size, selection: selection)
                guard let self, !Task.isCancelled, self.generation == session else { return }
                self.isActive = false
                self.task = nil
                self.removeKeyMonitors()
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    self.onError?("圈选区域里没有识别到文字，请重新圈选。")
                    return
                }
                let anchor = NSPoint(x: snapshot.screenFrame.minX + rect.maxX,
                                     y: snapshot.screenFrame.minY + rect.minY)
                self.onCapture?(text, anchor)
            } catch {
                guard let self, !Task.isCancelled, self.generation == session else { return }
                self.finishWithError("文字识别失败：\(error.localizedDescription)")
            }
        }
    }

    private func retainOutline(selection: CaptureSelection, screenFrame: CGRect) {
        clearOutline()
        let geometry = CaptureOutlineGeometry(selection: selection, screenFrame: screenFrame)
        let panel = CaptureOutlinePanel(contentRect: geometry.windowFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = NSView(frame: CGRect(origin: .zero, size: geometry.windowFrame.size))
        view.wantsLayer = true
        let scale = NSScreen.screens.first { $0.frame.intersects(screenFrame) }?.backingScaleFactor ?? 2
        for halo in [true, false] {
            let shape = CAShapeLayer()
            CaptureAppearance.configure(shape, bounds: view.bounds, scale: scale, halo: halo)
            shape.path = geometry.localPath
            view.layer?.addSublayer(shape)
        }
        panel.contentView = view
        outlineGeometry = geometry
        outlinePanel = panel
        panel.orderFrontRegardless()
    }

    private func finishWithError(_ message: String) {
        dismissPanels()
        removeKeyMonitors()
        isActive = false
        task = nil
        onError?(message)
    }

    private func dismissPanels() {
        for panel in panels { panel.orderOut(nil); panel.close() }
        panels.removeAll()
        NSCursor.arrow.set()
    }

    private func installKeyMonitors() {
        removeKeyMonitors()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { self?.cancel() }
            return nil
        }
        // The source app can still own focus while screenshots are being prepared.
        // Use an existing accessibility grant; this never requests a new permission.
        if AXIsProcessTrusted() {
            globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53 else { return }
                MainActor.assumeIsolated { self?.cancel() }
            }
        }
    }

    private func removeKeyMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor); self.globalKeyMonitor = nil }
    }
}

private struct CaptureSnapshot {
    let image: CGImage
    let screenFrame: NSRect
}

private final class CapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    // Overlay frames include the menu bar and Dock, including displays above/below the main screen.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private final class CaptureOutlinePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
private final class CaptureOverlayView: NSView {
    var onBegin: (() -> Void)?
    var onSelect: ((CaptureSelection) -> Void)?
    var onCancel: (() -> Void)?
    private let imageLayer = CALayer()
    private let haloLayer = CAShapeLayer()
    private let strokeLayer = CAShapeLayer()
    private let startLayer = CAShapeLayer()
    private var hint: NSView?
    private var stroke = CaptureStroke()

    init(snapshot: CaptureSnapshot) {
        super.init(frame: CGRect(origin: .zero, size: snapshot.screenFrame.size))
        wantsLayer = true
        layer?.isGeometryFlipped = false
        // Upload the frozen screenshot once. Pointer movement only changes a tiny vector path.
        CaptureLayerGeometry.configurePreview(imageLayer, image: snapshot.image, bounds: bounds)
        layer?.addSublayer(imageLayer)
        for (shape, halo) in [(haloLayer, true), (strokeLayer, false)] {
            CaptureAppearance.configure(shape, bounds: bounds, scale: imageLayer.contentsScale, halo: halo)
            layer?.addSublayer(shape)
        }
        CaptureAppearance.configure(startLayer, bounds: bounds, scale: imageLayer.contentsScale)
        startLayer.fillColor = CaptureAppearance.accent.cgColor
        startLayer.strokeColor = CaptureAppearance.paper.cgColor
        startLayer.lineWidth = 1.8
        layer?.addSublayer(startLayer)
        installHint()
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    func clearSelection() {
        stroke.clear()
        updateStrokeLayers()
        hint?.isHidden = false
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        onBegin?()
        hint?.isHidden = true
        let point = location(event)
        stroke.begin(at: point, rectangle: event.modifierFlags.contains(.shift))
        updateStrokeLayers()
    }

    override func mouseDragged(with event: NSEvent) {
        guard stroke.isDrawing else { return }
        stroke.update(to: location(event), rectangle: event.modifierFlags.contains(.shift))
        updateStrokeLayers()
    }

    override func mouseUp(with event: NSEvent) {
        guard let selection = stroke.finish(at: location(event), rectangle: event.modifierFlags.contains(.shift)) else { return }
        onSelect?(selection)
    }

    override func flagsChanged(with event: NSEvent) {
        guard stroke.isDrawing else { return }
        stroke.setRectangle(event.modifierFlags.contains(.shift))
        updateStrokeLayers()
    }

    private func location(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(0, point.x), bounds.width), y: min(max(0, point.y), bounds.height))
    }

    private func updateStrokeLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = stroke.openPath
        haloLayer.path = path
        strokeLayer.path = path
        startLayer.path = stroke.origin.map { point in
            let diameter = CaptureAppearance.startDiameter
            return CGPath(ellipseIn: CGRect(x: point.x - diameter / 2, y: point.y - diameter / 2,
                                          width: diameter, height: diameter), transform: nil)
        }
        CATransaction.commit()
    }

    private func installHint() {
        let label = NSTextField(labelWithString: L10n.text("圈选翻译   ·   ⇧ 矩形   ·   Esc 取消"))
        label.font = .systemFont(ofSize: 11.5, weight: .medium)
        label.textColor = CaptureAppearance.ink
        label.alignment = .center
        label.sizeToFit()
        let hint = NSView(frame: CGRect(x: (bounds.width - label.frame.width - 24) / 2,
                                       y: bounds.height - 56, width: label.frame.width + 24, height: 26))
        hint.wantsLayer = true
        hint.layer?.backgroundColor = CaptureAppearance.paper.withAlphaComponent(0.96).cgColor
        hint.layer?.cornerRadius = 13
        hint.layer?.borderColor = NSColor(calibratedWhite: 0.78, alpha: 0.6).cgColor
        hint.layer?.borderWidth = 0.5
        hint.layer?.shadowColor = NSColor.black.cgColor
        hint.layer?.shadowOpacity = 0.08
        hint.layer?.shadowRadius = 8
        hint.layer?.shadowOffset = CGSize(width: 0, height: -2)
        label.frame.origin = CGPoint(x: 12, y: (hint.bounds.height - label.frame.height) / 2)
        hint.addSubview(label)
        addSubview(hint)
        self.hint = hint
    }
}
