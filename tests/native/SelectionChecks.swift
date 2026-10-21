import Foundation

/// Pure policy fixtures: no AX calls, input events, real applications or pasteboard.
func runSelectionChecks() throws -> Int {
    struct Failure: LocalizedError {
        let reason: String
        var errorDescription: String? { "Selection policy: " + reason }
    }
    func require(_ value: @autoclosure () -> Bool, _ reason: String) throws -> Int {
        guard value() else { throw Failure(reason: reason) }
        return 1
    }

    var checks = 0
    for distance in [0.0, 1.0, 3.99] {
        checks += try require(!SelectionPolicy.Gesture.drag(distance: distance).canSelectText,
                              "A \(distance)-point movement must not advertise a chat selection")
    }
    checks += try require(SelectionPolicy.Gesture.drag(distance: 4).canSelectText, "Selection drag threshold")
    checks += try require(SelectionPolicy.Gesture.drag(distance: 80).canSelectText, "Long selection drag")
    checks += try require(!SelectionPolicy.Gesture.plainClick.canSelectText, "A plain click cannot renew an old selection")
    checks += try require(!SelectionPolicy.Gesture.multipleClick(1).canSelectText, "A single click cannot select a word")
    checks += try require(SelectionPolicy.Gesture.multipleClick(2).canSelectText, "Double click selects a word")
    checks += try require(SelectionPolicy.Gesture.multipleClick(3).canSelectText, "Triple click selects a paragraph")
    checks += try require(SelectionPolicy.Gesture.extendedClick.canSelectText, "Shift-click can extend a selection")
    checks += try require(SelectionPolicy.Gesture.keyboardSelection.canSelectText, "Keyboard selection is supported")

    let chatBundles = ["com.electron.lark", "com.tencent.xinWeChat"]
    let safeTarget = SelectionPolicy.TargetFacts()
    for bundle in chatBundles {
        checks += try require(SelectionPolicy.isChatApplication(bundle), "Verified chat bundle \(bundle)")
        checks += try require(SelectionPolicy.permitsDeferred(bundle: bundle, gesture: .drag(distance: 20), target: safeTarget),
                              "Chat selection can offer an explicit translation button")
        checks += try require(!SelectionPolicy.permitsDeferred(bundle: bundle, gesture: .plainClick, target: safeTarget),
                              "Chat plain click cannot offer a stale selection")
    }
    for bundle: String? in [nil, "", "com.google.Chrome", "com.tencent.xinWeChat.extra", "COM.TENCENT.XINWECHAT", "com.electron.lark.fake"] {
        checks += try require(!SelectionPolicy.isChatApplication(bundle), "Chat detection must use exact identifiers")
        checks += try require(!SelectionPolicy.permitsDeferred(bundle: bundle, gesture: .keyboardSelection, target: safeTarget),
                              "An unknown application cannot use the deferred chat action")
    }
    for bundle in chatBundles.prefix(1) {
        checks += try require(SelectionPolicy.needsManualAccessibility(bundle), "Lark requires Chromium accessibility activation")
    }
    checks += try require(SelectionPolicy.needsManualAccessibility("com.google.Chrome"), "Existing Chromium accessibility support")
    checks += try require(SelectionPolicy.needsManualAccessibility("com.todesktop.fixture"), "Electron accessibility support")
    checks += try require(!SelectionPolicy.needsManualAccessibility("com.tencent.xinWeChat"), "WeChat is not assumed to be Chromium")
    checks += try require(!SelectionPolicy.needsManualAccessibility(nil), "Unknown bundle does not receive Chromium attributes")

    var unsafeTargets = [SelectionPolicy.TargetFacts]()
    var protectedTarget = safeTarget
    protectedTarget.protected = true
    unsafeTargets.append(protectedTarget)
    var editableTarget = safeTarget
    editableTarget.riskyEditable = true
    unsafeTargets.append(editableTarget)
    var chromeTarget = safeTarget
    chromeTarget.windowChrome = true
    unsafeTargets.append(chromeTarget)
    var foreignTarget = safeTarget
    foreignTarget.belongsToSource = false
    unsafeTargets.append(foreignTarget)
    var incompleteTarget = safeTarget
    incompleteTarget.incomplete = true
    unsafeTargets.append(incompleteTarget)
    for target in unsafeTargets {
        checks += try require(!SelectionPolicy.permitsDeferred(bundle: chatBundles[0], gesture: .drag(distance: 20), target: target),
                              "Protected, editable, window chrome, foreign and incomplete targets cannot advertise copying")
    }
    checks += try require(SelectionPolicy.permitsDeferred(bundle: chatBundles[0], gesture: .drag(distance: 20),
                                                        target: SelectionPolicy.TargetFacts()),
                          "Unavailable AX facts may offer an explicit action; an interrupted inspection may not")
    checks += try require(SelectionPolicy.permitsExplicitChatKeyboardCopy(bundle: "com.tencent.xinWeChat", target: safeTarget),
                          "A safe WeChat selection can use keyboard Copy after an explicit button click")
    for bundle: String? in ["com.electron.lark", "com.google.Chrome", "com.tencent.xinWeChat.extra", nil] {
        checks += try require(!SelectionPolicy.permitsExplicitChatKeyboardCopy(bundle: bundle, target: safeTarget),
                              "The exceptional explicit keyboard Copy path is limited to the exact WeChat bundle")
    }
    for target in unsafeTargets {
        checks += try require(!SelectionPolicy.permitsExplicitChatKeyboardCopy(bundle: "com.tencent.xinWeChat", target: target),
                              "WeChat keyboard Copy rejects protected, editable, window chrome, foreign and incomplete targets")
    }

    // Mouse-up only decides whether to offer a button. The policy supplies no
    // automatic-copy operation; clipboard decisions below model an explicit click.
    let offeredOnMouseUp = SelectionPolicy.permitsDeferred(bundle: chatBundles[0], gesture: .drag(distance: 20), target: safeTarget)
    let untouchedClipboard = SelectionPolicy.clipboardDecision(originalCount: 8, observedCount: 8, text: "old clipboard",
                                                               sameApplication: true, sameGeneration: true, userRequestedCopy: false)
    checks += try require(offeredOnMouseUp && untouchedClipboard == .wait, "Offering an action does not turn existing clipboard text into a selection")
    checks += try require(SelectionPolicy.permitsExplicitChatKeyboardCopy(bundle: "com.tencent.xinWeChat", target: safeTarget)
                          && untouchedClipboard == .wait,
                          "Checking explicit WeChat Copy eligibility does not consume clipboard text during a gesture")

    checks += try require(SelectionPolicy.isCurrent(originPID: 42, generation: 9, currentPID: 42, currentGeneration: 9,
                                                  enabled: true, cancelled: false), "Current read may complete")
    checks += try require(!SelectionPolicy.isCurrent(originPID: 42, generation: 9, currentPID: 43, currentGeneration: 9,
                                                   enabled: true, cancelled: false), "Changing applications invalidates a read")
    checks += try require(!SelectionPolicy.isCurrent(originPID: 42, generation: 9, currentPID: nil, currentGeneration: 9,
                                                   enabled: true, cancelled: false), "Missing frontmost application invalidates a read")
    checks += try require(!SelectionPolicy.isCurrent(originPID: 42, generation: 9, currentPID: 42, currentGeneration: 10,
                                                   enabled: true, cancelled: false), "A newer gesture invalidates an old result even in the same app")
    checks += try require(!SelectionPolicy.isCurrent(originPID: 42, generation: 9, currentPID: 42, currentGeneration: 9,
                                                   enabled: false, cancelled: false), "Disabling selection invalidates a pending read")
    checks += try require(!SelectionPolicy.isCurrent(originPID: 42, generation: 9, currentPID: 42, currentGeneration: 9,
                                                   enabled: true, cancelled: true), "Cancelled read cannot complete")
    let cancellation = SelectionCancellation()
    let independentCancellation = SelectionCancellation()
    checks += try require(!cancellation.isCancelled, "A new origin cancellation token is active")
    let queuedReadAllowed = {
        !cancellation.isCancelled && SelectionPolicy.isCurrent(originPID: 42, generation: 9,
                                                               currentPID: 42, currentGeneration: 9,
                                                               enabled: true, cancelled: false)
    }
    checks += try require(queuedReadAllowed(), "A queued read can observe its originating active token")
    cancellation.cancel()
    checks += try require(cancellation.isCancelled && !queuedReadAllowed(), "A captured queue predicate observes later origin cancellation")
    cancellation.cancel()
    checks += try require(cancellation.isCancelled, "Origin cancellation is idempotent")
    checks += try require(!independentCancellation.isCancelled, "Cancelling one selection does not cancel a newer token")

    checks += try require(SelectionPolicy.clean(nil) == nil, "Missing selected text")
    checks += try require(SelectionPolicy.clean(" \n\t ") == nil, "Whitespace is not selected content")
    checks += try require(SelectionPolicy.clean("\u{0001}\u{0002}") == nil, "Control-only content is rejected")
    checks += try require(SelectionPolicy.clean(" \n你好，world 🎹\t") == "你好，world 🎹", "Multilingual selection is trimmed without changing its content")
    checks += try require(SelectionPolicy.clean("first\nsecond") == "first\nsecond", "Selected line breaks are retained")
    checks += try require(SelectionPolicy.clean(String(repeating: "字", count: 16_000))?.count == 16_000, "Maximum supported selection length")
    checks += try require(SelectionPolicy.clean(String(repeating: "字", count: 16_001)) == nil, "Oversized selected text is rejected")

    struct Node {
        var selection: String?
        var fullValue: String?
        var children: [Int] = []
        var protected = false
    }
    func selection(in nodes: [Int: Node], seeds: [Int], maximumNodes: Int = 80, maximumDepth: Int = 5,
                   canContinue: () -> Bool = { true }, reads: inout [Int], expanded: inout [Int]) -> String? {
        SelectionPolicy.selectedText(seeds: seeds, maximumNodes: maximumNodes, maximumDepth: maximumDepth,
                                     same: ==, canContinue: canContinue,
                                     protected: { nodes[$0]?.protected ?? false },
                                     read: { node in
                                         reads.append(node)
                                         // The fixture carries full values to catch accidental use of
                                         // surrounding messages. Only selection is a legal input.
                                         return nodes[node]?.selection
                                     }, children: { node in
                                         expanded.append(node)
                                         return nodes[node]?.children ?? []
                                     })
    }
    var reads = [Int]()
    var expanded = [Int]()
    let chatTree = [
        0: Node(fullValue: "Unselected composer and previous chat history", children: [1, 2]),
        1: Node(fullValue: "An older unselected message", children: [3]),
        2: Node(selection: " Selected chat message "),
        3: Node(selection: "A deeper selection")
    ]
    var text = selection(in: chatTree, seeds: [0], reads: &reads, expanded: &expanded)
    checks += try require(text == "Selected chat message", "Bounded traversal finds selected chat text outside the focused editor")
    checks += try require(reads == [0, 1, 2], "Breadth-first traversal prefers the nearest selected node")
    checks += try require(!reads.contains(3), "Finding a selection stops traversal before unrelated descendants")

    reads = []; expanded = []
    text = selection(in: [0: Node(fullValue: "Private unselected chat history", children: [1]),
                          1: Node(fullValue: "Another whole message")], seeds: [0], reads: &reads, expanded: &expanded)
    checks += try require(text == nil, "Whole message values must never substitute for an actual selection")

    reads = []; expanded = []
    text = selection(in: [0: Node(selection: " \n ", children: [2]), 1: Node(selection: "hit-test selection"),
                          2: Node(selection: "focused descendant")], seeds: [0, 1], reads: &reads, expanded: &expanded)
    checks += try require(text == "hit-test selection" && reads == [0, 1], "Hit-test seed is checked before unrelated focused descendants")

    reads = []; expanded = []
    let deferredSourceTree = [10: Node(children: [12]), 11: Node(),
                              12: Node(selection: "original source selection"),
                              99: Node(selection: "foreign overlay text")]
    text = selection(in: deferredSourceTree, seeds: [10, 11], reads: &reads, expanded: &expanded)
    checks += try require(text == "original source selection", "Deferred selection resolves from retained source gesture endpoints")
    checks += try require(!reads.contains(99) && reads == [10, 11, 12],
                          "A foreign overlay under the current pointer is never used as a source seed")

    reads = []; expanded = []
    text = selection(in: [0: Node(selection: "secret", children: [1], protected: true),
                          1: Node(selection: "nested secret"), 2: Node(selection: "public selection")],
                     seeds: [0, 2], reads: &reads, expanded: &expanded)
    checks += try require(text == "public selection", "Protected branch does not block a separate safe seed")
    checks += try require(reads == [2] && !expanded.contains(0), "Protected nodes and their descendants are never read or expanded")

    reads = []; expanded = []
    text = selection(in: [0: Node(children: [1, 1]), 1: Node(children: [0, 1])],
                     seeds: [0, 0], reads: &reads, expanded: &expanded)
    checks += try require(text == nil && reads == [0, 1], "Duplicate references and ancestor cycles are visited once")
    checks += try require(expanded == [0, 1], "Cyclic branches are expanded once")

    let deepTree = [0: Node(children: [1]), 1: Node(children: [2]), 2: Node(selection: "deep selection")]
    reads = []; expanded = []
    text = selection(in: deepTree, seeds: [0], maximumNodes: 2, reads: &reads, expanded: &expanded)
    checks += try require(text == nil && reads == [0, 1], "Node budget bounds reads without visiting the third node")
    reads = []; expanded = []
    text = selection(in: deepTree, seeds: [0], maximumNodes: 0, reads: &reads, expanded: &expanded)
    checks += try require(text == nil && reads.isEmpty && expanded.isEmpty, "Zero node budget performs no traversal")
    reads = []; expanded = []
    text = selection(in: deepTree, seeds: [0], maximumDepth: 0, reads: &reads, expanded: &expanded)
    checks += try require(text == nil && reads == [0] && expanded.isEmpty, "Depth zero examines only the supplied seeds")
    reads = []; expanded = []
    text = selection(in: deepTree, seeds: [0], maximumDepth: 1, reads: &reads, expanded: &expanded)
    checks += try require(text == nil && reads == [0, 1] && expanded == [0], "Depth limit excludes grandchildren")
    reads = []; expanded = []
    text = selection(in: deepTree, seeds: [0], maximumDepth: 2, reads: &reads, expanded: &expanded)
    checks += try require(text == "deep selection", "Selection at the allowed depth remains reachable")

    reads = []; expanded = []
    text = selection(in: chatTree, seeds: [0], canContinue: { false }, reads: &reads, expanded: &expanded)
    checks += try require(text == nil && reads.isEmpty && expanded.isEmpty, "Cancelled or expired traversal performs no read")
    var continueChecks = 0
    reads = []; expanded = []
    text = selection(in: chatTree, seeds: [0], canContinue: { continueChecks += 1; return continueChecks < 2 },
                     reads: &reads, expanded: &expanded)
    checks += try require(text == nil && reads.isEmpty, "Cancellation during protection checks prevents selected-text IPC")
    var mayContinue = true
    var readAfterCancellation = [Int]()
    var expansionsAfterCancellation = 0
    text = SelectionPolicy.selectedText(seeds: [0], same: ==, canContinue: { mayContinue }, protected: { _ in false },
                                        read: { node in readAfterCancellation.append(node); mayContinue = false; return nil },
                                        children: { _ in expansionsAfterCancellation += 1; return [99] })
    checks += try require(text == nil && readAfterCancellation == [0] && expansionsAfterCancellation == 0,
                          "Cancellation after a read prevents descendant expansion")

    func menu(identifier: String? = nil, title: String? = nil, command: String? = nil, enabled: Bool = true) -> SelectionPolicy.CopyMenuItem {
        SelectionPolicy.CopyMenuItem(identifier: identifier, title: title, commandCharacter: command, enabled: enabled)
    }
    checks += try require(menu(identifier: "copy:").isStandardCopy, "Standard Copy selector is recognized independent of menu language")
    for title in ["Copy", "复制", "拷贝", "コピー"] {
        checks += try require(menu(title: " \(title) ", command: "c").isStandardCopy, "Standard localized Copy title \(title)")
    }
    checks += try require(menu(title: "Copy", command: "C").isStandardCopy, "Copy command character matching is case insensitive")
    for title in ["Copy Link", "Copy Message Link", "复制链接", "全部复制", "copy"] {
        checks += try require(!menu(title: title, command: "c").isStandardCopy, "Nonstandard menu action must not masquerade as Copy")
    }
    checks += try require(!menu(title: "Copy").isStandardCopy, "A title alone is insufficient to identify a Copy action")
    checks += try require(!menu(title: "Copy", command: "x").isStandardCopy, "Cut shortcut cannot be treated as Copy")
    let disabledCopy = menu(identifier: "copy:", enabled: false)
    checks += try require(disabledCopy.isStandardCopy && !disabledCopy.enabled, "Disabled Copy remains identifiable but ineligible for invocation")
    for title in ["Edit", "编辑", "編輯", "編集"] {
        checks += try require(SelectionPolicy.isEditMenu(title: title), "Localized Edit menu \(title) is recognized")
    }
    for title: String? in [nil, "", "File", "Copy", "Edit Message", "编辑消息"] {
        checks += try require(!SelectionPolicy.isEditMenu(title: title), "Only an Edit menu may be searched for the standard Copy action")
    }
    if case .unavailable = SelectionPolicy.menuFallbackResult(searchCompleted: true) {
        checks += 1
    } else {
        throw Failure(reason: "A completed menu search may allow the explicit keyboard-copy fallback")
    }
    if case .disabled = SelectionPolicy.menuFallbackResult(searchCompleted: false) {
        checks += 1
    } else {
        throw Failure(reason: "Interrupted or exhausted menu searches must prevent keyboard-copy fallback")
    }

    func decision(_ count: Int, text: String?, sameApplication: Bool = true, sameGeneration: Bool = true,
                  userRequestedCopy: Bool = false) -> SelectionPolicy.ClipboardDecision {
        SelectionPolicy.clipboardDecision(originalCount: 10, observedCount: count, text: text,
                                           sameApplication: sameApplication, sameGeneration: sameGeneration,
                                           userRequestedCopy: userRequestedCopy)
    }
    // One explicit-copy attempt: existing clipboard -> no update -> actual copied
    // selection. Repeated unchanged observations must never return the old text.
    let explicitSequence = [decision(10, text: "existing user clipboard"), decision(10, text: nil),
                            decision(11, text: " \nselected message\t")]
    checks += try require(explicitSequence == [.wait, .wait, .acceptAndRestore("selected message")],
                          "Explicit copy accepts only a new, valid clipboard text update")
    checks += try require(decision(11, text: nil) == .abandon, "A non-text clipboard update must remain untouched")
    checks += try require(decision(11, text: " \n ") == .abandon, "An empty copied value must remain untouched")
    checks += try require(decision(11, text: String(repeating: "x", count: 16_001)) == .abandon, "Oversized copied value cannot become a translation")
    checks += try require(decision(11, text: "new app copy", sameApplication: false) == .abandon, "Focus change leaves the newer clipboard untouched")
    checks += try require(decision(11, text: "new gesture copy", sameGeneration: false) == .abandon, "New gesture leaves the newer clipboard untouched")
    checks += try require(decision(11, text: "user copy", userRequestedCopy: true) == .abandon, "A real user copy is never translated or restored over")
    checks += try require(decision(10, text: "old text", sameApplication: false) == .abandon, "Focus change cancels before waiting for clipboard change")
    checks += try require(decision(10, text: "old text", sameGeneration: false) == .abandon, "A superseded copy attempt cancels before waiting")
    checks += try require(decision(10, text: "old text", userRequestedCopy: true) == .abandon, "User Copy cancels even before its pasteboard update arrives")

    return checks
}

/// Mock dispatch callbacks only: never construct or post a CGEvent.
@MainActor
func runSelectionDispatchChecks() async throws -> Int {
    struct Failure: LocalizedError {
        let reason: String
        var errorDescription: String? { "Selection dispatch: " + reason }
    }
    func require(_ value: @autoclosure () -> Bool, _ reason: String) throws -> Int {
        guard value() else { throw Failure(reason: reason) }
        return 1
    }
    var checks = 0
    var trace = [String]()
    let sent = await SelectionPolicy.sendCopyKey(to: 42, allowed: { true },
                                                keyDown: { trace.append("down:\($0)"); return true },
                                                keyUp: { trace.append("up:\($0)") },
                                                pause: { trace.append("pause"); await Task.yield() })
    checks += try require(sent, "An allowed dispatch reports successful key delivery")
    checks += try require(trace == ["down:42", "pause", "up:42"], "Copy sends one ordered key pair to the original PID")

    for pid: Int32 in [0, -1] {
        trace = []
        let sent = await SelectionPolicy.sendCopyKey(to: pid, allowed: { true },
                                                    keyDown: { trace.append("down:\($0)"); return true },
                                                    keyUp: { trace.append("up:\($0)") },
                                                    pause: { trace.append("pause") })
        checks += try require(!sent && trace.isEmpty, "Invalid process \(pid) receives no key, pause or key-up")
    }

    trace = []
    let rejected = await SelectionPolicy.sendCopyKey(to: 42, allowed: { false },
                                                    keyDown: { trace.append("down:\($0)"); return true },
                                                    keyUp: { trace.append("up:\($0)") },
                                                    pause: { trace.append("pause") })
    checks += try require(!rejected && trace.isEmpty, "A stale or cancelled request cannot begin key dispatch")

    trace = []
    let failed = await SelectionPolicy.sendCopyKey(to: 42, allowed: { true },
                                                  keyDown: { trace.append("down:\($0)"); return false },
                                                  keyUp: { trace.append("up:\($0)") },
                                                  pause: { trace.append("pause") })
    checks += try require(!failed && trace == ["down:42"], "A failed key-down is not retried and receives no pause or unmatched key-up")

    trace = []
    let token = SelectionCancellation()
    _ = await SelectionPolicy.sendCopyKey(to: 42, allowed: { !token.isCancelled },
                                         keyDown: { trace.append("down:\($0)"); return true },
                                         keyUp: { trace.append("up:\($0)") },
                                         pause: { trace.append("pause"); token.cancel(); await Task.yield() })
    checks += try require(token.isCancelled && trace == ["down:42", "pause", "up:42"],
                          "Origin cancellation during the pause still releases the original process's key")

    trace = []
    var foregroundPID: Int32 = 42
    _ = await SelectionPolicy.sendCopyKey(to: 42, allowed: { foregroundPID == 42 },
                                         keyDown: { trace.append("down:\($0)"); return true },
                                         keyUp: { trace.append("up:\($0)") },
                                         pause: { trace.append("pause"); foregroundPID = 77; await Task.yield() })
    checks += try require(foregroundPID == 77 && trace == ["down:42", "pause", "up:42"],
                          "Focus changes never route key-up into the newly active application")

    trace = []
    let cancelledDispatch = Task { @MainActor in
        await SelectionPolicy.sendCopyKey(to: 42, allowed: { !Task.isCancelled },
                                          keyDown: { trace.append("down:\($0)"); return true },
                                          keyUp: { trace.append("up:\($0)") },
                                          pause: {
                                              trace.append("pause")
                                              withUnsafeCurrentTask { $0?.cancel() }
                                              await Task.yield()
                                          })
    }
    _ = await cancelledDispatch.value
    checks += try require(cancelledDispatch.isCancelled && trace == ["down:42", "pause", "up:42"],
                          "Actual Task cancellation cannot leave the source application's copy key held down")
    return checks
}
