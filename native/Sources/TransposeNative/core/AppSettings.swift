import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class AppSettings: ObservableObject {
    private struct Connection: Codable { var baseURL: String; var model: String; var cliPath: String }
    private let defaults: UserDefaults
    private var connections: [String: Connection]
    private var loadingConnection = false
    private var connectionTask: Task<Void, Never>?
    private var connectionGeneration = UUID()

    @Published var provider: TranslationProvider {
        didSet { if oldValue != provider { changedProvider(from: oldValue) } }
    }
    @Published var target: TargetLanguage { didSet { defaults.set(target.rawValue, forKey: "target"); invalidateConnectionTest() } }
    @Published var automaticSelection: Bool { didSet { defaults.set(automaticSelection, forKey: "automaticSelection") } }
    @Published var apiBaseURL: String { didSet { persistConnection(); refreshCredentialMetadata() } }
    @Published var apiModel: String { didSet { persistConnection() } }
    @Published var cliPath: String { didSet { persistConnection() } }
    @Published var preferences: String { didSet { defaults.set(preferences, forKey: "translationPreferences") } }
    @Published var glossary: [GlossaryEntry] { didSet { if let data = try? JSONEncoder().encode(glossary) { defaults.set(data, forKey: "glossary") } } }
    @Published var detectedCLIs: [DetectedCLI]
    @Published var credentialStatus = ""
    @Published var keyDraft = "" { didSet { invalidateConnectionTest() } }
    @Published var keyIsSaved = false
    @Published var connectionStatus = ""
    @Published var testingConnection = false
    @Published var glossaryStatus = ""

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let detected = CLIProbe.discover()
        detectedCLIs = detected
        if let data = defaults.data(forKey: "providerConnections"), let saved = try? JSONDecoder().decode([String: Connection].self, from: data) {
            connections = saved
        } else { connections = [:] }
        let isNewConnections = defaults.integer(forKey: "connectionSchema") < 2
        let preferredLocal = detected.first(where: { $0.provider == .codex }) ?? detected.first
        let savedProvider = TranslationProvider(rawValue: defaults.string(forKey: "provider") ?? "")
        let firstProvider = AppleTranslationBackend.isSupported ? TranslationProvider.apple : (preferredLocal?.provider ?? .openrouter)
        let chosen = isNewConnections ? firstProvider : (savedProvider ?? firstProvider)
        provider = chosen
        target = TargetLanguage(rawValue: defaults.string(forKey: "target") ?? "") ?? .smart
        automaticSelection = defaults.object(forKey: "automaticSelection") as? Bool ?? true
        let connection = connections[chosen.rawValue]
        apiBaseURL = connection?.baseURL ?? chosen.defaultBaseURL
        apiModel = connection?.model ?? chosen.defaultModel
        cliPath = connection?.cliPath ?? detected.first(where: { $0.provider == chosen })?.path ?? ""
        preferences = defaults.string(forKey: "translationPreferences") ?? ""
        if let data = defaults.data(forKey: "glossary"), let entries = try? JSONDecoder().decode([GlossaryEntry].self, from: data) {
            glossary = entries
        } else { glossary = [] }
        defaults.set(2, forKey: "connectionSchema")
        defaults.set(chosen.rawValue, forKey: "provider")
        refreshCredentialMetadata()
    }

    func selectProvider(_ value: TranslationProvider) { provider = value; refreshCredentialMetadata() }

    func scanCLIs() {
        detectedCLIs = CLIProbe.discover()
        if provider.isCLI, cliPath.isEmpty || !FileManager.default.isExecutableFile(atPath: (cliPath as NSString).expandingTildeInPath) {
            cliPath = detectedCLIs.first(where: { $0.provider == provider })?.path ?? ""
        }
    }

    func options(for text: String, provider override: TranslationProvider? = nil, overrideKey: String? = nil) -> TranslationOptions {
        let chosen = override ?? provider
        let current = chosen == provider
        let connection = connections[chosen.rawValue]
        let baseURL = current ? apiBaseURL : (connection?.baseURL ?? chosen.defaultBaseURL)
        let model = current ? apiModel : (connection?.model ?? chosen.defaultModel)
        let path = current ? cliPath : (connection?.cliPath ?? detectedCLIs.first(where: { $0.provider == chosen })?.path ?? "")
        let key = overrideKey ?? (chosen.isAPI ? KeychainStore.get(provider: chosen, baseURL: baseURL) : nil) ?? ""
        return TranslationOptions(provider: chosen, targetLanguage: target.resolved(for: text), baseURL: baseURL, model: model, apiKey: key, cliPath: path, preferences: preferences, glossary: glossary)
    }

    @discardableResult func saveKey() -> Bool {
        guard provider.isAPI else { return false }
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { credentialStatus = "请输入 API Key 后保存。"; return false }
        let enteredURL = apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = enteredURL.isEmpty ? provider.defaultBaseURL : enteredURL
        guard let url = URL(string: endpoint), let host = url.host, !host.isEmpty else {
            credentialStatus = "请填写有效的 API 地址。"; return false
        }
        do {
            try KeychainStore.set(key, provider: provider, baseURL: apiBaseURL)
            keyDraft = ""
            refreshCredentialMetadata()
            credentialStatus = "已保存到 macOS 钥匙串"
            return true
        } catch { credentialStatus = error.localizedDescription; return false }
    }

    @discardableResult func removeKey() -> Bool {
        guard provider.isAPI else { return false }
        invalidateConnectionTest()
        do {
            try KeychainStore.delete(provider: provider, baseURL: apiBaseURL)
            keyDraft = ""
            refreshCredentialMetadata()
            credentialStatus = "已移除此连接的 API Key"
            return true
        } catch { credentialStatus = error.localizedDescription; return false }
    }

    func testConnection() {
        invalidateConnectionTest()
        let request = connectionGeneration
        let source = "A little clarity goes a long way."
        let options = options(for: source, overrideKey: keyDraft.isEmpty ? nil : keyDraft)
        testingConnection = true
        connectionStatus = "正在试译一句…"
        connectionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.connectionGeneration == request {
                    self.testingConnection = false
                    self.connectionTask = nil
                }
            }
            let tester = TranslationService()
            var output = ""
            do {
                let stats = try await tester.translate(source, options: options) { output = $0 }
                guard !Task.isCancelled, self.connectionGeneration == request else { return }
                self.connectionStatus = "连接成功 · \(String(format: "%.1f", stats.elapsed)) 秒\n\(output)"
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled, self.connectionGeneration == request else { return }
                self.connectionStatus = error.localizedDescription
            }
        }
    }

    func cancelPendingWork() { invalidateConnectionTest(); keyDraft = "" }

    func importGlossary() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("导入术语表")
        panel.allowedContentTypes = [.json, .commaSeparatedText, .tabSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard data.count <= 2_000_000 else { throw AppError.message("术语文件超过 2 MB，请缩小后重试。") }
            let format: GlossaryStore.Format = url.pathExtension.lowercased() == "json" ? .json : (url.pathExtension.lowercased() == "csv" ? .csv : .tsv)
            let entries = try GlossaryStore.parse(data: data, format: format)
            glossary = try GlossaryStore.importEntries(existing: glossary, incoming: entries)
            glossaryStatus = "已导入 \(entries.count) 条术语"
        } catch { glossaryStatus = error.localizedDescription }
    }

    func exportGlossary() {
        let panel = NSSavePanel()
        panel.title = L10n.text("导出术语表")
        panel.nameFieldStringValue = "transpose-glossary.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try GlossaryStore.encode(glossary, format: .json).write(to: url, options: [.atomic])
            glossaryStatus = "术语表已导出"
        } catch { glossaryStatus = error.localizedDescription }
    }

    private func changedProvider(from old: TranslationProvider) {
        invalidateConnectionTest()
        connections[old.rawValue] = Connection(baseURL: apiBaseURL, model: apiModel, cliPath: cliPath)
        loadingConnection = true
        let saved = connections[provider.rawValue]
        apiBaseURL = saved?.baseURL ?? provider.defaultBaseURL
        apiModel = saved?.model ?? provider.defaultModel
        cliPath = saved?.cliPath ?? detectedCLIs.first(where: { $0.provider == provider })?.path ?? ""
        keyDraft = ""
        loadingConnection = false
        defaults.set(provider.rawValue, forKey: "provider")
        persistConnection()
        refreshCredentialMetadata()
    }

    private func persistConnection() {
        guard !loadingConnection else { return }
        invalidateConnectionTest()
        connections[provider.rawValue] = Connection(baseURL: apiBaseURL, model: apiModel, cliPath: cliPath)
        if let data = try? JSONEncoder().encode(connections) { defaults.set(data, forKey: "providerConnections") }
    }

    private func refreshCredentialMetadata() {
        guard !loadingConnection else { return }
        keyIsSaved = provider.isAPI && KeychainStore.contains(provider: provider, baseURL: apiBaseURL)
        credentialStatus = keyIsSaved ? "API Key 已保存在 macOS 钥匙串" : ""
    }

    private func invalidateConnectionTest() {
        connectionGeneration = UUID()
        connectionTask?.cancel()
        connectionTask = nil
        testingConnection = false
        connectionStatus = ""
    }
}
