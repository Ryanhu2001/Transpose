import AppKit
import NaturalLanguage
import SwiftUI
import Translation

/// The system service uses downloaded, on-device models. A normal translation
/// never requests a model download; only the explicit setup view may do that.
@MainActor
enum AppleTranslationBackend {
    static var isSupported: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    static func translate(_ text: String, options: TranslationOptions,
                          onDelta: @escaping @MainActor (String) -> Void) async throws -> String {
        guard #available(macOS 15.0, *) else {
            throw AppError.message("Apple 翻译需要 macOS 15 或更新版本。")
        }
        try Task.checkCancellation()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppError.message("没有可翻译的文字。")
        }
        let pair = try AppleTranslationLanguages.pair(for: text, target: options.targetLanguage)
        if AppleTranslationLanguages.sameLanguage(pair.source, pair.target) {
            try Task.checkCancellation()
            onDelta(text)
            return text
        }
        let availability = AppleTranslationLanguages.availability()
        let status = await availability.status(from: pair.source, to: pair.target)
        try Task.checkCancellation()
        switch status {
        case .installed: break
        case .supported:
            AppleTranslationDownloadRequest.shared.pair = (pair.source.minimalIdentifier, pair.target.minimalIdentifier)
            throw AppError.message("请在设置的 Apple 翻译中点击“准备语言包”，同意系统下载后重试。")
        case .unsupported:
            throw AppError.message("Apple 翻译暂不支持这组语言，请在设置中选择其他渠道。")
        @unknown default:
            throw AppError.message("暂时无法确认 Apple 翻译的语言支持。")
        }

        if #available(macOS 26.0, *) {
            let session: TranslationSession
            if #available(macOS 26.4, *) {
                session = TranslationSession(installedSource: pair.source, target: pair.target, preferredStrategy: .lowLatency)
            } else {
                session = TranslationSession(installedSource: pair.source, target: pair.target)
            }
            return try await withTaskCancellationHandler {
                try await translateInstalled(text, session: session, onDelta: onDelta)
            } onCancel: {
                Task { @MainActor in session.cancel() }
            }
        }
        return try await AppleTranslationBroker.shared.translate(text, source: pair.source, target: pair.target, onDelta: onDelta)
    }

    @available(macOS 15.0, *)
    fileprivate static func translateInstalled(_ text: String, session: TranslationSession,
                                              onDelta: @escaping @MainActor (String) -> Void) async throws -> String {
        try Task.checkCancellation()
        let plan = AppleTranslationTextPlan(text)
        do {
            let translated: [String]
            if plan.paragraphs.count == 1 {
                let response = try await session.translate(plan.paragraphs[0])
                translated = [response.targetText]
            } else {
                let requests = plan.paragraphs.enumerated().map {
                    TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
                }
                let responses = try await session.translations(from: requests)
                try Task.checkCancellation()
                var ordered = [String?](repeating: nil, count: requests.count)
                for response in responses {
                    guard let id = response.clientIdentifier, let index = Int(id), ordered.indices.contains(index), ordered[index] == nil else {
                        throw AppError.message("Apple 翻译返回的段落不完整，请重试。")
                    }
                    ordered[index] = response.targetText
                }
                guard ordered.allSatisfy({ $0 != nil }) else {
                    throw AppError.message("Apple 翻译返回的段落不完整，请重试。")
                }
                translated = ordered.map { $0! }
            }
            try Task.checkCancellation()
            guard translated.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw AppError.message("Apple 翻译没有返回完整译文，请重试。")
            }
            let output = try plan.join(translated)
            try Task.checkCancellation()
            onDelta(output)
            return output
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AppError {
            throw error
        } catch {
            try Task.checkCancellation()
            if #available(macOS 26.0, *), TranslationError.notInstalled ~= error {
                throw AppError.message("Apple 语言包尚未就绪，请在设置中准备语言包后重试。")
            }
            throw AppError.message("Apple 翻译暂时不可用，请重试或在设置中检查语言包。")
        }
    }
}

/// Pure text planning keeps paragraph delimiters intact while allowing the
/// system to translate each whole paragraph with its sentence context.
struct AppleTranslationTextPlan {
    private enum Part { case paragraph(Int), separator(String) }
    private var parts: [Part] = []
    private(set) var paragraphs: [String] = []

    init(_ text: String) {
        // A CRLF is one line break. Negative lookarounds prevent the engine
        // from backtracking into two breaks and splitting every Windows line.
        let expression = try! NSRegularExpression(pattern: #"(?:\r\n|\r(?!\n)|(?<!\r)\n)(?:[ \t]*(?:\r\n|\r(?!\n)|(?<!\r)\n))+"#)
        let ns = text as NSString
        var cursor = 0
        for match in expression.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            append(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            parts.append(.separator(ns.substring(with: match.range)))
            cursor = NSMaxRange(match.range)
        }
        append(ns.substring(from: cursor))
    }

    private mutating func append(_ text: String) {
        guard !text.isEmpty else { return }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(.separator(text)); return }
        parts.append(.paragraph(paragraphs.count))
        paragraphs.append(text)
    }

    func join(_ translations: [String]) throws -> String {
        guard translations.count == paragraphs.count else {
            throw AppError.message("Apple 翻译返回的段落不完整，请重试。")
        }
        return parts.map {
            switch $0 { case .paragraph(let index): return translations[index]; case .separator(let value): return value }
        }.joined()
    }
}

enum AppleTranslationLanguages {
    static func targetCode(_ target: String) throws -> String {
        switch target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "simplified chinese", "简体中文", "chinese", "zh", "zh-cn", "zh-hans": return "zh-Hans"
        case "english", "en", "英语": return "en"
        case "japanese", "日本語", "日语", "ja": return "ja"
        default: throw AppError.message("Apple 翻译暂未配置这个目标语言。")
        }
    }

    static func sourceCode(_ text: String) throws -> String {
        let sample = String(text.prefix(8_000))
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        let confidence = recognizer.languageHypotheses(withMaximum: 1).values.first ?? 0
        // Acronyms, product names and short UI labels give very weak language
        // evidence. Prefer English only for low-confidence short ASCII, while
        // keeping confident words such as Bonjour or Hola in their language.
        if sample.count <= 80, sample.unicodeScalars.allSatisfy({ $0.isASCII }),
           sample.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }), confidence < 0.55 {
            return "en"
        }
        guard let language = recognizer.dominantLanguage else {
            throw AppError.message("Apple 翻译无法识别原文语言，请多选择一些文字。")
        }
        switch language {
        case .simplifiedChinese, .traditionalChinese:
            // Shared Han characters (e.g. 你好) provide no script evidence.
            // Choose Hans when conversion would leave the text unchanged.
            if sample.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) == sample { return "zh-Hans" }
            return language == .simplifiedChinese ? "zh-Hans" : "zh-Hant"
        default: return language.rawValue
        }
    }

    static func pair(for text: String, target: String) throws -> (source: Locale.Language, target: Locale.Language) {
        (Locale.Language(identifier: try sourceCode(text)), Locale.Language(identifier: try targetCode(target)))
    }

    static func sameLanguage(_ first: Locale.Language, _ second: Locale.Language) -> Bool {
        guard first.languageCode == second.languageCode else { return false }
        // Chinese script conversion is a real requested change. Let the
        // framework validate that pairing instead of returning unchanged text.
        if first.languageCode?.identifier == "zh" { return first.script == second.script }
        return true
    }

    @available(macOS 15.0, *)
    @MainActor static func availability() -> LanguageAvailability {
        if #available(macOS 26.4, *) { return LanguageAvailability(preferredStrategy: .lowLatency) }
        return LanguageAvailability()
    }

    static func setupPairs(targetLanguage: TargetLanguage, additional: (String, String)? = nil) -> [(String, String)] {
        let codes = targetLanguage == .japanese ? ["zh-Hans", "en", "ja"] : ["zh-Hans", "en"]
        var pairs = codes.flatMap { source in codes.filter { $0 != source }.map { (source, $0) } }
        if let additional {
            let source = Locale.Language(identifier: additional.0)
            let target = Locale.Language(identifier: additional.1)
            if !sameLanguage(source, target), !pairs.contains(where: {
                Locale.Language(identifier: $0.0).isEquivalent(to: source) && Locale.Language(identifier: $0.1).isEquivalent(to: target)
            }) { pairs.append(additional) }
        }
        return pairs
    }
}

/// Only the most recently requested missing pairing is remembered, in memory.
/// This lets Settings prepare an actual source such as French or Japanese
/// without downloading every supported language or persisting source content.
@MainActor
private final class AppleTranslationDownloadRequest: ObservableObject {
    static let shared = AppleTranslationDownloadRequest()
    @Published var pair: (String, String)?
    var id: String { pair.map { $0.0 + ">" + $0.1 } ?? "" }
}

/// Mount in a real SwiftUI surface on macOS 15–25. Multiple surfaces may host
/// this view, but a broker job is claimed only once. No extra window is created.
struct AppleTranslationHostView: View {
    var body: some View {
        if #available(macOS 15.0, *) { AppleTranslationLegacyHost() }
    }
}

/// A host may claim a job once. A fresh token after handover makes an old
/// session's completion harmless, even though macOS 15 has no session.cancel().
struct AppleTranslationHostClaim {
    private(set) var hostID: UUID?
    private(set) var token: UUID?

    mutating func acquire(host: UUID) -> UUID? {
        guard token == nil else { return nil }
        let newToken = UUID()
        hostID = host
        token = newToken
        return newToken
    }

    mutating func release(host: UUID) -> Bool {
        guard hostID == host else { return false }
        hostID = nil
        token = nil
        return true
    }

    func matches(_ candidate: UUID) -> Bool { token == candidate }
}

@available(macOS 15.0, *)
private struct AppleTranslationLegacyHost: View {
    @ObservedObject private var broker = AppleTranslationBroker.shared
    @State private var hostID = UUID()

    var body: some View {
        let jobID = broker.jobID
        Color.clear.frame(width: 0, height: 0)
            .translationTask(broker.configuration) { session in
                await broker.perform(session, jobID: jobID, hostID: hostID)
            }
            .onAppear { broker.register(hostID) }
            .onDisappear { broker.unregister(hostID) }
    }
}

@available(macOS 15.0, *)
@MainActor
private final class AppleTranslationBroker: ObservableObject {
    static let shared = AppleTranslationBroker()
    @Published private(set) var configuration: TranslationSession.Configuration?
    private var hosts = Set<UUID>()
    private var job: Job?
    private var nextConfiguration = TranslationSession.Configuration()
    var jobID: UUID? { job?.id }

    private struct Job {
        let id: UUID
        let text: String
        let emit: @MainActor (String) -> Void
        let continuation: CheckedContinuation<String, Error>
        var claim = AppleTranslationHostClaim()
        var timeout: Task<Void, Never>?
    }

    func register(_ id: UUID) {
        hosts.insert(id)
        if job != nil, job?.claim.token == nil { restartConfiguration() }
    }
    func unregister(_ id: UUID) {
        hosts.remove(id)
        if hosts.isEmpty, let current = job?.id {
            finish(current, result: .failure(CancellationError()))
        } else if job?.claim.release(host: id) == true {
            restartConfiguration()
        }
    }

    func translate(_ text: String, source: Locale.Language, target: Locale.Language,
                   onDelta: @escaping @MainActor (String) -> Void) async throws -> String {
        guard !hosts.isEmpty else {
            throw AppError.message("macOS 15–25 的 Apple 翻译需要打开应用译文窗口或设置页面。")
        }
        try Task.checkCancellation()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let current = job?.id { finish(current, result: .failure(CancellationError())) }
                job = Job(id: id, text: text, emit: onDelta, continuation: continuation)
                job?.timeout = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(45)) } catch { return }
                    self?.finish(id, result: .failure(AppError.message("Apple 翻译等待超时，请重试。")))
                }
                nextConfiguration.source = source
                nextConfiguration.target = target
                nextConfiguration.invalidate()
                configuration = nextConfiguration
                if Task.isCancelled { finish(id, result: .failure(CancellationError())) }
            }
        } onCancel: {
            Task { @MainActor in self.finish(id, result: .failure(CancellationError())) }
        }
    }

    func perform(_ session: TranslationSession, jobID: UUID?, hostID: UUID) async {
        guard let id = jobID, job?.id == id, hosts.contains(hostID),
              let token = job?.claim.acquire(host: hostID), let current = job else { return }
        do {
            let result = try await AppleTranslationBackend.translateInstalled(current.text, session: session) { [weak self] value in
                guard self?.job?.id == id, self?.job?.claim.matches(token) == true, !Task.isCancelled else { return }
                current.emit(value)
            }
            try Task.checkCancellation()
            finishAttempt(id, token: token, result: .success(result))
        } catch { finishAttempt(id, token: token, result: .failure(error)) }
    }

    private func restartConfiguration() {
        guard job != nil else { return }
        nextConfiguration.invalidate()
        configuration = nextConfiguration
    }

    private func finishAttempt(_ id: UUID, token: UUID, result: Result<String, Error>) {
        guard job?.id == id, job?.claim.matches(token) == true else { return }
        finish(id, result: result)
    }

    private func finish(_ id: UUID, result: Result<String, Error>) {
        guard let current = job, current.id == id else { return }
        job = nil
        current.timeout?.cancel()
        configuration = nil
        current.continuation.resume(with: result)
    }
}

/// Embed only in Settings. The framework presents its own permission/download
/// sheet after the person explicitly clicks the preparation button.
struct AppleTranslationSetupView: View {
    @ObservedObject private var language = L10n.shared
    let targetLanguage: TargetLanguage
    init(targetLanguage: TargetLanguage = .smart) { self.targetLanguage = targetLanguage }

    var body: some View {
        if #available(macOS 15.0, *) {
            AppleTranslationLanguageSetup(targetLanguage: targetLanguage)
        } else {
            Text(L10n.text("Apple 翻译需要 macOS 15 或更新版本。"))
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

@available(macOS 15.0, *)
private struct AppleTranslationLanguageSetup: View {
    @ObservedObject private var language = L10n.shared
    let targetLanguage: TargetLanguage
    @ObservedObject private var downloadRequest = AppleTranslationDownloadRequest.shared
    @State private var configuration: TranslationSession.Configuration?
    @State private var pending: [(String, String)] = []
    @State private var preparationPairs: [(String, String)] = []
    @State private var preparing = false
    @State private var status = "正在检查本机语言包…"
    @State private var checkID = UUID()

    var body: some View {
        let preparationID = checkID
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("翻译在本机完成，无需 API Key。首次使用需同意下载 Apple 语言包。"))
                .font(.callout).foregroundStyle(.secondary)
            if targetLanguage == .japanese {
                Text(L10n.text("将准备中文、英语与日语之间的翻译。"))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(L10n.text("将准备中文与英语之间的翻译。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let requested = downloadRequest.pair {
                Text(L10n.format("最近请求的语言：%@ → %@", L10n.languageName(code: requested.0), L10n.languageName(code: requested.1)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button(L10n.text(preparing ? "正在准备…" : "准备语言包")) { Task { await prepare() } }
                    .disabled(preparing)
                if preparing { ProgressView().controlSize(.small) }
                Text(L10n.text(status)).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .translationTask(configuration) { session in
            do {
                try await session.prepareTranslation()
                try Task.checkCancellation()
                guard checkID == preparationID else { return }
                await advance()
            } catch {
                await MainActor.run {
                    guard checkID == preparationID else { return }
                    configuration = nil
                    pending = []
                    preparationPairs = []
                    preparing = false
                    status = "语言包准备未完成。可重新点击并按系统提示操作。"
                }
            }
        }
        .task(id: targetLanguage.rawValue + "|" + downloadRequest.id) {
            // A changed target invalidates the previous preparation; its late
            // completion must not mark a different language pack as ready.
            if preparing {
                checkID = UUID()
                configuration = nil
                pending = []
                preparationPairs = []
                preparing = false
            }
            await inspect()
        }
        .onDisappear {
            checkID = UUID()
            configuration = nil
            pending = []
            preparationPairs = []
            preparing = false
        }
    }

    @MainActor private func inspect() async {
        guard !preparing else { return }
        let id = UUID()
        checkID = id
        let availability = AppleTranslationLanguages.availability()
        var allInstalled = true
        var unsupported = false
        for pair in AppleTranslationLanguages.setupPairs(targetLanguage: targetLanguage, additional: downloadRequest.pair) {
            let state = await availability.status(from: Locale.Language(identifier: pair.0), to: Locale.Language(identifier: pair.1))
            guard !Task.isCancelled, checkID == id else { return }
            if state != .installed { allInstalled = false }
            if state == .unsupported { unsupported = true }
        }
        guard checkID == id else { return }
        status = unsupported ? "所选语言暂不受 Apple 翻译支持。" : (allInstalled ? "语言包已安装，可直接翻译。" : "语言包尚未安装完成，点击由 macOS 确认或继续准备。")
    }

    @MainActor private func prepare() async {
        guard !preparing else { return }
        preparing = true
        checkID = UUID()
        let id = checkID
        status = "正在检查语言包…"
        let availability = AppleTranslationLanguages.availability()
        var missing: [(String, String)] = []
        preparationPairs = AppleTranslationLanguages.setupPairs(targetLanguage: targetLanguage, additional: downloadRequest.pair)
        for pair in preparationPairs {
            let state = await availability.status(from: Locale.Language(identifier: pair.0), to: Locale.Language(identifier: pair.1))
            guard !Task.isCancelled, checkID == id else { return }
            if state == .unsupported {
                preparing = false
                status = "所选语言暂不受 Apple 翻译支持。"
                return
            }
            if state != .installed { missing.append(pair) }
        }
        pending = missing
        await advance()
    }

    @MainActor private func advance() async {
        guard !Task.isCancelled, preparing else { return }
        guard !pending.isEmpty else {
            await waitForInstallation(id: checkID)
            return
        }
        let pair = pending.removeFirst()
        status = "请按 macOS 提示准备语言包…"
        let source = Locale.Language(identifier: pair.0)
        let target = Locale.Language(identifier: pair.1)
        if #available(macOS 26.4, *) {
            configuration = TranslationSession.Configuration(source: source, target: target, preferredStrategy: .lowLatency)
        } else {
            configuration = TranslationSession.Configuration(source: source, target: target)
        }
    }

    @MainActor private func waitForInstallation(id: UUID) async {
        // prepareTranslation may return immediately when a download is already
        // in progress. Only an installed availability result means ready.
        let pairs = preparationPairs
        let deadline = Date().addingTimeInterval(600)
        status = "语言包正在下载或等待系统准备…"
        while !Task.isCancelled, preparing, checkID == id {
            let availability = AppleTranslationLanguages.availability()
            var allInstalled = !pairs.isEmpty
            var unsupported = false
            for pair in pairs {
                let state = await availability.status(from: Locale.Language(identifier: pair.0), to: Locale.Language(identifier: pair.1))
                guard !Task.isCancelled, preparing, checkID == id else { return }
                if state != .installed { allInstalled = false }
                if state == .unsupported { unsupported = true }
            }
            if allInstalled {
                preparing = false
                configuration = nil
                preparationPairs = []
                status = "语言包已安装，可直接翻译。"
                return
            }
            if unsupported || Date() >= deadline {
                preparing = false
                configuration = nil
                preparationPairs = []
                status = unsupported ? "所选语言暂不受 Apple 翻译支持。" : "语言包尚未安装完成，可稍后重新检查。"
                return
            }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }

}
