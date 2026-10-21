import Foundation
import CryptoKit

@MainActor
final class TranslationService {
    private struct CacheKey: Hashable {
        let provider: TranslationProvider
        let endpoint: String
        let model: String
        let target: String
        let preferences: String
        let glossary: [GlossaryEntry]
        let credentialScope: String
        let text: String
    }
    private let session: URLSession
    private var cache: [CacheKey: String] = [:]
    private var recency: [CacheKey] = []
    private var cacheCharacters = 0
    private var activeRequest: UUID?
    private var activeTask: Task<String, Error>?

    /// Configuration injection is used only by the offline URLProtocol fixtures.
    init(configuration: URLSessionConfiguration? = nil) {
        let configuration = configuration ?? URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration, delegate: TranslationRedirectPolicy(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }

    func translate(_ text: String, options: TranslationOptions, onDelta: @escaping @MainActor (String) -> Void) async throws -> TranslationStats {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { throw AppError.message("没有识别到可翻译的文字。") }
        guard input.count <= 60_000 else { throw AppError.message("选中文字较多，请分成较小的区域翻译。") }
        try Task.checkCancellation()
        activeTask?.cancel()
        activeTask = nil
        let requestID = UUID()
        activeRequest = requestID
        let start = Date()
        var firstToken: TimeInterval?
        let apiKey = options.provider.isAPI ? OpenAIRequestBuilder.resolvedAPIKey(options) : ""
        let endpoint = options.provider == .apple ? "apple:on-device" : (options.provider.isAPI ? try OpenAIRequestBuilder.endpoint(options).absoluteString : options.cliPath)
        let key = CacheKey(
            provider: options.provider, endpoint: endpoint, model: OpenAIRequestBuilder.resolvedModel(options),
            target: options.targetLanguage, preferences: options.preferences, glossary: options.glossary,
            credentialScope: SHA256.hash(data: Data(apiKey.utf8)).map { String(format: "%02x", $0) }.joined(), text: input
        )
        if let result = cache[key] {
            touch(key)
            onDelta(result)
            return TranslationStats(elapsed: Date().timeIntervalSince(start), firstToken: 0, cached: true, provider: options.provider.title)
        }
        let prompt = options.provider == .apple ? "" : TranslationPromptBuilder.systemPrompt(target: options.targetLanguage, preferences: options.preferences, terms: options.glossary, source: input)
        let emit: @MainActor (String) -> Void = { [weak self] value in
            guard !Task.isCancelled, self?.activeRequest == requestID, !value.isEmpty else { return }
            if firstToken == nil { firstToken = Date().timeIntervalSince(start) }
            onDelta(value)
        }
        let request: URLRequest? = options.provider.isAPI ? try OpenAIRequestBuilder.request(text: input, options: options, prompt: prompt, apiKey: apiKey) : nil
        let session = self.session
        let task = Task { @MainActor in
            if options.provider == .apple { return try await AppleTranslationBackend.translate(input, options: options, onDelta: emit) }
            if let request { return try await Self.translateAPI(request, session: session, onDelta: emit) }
            return try await CLIRunner.translate(input, options: options, systemPrompt: prompt, onDelta: emit)
        }
        activeTask = task
        defer { if activeRequest == requestID { activeTask = nil } }
        let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation()
        guard activeRequest == requestID else { throw CancellationError() }
        let final = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !final.isEmpty else { throw AppError.message("翻译服务没有返回文字，请重试。") }
        if final != result { onDelta(final) }
        insert(final, for: key)
        return TranslationStats(elapsed: Date().timeIntervalSince(start), firstToken: firstToken, cached: false, provider: options.provider.title)
    }

    private static func translateAPI(_ request: URLRequest, session: URLSession, onDelta: @escaping @MainActor (String) -> Void) async throws -> String {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse else { throw AppError.message("翻译服务响应无效。") }
            guard (200..<300).contains(response.statusCode) else {
                switch response.statusCode {
                case 300..<400: throw AppError.message("服务地址发生重定向，请填写最终服务地址。")
                case 401, 403: throw AppError.message("API Key 无效或没有访问权限，请检查设置。")
                case 402: throw AppError.message("API 账户额度不足，或所选模型需要付费。")
                case 429: throw AppError.message("当前模型达到请求限额，请稍后重试或自行更换模型。")
                default: throw AppError.message("翻译服务暂时不可用（HTTP \(response.statusCode)）。")
                }
            }
            if response.mimeType == "application/json" {
                var data = Data()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard data.count < 2_000_000 else { throw AppError.message("翻译响应过大，请缩小选区。") }
                    data.append(byte)
                }
                let result = try TranslationWireParser.completeJSON(data)
                try Task.checkCancellation()
                onDelta(result)
                return result
            }
            var result = ""
            var completed = false
            for try await line in bytes.lines {
                try Task.checkCancellation()
                let event = try TranslationWireParser.openAI(line)
                if let text = event.text, !text.isEmpty {
                    result += text
                    guard result.utf8.count <= 2_000_000 else { throw AppError.message("翻译响应过大，请缩小选区。") }
                    onDelta(result)
                }
                if event.done { completed = true; break }
            }
            try Task.checkCancellation()
            guard completed else { throw AppError.message("翻译连接提前结束，译文尚未完成，请重试。") }
            guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppError.message("模型没有返回译文，请检查模型名称。") }
            return result
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as AppError { throw error }
        catch let error as URLError {
            switch error.code {
            case .timedOut: throw AppError.message("翻译请求超时，请重试。")
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                throw AppError.message("无法连接翻译服务，请检查网络和服务地址。")
            default: throw AppError.message("翻译连接中断，请重试。")
            }
        } catch { throw AppError.message("翻译服务暂时不可用，请重试。") }
    }

    private func touch(_ key: CacheKey) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }
    private func insert(_ value: String, for key: CacheKey) {
        if let old = cache.updateValue(value, forKey: key) { cacheCharacters -= old.count + key.text.count }
        cacheCharacters += value.count + key.text.count
        touch(key)
        while recency.count > 96 || cacheCharacters > 1_000_000 {
            guard let oldest = recency.first else { break }
            recency.removeFirst()
            if let removed = cache.removeValue(forKey: oldest) { cacheCharacters -= removed.count + oldest.text.count }
        }
    }
}

/// Authorization is sent exclusively to the configured endpoint, never a redirect.
final class TranslationRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum OpenAIRequestBuilder {
    static func resolvedModel(_ options: TranslationOptions) -> String {
        let model = options.model.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isEmpty ? options.provider.defaultModel : model
    }
    static func resolvedAPIKey(_ options: TranslationOptions) -> String {
        // Settings supplies only the credential saved for this exact connection.
        // An inherited shell credential must never follow a changed API endpoint.
        options.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func endpoint(_ options: TranslationOptions) throws -> URL {
        let supplied = options.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = supplied.isEmpty ? options.provider.defaultBaseURL : supplied
        guard var components = URLComponents(string: value), let scheme = components.scheme?.lowercased(), ["https", "http"].contains(scheme), let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.fragment == nil else {
            throw AppError.message("请填写有效的 HTTP 或 HTTPS API 地址，地址中不要包含账号或密码。")
        }
        guard scheme == "https" || isLoopback(host) else { throw AppError.message("远程 API 必须使用 HTTPS；HTTP 仅用于本机服务。") }
        if let port = components.port, !(1...65_535).contains(port) { throw AppError.message("API 地址的端口无效。") }
        components.scheme = scheme
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix("/chat/completions") { path += "/chat/completions" }
        components.percentEncodedPath = path
        guard let url = components.url else { throw AppError.message("API 地址无效。") }
        return url
    }
    private static func isLoopback(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host == "::1" || host == "0:0:0:0:0:0:0:1" { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.first == "127" && octets.allSatisfy { UInt8($0) != nil }
    }
    static func request(text: String, options: TranslationOptions, prompt: String, apiKey: String) throws -> URLRequest {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.contains("\n"), !key.contains("\r") else { throw AppError.message("API Key 格式无效。") }
        guard options.provider == .customAPI || !key.isEmpty else { throw AppError.message("请在设置中填写 API Key。") }
        let model = resolvedModel(options)
        guard !model.isEmpty else { throw AppError.message("请在设置中填写模型名称。") }
        var request = URLRequest(url: try endpoint(options))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if !key.isEmpty { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        var body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": prompt], ["role": "user", "content": text]],
            "stream": true, "temperature": 0.2,
            "max_tokens": min(16_384, max(1_024, text.count * 2 + 256))
        ]
        if options.provider == .deepseek { body["thinking"] = ["type": "disabled"] }
        if options.provider == .openrouter {
            body["reasoning"] = ["enabled": false]
            body["provider"] = ["allow_fallbacks": false]
            request.setValue("Transpose", forHTTPHeaderField: "X-Title")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}

enum TranslationWireParser {
    static func openAI(_ line: String) throws -> (text: String?, done: Bool) {
        guard line.hasPrefix("data:") else { return (nil, false) }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return (nil, true) }
        if payload.isEmpty { return (nil, false) }
        guard let data = payload.data(using: .utf8), let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError.message("翻译流数据不完整，请重试。")
        }
        if event["error"] != nil { throw AppError.message("API 返回错误，请检查模型、额度和服务配置。") }
        guard let choices = event["choices"] as? [[String: Any]], let choice = choices.first else { return (nil, false) }
        let done = try completed(choice["finish_reason"] as? String)
        let delta = choice["delta"] as? [String: Any]
        if let refusal = delta?["refusal"] as? String, !refusal.isEmpty { throw AppError.message("模型未能翻译这段内容。") }
        return (content(delta?["content"]), done)
    }
    static func completeJSON(_ data: Data) throws -> String {
        guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any], event["error"] == nil,
              let choices = event["choices"] as? [[String: Any]], let choice = choices.first,
              try completed(choice["finish_reason"] as? String), let message = choice["message"] as? [String: Any],
              let result = content(message["content"]), !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppError.message("API 没有返回完整译文，请检查服务兼容性。")
        }
        return result
    }
    private static func completed(_ reason: String?) throws -> Bool {
        guard let reason else { return false }
        switch reason {
        case "stop": return true
        case "length": throw AppError.message("译文超过单次长度限制，请缩小选区后重试。")
        case "content_filter": throw AppError.message("翻译服务未能处理这段内容。")
        default: throw AppError.message("翻译服务提前停止，译文尚未完成，请重试。")
        }
    }
    private static func content(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let parts = value as? [[String: Any]] {
            return parts.filter { ($0["type"] as? String) == "text" }.compactMap { $0["text"] as? String }.joined()
        }
        return nil
    }
}
