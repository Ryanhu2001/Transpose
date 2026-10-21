import Foundation

private final class BackendMockProtocol: URLProtocol, @unchecked Sendable {
    enum Fixture { case stream, truncated, hang, redirect, mandatoryReasoning, mandatoryAlways, invalidModel, oversizedError }
    static let mandatoryReasoning = #"{"error":{"message":"Reasoning is mandatory for this endpoint and cannot be disabled.","code":400}}"#
    private static let lock = NSLock()
    private static var fixture: Fixture = .stream
    private static var requests: [URLRequest] = []
    private static var stopped: Set<Int> = []
    private static var requestBodies: [[String: Any]] = []
    private var number = -1

    static func reset(_ value: Fixture) {
        lock.lock(); fixture = value; requests = []; stopped = []; requestBodies = []; lock.unlock()
    }
    static var count: Int { lock.lock(); defer { lock.unlock() }; return requests.count }
    static var hosts: [String] { lock.lock(); defer { lock.unlock() }; return requests.compactMap { $0.url?.host } }
    static var bodies: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return requestBodies }
    static func didStop(_ number: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return stopped.contains(number) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var captured = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                captured.append(buffer, count: count)
            }
            data = captured
        }
        Self.lock.lock()
        number = Self.requests.count
        Self.requests.append(request)
        Self.requestBodies.append(data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:])
        let fixture = Self.fixture
        Self.lock.unlock()
        let url = request.url!
        let error: String?
        switch fixture {
        case .mandatoryReasoning where number == 0, .mandatoryAlways: error = Self.mandatoryReasoning
        case .invalidModel: error = #"{"error":{"message":"Invalid model identifier"}}"#
        case .oversizedError: error = Self.mandatoryReasoning + String(repeating: " ", count: 65_537)
        default: error = nil
        }
        if let error {
            let response = HTTPURLResponse(url: url, statusCode: 400, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(error.utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        if case .redirect = fixture, url.host != "redirect-target.test" {
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": "https://redirect-target.test/v1/chat/completions"])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: "https://redirect-target.test/v1/chat/completions")!), redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let first = #"data: {"choices":[{"delta":{"content":"你好"}}]}"# + "\n\n"
        client?.urlProtocol(self, didLoad: Data(first.utf8))
        if case .hang = fixture { return }
        if case .truncated = fixture { client?.urlProtocolDidFinishLoading(self); return }
        let last = #"data: {"choices":[{"delta":{"content":"，世界。"},"finish_reason":"stop"}]}"# + "\n\n"
        client?.urlProtocol(self, didLoad: Data(last.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        Self.lock.lock(); Self.stopped.insert(number); Self.lock.unlock()
    }
}

@MainActor
func runBackendChecks() async throws -> Int {
    struct Failure: Error { let reason: String }
    var checks = 0
    func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        if !(try condition()) { throw Failure(reason: label) }
        checks += 1
    }
    func options(provider: TranslationProvider = .customAPI, base: String = "https://fixture.test/v1", model: String = "fixture", key: String = "fixture-not-a-real-key", target: String = "Simplified Chinese", preferences: String = "", glossary: [GlossaryEntry] = []) -> TranslationOptions {
        TranslationOptions(provider: provider, targetLanguage: target, baseURL: base, model: model, apiKey: key, preferences: preferences, glossary: glossary)
    }
    try check(try OpenAIRequestBuilder.endpoint(TranslationOptions(provider: .deepseek, targetLanguage: "Chinese")).absoluteString == "https://api.deepseek.com/chat/completions", "root endpoint")
    try check(try OpenAIRequestBuilder.endpoint(options()).absoluteString == "https://fixture.test/v1/chat/completions", "v1 endpoint")
    let complete = try OpenAIRequestBuilder.endpoint(options(base: "https://custom.test/proxy/v1/chat/completions/?api-version=1"))
    try check(complete.host == "custom.test" && complete.path == "/proxy/v1/chat/completions" && complete.query == "api-version=1", "full endpoint preserves host and prefix")

    var rejected = 0
    for base in ["http://remote.test/v1", "file:///tmp/model", "https://user:pass@remote.test/v1", "http://localhost.evil.test/v1"] {
        do { _ = try OpenAIRequestBuilder.endpoint(options(base: base)) } catch { rejected += 1 }
    }
    try check(rejected == 4, "unsafe endpoint rejection")
    let local = try ["http://localhost:11434/v1", "http://127.0.0.2:1234/v1", "http://[::1]:1234/v1"].map { try OpenAIRequestBuilder.endpoint(options(base: $0)) }
    try check(local.count == 3 && local.allSatisfy { $0.scheme == "http" }, "local HTTP endpoints")

    let deepseek = try OpenAIRequestBuilder.request(text: "Hello", options: options(provider: .deepseek), prompt: "Translate", apiKey: "fixture-not-a-real-key")
    let deepseekBody = try JSONSerialization.jsonObject(with: deepseek.httpBody!) as! [String: Any]
    try check((deepseekBody["thinking"] as? [String: String])?["type"] == "disabled" && deepseekBody["tools"] == nil, "DeepSeek no thinking or tools")
    let free = try OpenAIRequestBuilder.request(text: "Hello", options: TranslationOptions(provider: .openrouter, targetLanguage: "Chinese", apiKey: "fixture-not-a-real-key"), prompt: "Translate", apiKey: "fixture-not-a-real-key")
    let freeBody = try JSONSerialization.jsonObject(with: free.httpBody!) as! [String: Any]
    try check(freeBody["model"] as? String == "openrouter/free" && freeBody["models"] == nil && (freeBody["provider"] as? [String: Bool])?["allow_fallbacks"] == false, "free default without model fallback")
    let paid = try OpenAIRequestBuilder.request(text: "Hello", options: options(provider: .openrouter, model: "explicit/user-model"), prompt: "Translate", apiKey: "fixture-not-a-real-key")
    let paidBody = try JSONSerialization.jsonObject(with: paid.httpBody!) as! [String: Any]
    try check(paidBody["model"] as? String == "explicit/user-model", "explicit user model is preserved")
    let reasoningRetry = OpenAIRequestBuilder.mandatoryReasoningRequest(paid, errorData: Data(BackendMockProtocol.mandatoryReasoning.utf8))!
    var expectedRetry = paidBody
    expectedRetry["reasoning"] = ["exclude": true]
    let retryBody = try JSONSerialization.jsonObject(with: reasoningRetry.httpBody!) as! NSDictionary
    try check(retryBody.isEqual(to: expectedRetry) && reasoningRetry.url == paid.url && reasoningRetry.allHTTPHeaderFields == paid.allHTTPHeaderFields, "mandatory reasoning changes only reasoning options")
    try check(OpenAIRequestBuilder.mandatoryReasoningRequest(reasoningRetry, errorData: Data(BackendMockProtocol.mandatoryReasoning.utf8)) == nil, "mandatory reasoning cannot retry an already relaxed request")
    for error in [#"{"error":{"message":"Unknown model"}}"#, #"{"error":{"message":"Unsupported parameter: reasoning"}}"#, #"{"error":{"message":"Reasoning is mandatory"}}"#, "Reasoning is mandatory and cannot be disabled.", "malformed"] {
        try check(OpenAIRequestBuilder.mandatoryReasoningRequest(paid, errorData: Data(error.utf8)) == nil, "unrelated or unstructured error is never retried")
    }
    let noKey = try OpenAIRequestBuilder.request(text: "Hello", options: options(base: "http://localhost:11434/v1", key: ""), prompt: "Translate", apiKey: "")
    try check(noKey.value(forHTTPHeaderField: "Authorization") == nil, "local service without API key")

    // Isolated verification process only: fixtures overwrite any inherited values
    // without reading them. A changed endpoint must not pick up a shell credential.
    do {
        let environmentNames = ["DEEPSEEK_API_KEY", "OPENROUTER_API_KEY", "VELA_API_KEY"]
        for name in environmentNames { setenv(name, "fixture-environment-key-not-a-real-key", 1) }
        defer { for name in environmentNames { unsetenv(name) } }
        let providers: [TranslationProvider] = [.deepseek, .openrouter, .customAPI]
        try check(providers.allSatisfy {
            OpenAIRequestBuilder.resolvedAPIKey(options(provider: $0, base: "https://changed-endpoint.test/v1", key: " \n ")) == ""
        }, "an inherited API key is never resolved for a changed endpoint")
        try check(providers.allSatisfy {
            OpenAIRequestBuilder.resolvedAPIKey(options(provider: $0, key: " explicit-fixture-key \n")) == "explicit-fixture-key"
        }, "only the explicitly supplied API key is resolved")
        let unconfigured = options(base: "https://changed-endpoint.test/v1", key: "")
        let request = try OpenAIRequestBuilder.request(text: "Hello", options: unconfigured, prompt: "Translate", apiKey: OpenAIRequestBuilder.resolvedAPIKey(unconfigured))
        try check(request.value(forHTTPHeaderField: "Authorization") == nil, "environment API keys are not sent to a custom endpoint")
    }

    let visible = try TranslationWireParser.openAI(#"data: {"choices":[{"delta":{"content":"好","reasoning_content":"hidden"},"finish_reason":"stop"}]}"#)
    let reasoning = try TranslationWireParser.openAI(#"data: {"choices":[{"delta":{"reasoning_content":"hidden"}}]}"#)
    var badFinishes = 0
    for reason in ["length", "content_filter", "tool_calls"] {
        do { _ = try TranslationWireParser.openAI("data: {\"choices\":[{\"finish_reason\":\"\(reason)\",\"delta\":{}}]}") } catch { badFinishes += 1 }
    }
    try check(visible.text == "好" && visible.done && reasoning.text == nil && badFinishes == 3 && (try TranslationWireParser.openAI("data: [DONE]")).done, "SSE content completion and error handling")
    let json = Data(#"{"choices":[{"message":{"content":"完整译文"},"finish_reason":"stop"}]}"#.utf8)
    try check(try TranslationWireParser.completeJSON(json) == "完整译文", "compatible non-stream JSON response")

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [BackendMockProtocol.self]
    let service = TranslationService(configuration: configuration)
    BackendMockProtocol.reset(.stream)
    var deltas: [String] = []
    let first = try await service.translate("Hello world", options: options()) { deltas.append($0) }
    try check(!first.cached && deltas == ["你好", "你好，世界。"] && BackendMockProtocol.count == 1, "native cumulative streaming")
    let cached = try await service.translate("Hello world", options: options()) { _ in }
    try check(cached.cached && BackendMockProtocol.count == 1, "cache avoids repeated provider request")
    let changed = [
        options(preferences: "Formal"),
        options(glossary: [GlossaryEntry(source: "world", translation: "世界")]),
        options(target: "Japanese"),
        options(base: "https://second.test/v1"),
        options(key: "different-fixture-key"),
        options(model: "different-fixture-model"),
        options(provider: .openrouter)
    ]
    for variant in changed { _ = try await service.translate("Hello world", options: variant) { _ in } }
    try check(BackendMockProtocol.count == 8, "cache isolates endpoint model provider target preferences glossary and credential")

    BackendMockProtocol.reset(.mandatoryReasoning)
    var reasoningDeltas: [String] = []
    _ = try await service.translate("Mandatory reasoning fixture", options: options(provider: .openrouter, model: "minimax/minimax-m3.1-flash:free")) { reasoningDeltas.append($0) }
    let reasoningBodies = BackendMockProtocol.bodies
    var expectedSecond = reasoningBodies[0]
    expectedSecond["reasoning"] = ["exclude": true]
    try check(BackendMockProtocol.count == 2 && (reasoningBodies[1] as NSDictionary).isEqual(to: expectedSecond) && reasoningDeltas.last == "你好，世界。", "HTTP 400 mandatory reasoning retries the same model once")

    for (fixture, provider, label) in [(BackendMockProtocol.Fixture.invalidModel, TranslationProvider.openrouter, "invalid model"), (.mandatoryAlways, .openrouter, "repeated mandatory error"), (.mandatoryAlways, .customAPI, "non OpenRouter request"), (.oversizedError, .openrouter, "oversized error body")] {
        BackendMockProtocol.reset(fixture)
        var rejected = false
        do { _ = try await service.translate(label, options: options(provider: provider)) { _ in } }
        catch let error as AppError { rejected = error.localizedDescription.contains("400") && !error.localizedDescription.contains("Invalid model identifier") }
        let expectedCount: Int
        if case .mandatoryAlways = fixture, provider == .openrouter { expectedCount = 2 } else { expectedCount = 1 }
        try check(rejected && BackendMockProtocol.count == expectedCount, "HTTP error remains sanitized without an extra retry: " + label)
    }

    BackendMockProtocol.reset(.truncated)
    var failures = 0
    for _ in 0..<2 {
        do { _ = try await service.translate("Truncated", options: options()) { _ in } } catch is AppError { failures += 1 }
    }
    try check(failures == 2 && BackendMockProtocol.count == 2, "incomplete EOF is never cached")

    BackendMockProtocol.reset(.hang)
    var seen = false
    let task = Task { try await service.translate("Cancel me", options: options()) { _ in seen = true } }
    for _ in 0..<200 where !seen { try await Task.sleep(nanoseconds: 10_000_000) }
    let started = Date()
    task.cancel()
    var cancelled = false
    do { _ = try await task.value } catch is CancellationError { cancelled = true }
    for _ in 0..<100 where !BackendMockProtocol.didStop(0) { try await Task.sleep(nanoseconds: 10_000_000) }
    try check(seen && cancelled && Date().timeIntervalSince(started) < 1.5 && BackendMockProtocol.didStop(0), "cancellation stops the actual HTTP stream")

    BackendMockProtocol.reset(.redirect)
    var redirectRejected = false
    do { _ = try await service.translate("Redirect", options: options()) { _ in } } catch is AppError { redirectRejected = true }
    try check(redirectRejected && BackendMockProtocol.count == 1 && !BackendMockProtocol.hosts.contains("redirect-target.test"), "redirect never forwards Authorization to another origin")
    return checks
}
