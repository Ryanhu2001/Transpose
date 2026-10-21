import Foundation

/// Selection rules deliberately contain no AX, event or pasteboard operations.
/// A chat fallback advertises an explicit action; it never copies on mouse-up.
enum SelectionPolicy {
    enum Gesture {
        case drag(distance: Double), multipleClick(Int), extendedClick, keyboardSelection, plainClick
        var canSelectText: Bool {
            switch self {
            case .drag(let distance): return distance >= 4
            case .multipleClick(let count): return count >= 2
            case .extendedClick, .keyboardSelection: return true
            case .plainClick: return false
            }
        }
    }

    struct TargetFacts {
        var protected = false
        var riskyEditable = false
        var windowChrome = false
        var belongsToSource = true
        var incomplete = false
    }

    static func isChatApplication(_ bundle: String?) -> Bool {
        guard let bundle else { return false }
        return ["com.electron.lark", "com.tencent.xinWeChat"].contains(bundle)
    }

    static func needsManualAccessibility(_ bundle: String?) -> Bool {
        guard let bundle else { return false }
        if ["com.electron.lark"].contains(bundle) { return true }
        return ["com.google.Chrome", "org.chromium.Chromium", "com.microsoft.edgemac",
                "com.brave.Browser", "company.thebrowser.Browser", "com.vivaldi.Vivaldi",
                "com.todesktop.", "com.microsoft.VSCode", "com.cursor.Cursor"]
            .contains(where: { bundle.hasPrefix($0) })
    }

    static func permitsDeferred(bundle: String?, gesture: Gesture, target: TargetFacts) -> Bool {
        isChatApplication(bundle) && gesture.canSelectText && !target.protected
            && !target.riskyEditable && !target.windowChrome && target.belongsToSource && !target.incomplete
    }

    static func isCurrent(originPID: Int32, generation: Int, currentPID: Int32?, currentGeneration: Int,
                          enabled: Bool, cancelled: Bool) -> Bool {
        enabled && !cancelled && originPID == currentPID && generation == currentGeneration
    }

    static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 16_000,
              !text.unicodeScalars.allSatisfy({ CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return text
    }

    /// Only visit selection attributes. Full values from other messages are never read.
    static func selectedText<Node>(seeds: [Node], maximumNodes: Int = 80, maximumDepth: Int = 5,
                                   same: (Node, Node) -> Bool,
                                   canContinue: () -> Bool,
                                   protected: (Node) -> Bool,
                                   read: (Node) -> String?, children: (Node) -> [Node]) -> String? {
        var pending = seeds.map { ($0, 0) }
        var visited: [Node] = []
        var offset = 0
        while offset < pending.count && visited.count < maximumNodes && canContinue() {
            let (node, depth) = pending[offset]
            offset += 1
            guard !visited.contains(where: { same($0, node) }) else { continue }
            visited.append(node)
            guard !protected(node), canContinue() else { continue }
            if let text = clean(read(node)) { return text }
            guard depth < maximumDepth, canContinue() else { continue }
            // The queue itself is bounded, including duplicate references.
            let capacity = max(0, maximumNodes * 2 - pending.count)
            pending.append(contentsOf: children(node).prefix(capacity).map { ($0, depth + 1) })
        }
        return nil
    }

    struct CopyMenuItem {
        var identifier: String?
        var title: String?
        var commandCharacter: String?
        var enabled: Bool
        var isStandardCopy: Bool {
            if identifier == "copy:" { return true }
            let title = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return ["Copy", "复制", "拷贝", "コピー"].contains(title)
                && commandCharacter?.lowercased() == "c"
        }
    }

    static func isEditMenu(title: String?) -> Bool {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return ["Edit", "编辑", "編輯", "編集"].contains(title)
    }

    enum CopyMenuResult { case invoked, disabled, unavailable }
    static func menuFallbackResult(searchCompleted: Bool) -> CopyMenuResult {
        searchCompleted ? .unavailable : .disabled
    }
    enum ClipboardDecision: Equatable { case wait, abandon, acceptAndRestore(String) }

    static func clipboardDecision(originalCount: Int, observedCount: Int, text: String?,
                                  sameApplication: Bool, sameGeneration: Bool,
                                  userRequestedCopy: Bool) -> ClipboardDecision {
        guard sameApplication, sameGeneration, !userRequestedCopy else { return .abandon }
        guard originalCount != observedCount else { return .wait }
        // Non-text updates might come from another app; leave them untouched.
        guard let text = clean(text) else { return .abandon }
        return .acceptAndRestore(text)
    }
}

/// Explicit-copy cancellation must remain visible when AX work leaves the
/// originating Swift Task and calls back from a dispatch queue.
final class SelectionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
    }
}
